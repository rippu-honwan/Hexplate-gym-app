import Foundation
import HexplateCore
import Observation
import os

/// MyGym: the paired openGym server (rep-counter plan, Stage C). Pairing (lib/remote.js), the
/// watch's motion files (lib/motion-upload.js, PUT /api/motion) and the state document
/// (store/useStore.js pullState / pushState, PUT /api/data). The merge is openGym's own
/// (SyncMerge). With `writes` off, a sync only works out what it would do and logs it to
/// Documents/sync-log.txt (dry run); motion files go up either way.
@MainActor
@Observable
final class ServerSync {
    static let shared = ServerSync()
    typealias Object = [String: JSONValue]

    /// The pairing, in the file the Capacitor app kept it in, so a phone paired before the switch
    /// stays paired (and the old app, put back, would still find it).
    struct Remote: Codable { var mode: String; var base: String?; var token: String?; var user: JSONValue? }

    static let remoteFile = URL.libraryDirectory.appending(path: "NoCloud/opengym-remote.json")
    static let logFile = URL.documentsDirectory.appending(path: "sync-log.txt")
    static let dryFile = URL.documentsDirectory.appending(path: "sync-dryrun.json")
    static let motionDir = URL.documentsDirectory.appending(path: "motion")
    private static let log = Logger(subsystem: "com.rippuhonwan.mygym", category: "sync")

    private(set) var remote = (try? Data(contentsOf: remoteFile)).flatMap { try? JSONDecoder().decode(Remote.self, from: $0) }
    var paired: Bool { remote?.mode == "remote" && remote?.base != nil && remote?.token != nil }
    var host: String { remote?.base.flatMap { URL(string: $0)?.host() } ?? "" }

    /// Off (the default): dry run. On: merges are saved here and pushed to the server.
    var writes = UserDefaults.standard.bool(forKey: "syncWrites") { didSet { UserDefaults.standard.set(writes, forKey: "syncWrites") } }
    /// What the last attempt came to, for Settings.
    private(set) var status = ""
    private(set) var lastCheck: Date?
    private(set) var motionWaiting = 0

    /// The server copy this device last held (useStore's sync marker).
    private var base: SyncPlan.Base? {
        get { UserDefaults.standard.data(forKey: "syncBase").flatMap { try? JSONDecoder().decode(SyncPlan.Base.self, from: $0) } }
        set { UserDefaults.standard.set(newValue.flatMap { try? JSONEncoder().encode($0) }, forKey: "syncBase") }
    }

    private var running: Task<Void, Never>?
    private var renewed = false
    private var lastDryRun = ""
    private var pushSoon: Task<Void, Never>?
    // No cookies: the server lets a Bearer request past its CSRF check only when no session
    // cookie rides along (api/server.js csrfOk).
    private let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.httpShouldSetCookies = false
        c.timeoutIntervalForRequest = 30
        return URLSession(configuration: c)
    }()

    // MARK: Pairing

    /// Redeems the one-time code from the server's Settings → "Pair the mobile app".
    func pair(address: String, code: String, model: AppModel) async {
        var s = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if !s.contains("://") { s = "https://" + s }
        while s.hasSuffix("/") { s.removeLast() }
        guard URL(string: s)?.host() != nil else { status = String(localized: "Enter a valid server address."); return }
        do {
            let r = try await request(base: s, token: nil, "/api/pair/redeem", "POST", .object(["code": .string(code.trimmingCharacters(in: .whitespacesAndNewlines))]))
            guard let token = r?["token"]?.stringValue else { throw HTTPError(status: 200) }
            save(Remote(mode: "remote", base: s, token: token, user: r?["user"]))
            base = nil
            renewed = true
            note("paired with \(host)")
            run(model)
        } catch let e as HTTPError where e.status == 400 {
            status = String(localized: "That code didn't work. Codes last 5 minutes and work once, so get a fresh one.")
        } catch {
            failed(error)
        }
    }

    func disconnect() {
        save(Remote(mode: "local"))
        base = nil
        status = ""
        note("disconnected")
    }

    private func save(_ r: Remote) {
        remote = r
        try? FileManager.default.createDirectory(at: Self.remoteFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(r).write(to: Self.remoteFile, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    // MARK: Running

    /// Every minute while the app is open, plus at launch.
    func start(_ model: AppModel) {
        Task {
            while true {
                run(model)
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    /// One pass: renew the token (once per launch), send motion files, sync. Coalesced.
    @discardableResult
    func run(_ model: AppModel) -> Task<Void, Never>? {
        countMotion()
        guard paired else { return nil }
        if let running { return running }
        running = Task {
            if !renewed { await renew() }
            await uploadMotion()
            await sync(model)
            lastCheck = .now
            running = nil
        }
        return running
    }

    /// A change on this device goes up a few seconds later (only when writing; a dry run waits
    /// for the minute).
    func changed(_ model: AppModel) {
        guard writes, paired else { return }
        pushSoon?.cancel()
        pushSoon = Task {
            try? await Task.sleep(for: .seconds(3))
            if !Task.isCancelled { run(model) }
        }
    }

    /// The server hands out a fresh token once the old one is past half its life (GET /api/me).
    private func renew() async {
        guard let r = try? await call("/api/me") else { return }
        renewed = true
        if let token = r["token"]?.stringValue, var remote, token != remote.token {
            remote.token = token
            save(remote)
            note("token renewed")
        }
    }

    // MARK: Motion

    private func motionFiles() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: Self.motionDir.path)) ?? []).filter { $0.hasSuffix(".csv") }.sorted()
    }
    private func countMotion() { motionWaiting = motionFiles().count }

    /// Oldest first. The Watch's file leaves this phone only once the server says both it and its
    /// backup hold it (`canDelete`); until then it stays and goes up again on the next sync. The
    /// first failure stops the pass (offline, the server away, the backup failing).
    /// ponytail: a file the server refuses (400) blocks the ones after it, as in the old app; the
    /// watch only writes valid ones.
    func uploadMotion() async {
        var sent = 0
        for name in motionFiles() {
            let url = Self.motionDir.appending(path: name)
            guard let csv = try? String(contentsOf: url, encoding: .utf8) else { continue }
            do {
                let r = try await call("/api/motion", "PUT", .object(["name": .string(name), "csv": .string(csv)]))
                guard r?["canDelete"] == .bool(true) else {
                    note("motion \(name) kept: the server has not backed it up yet")
                    break
                }
            } catch {
                note("motion \(name) not sent: \(describe(error))")
                break
            }
            try? FileManager.default.removeItem(at: url)
            sent += 1
        }
        if sent > 0 { note("motion: \(sent) sent") }
        countMotion()
    }

    // MARK: State

    private func sync(_ model: AppModel) async {
        do {
            // Nothing changed here since the last sync: one small GET says whether the server moved.
            if let base, (model.root["_ts"]?.numberValue ?? 0) <= base.ts, let r = try await call("/api/data/rev") {
                let wid = r["wid"]?.stringValue
                if Int(r["rev"]?.numberValue ?? -1) == base.rev, base.wid == nil || wid == nil || wid == base.wid {
                    status = String(localized: "Up to date")
                    return
                }
            }
            // A dry run is worked out again only when either side moved since the last one.
            if !writes, let r = try await call("/api/data/rev") {
                let key = "\(r["rev"]?.numberValue ?? 0)|\(r["wid"]?.stringValue ?? "")|\(model.root["_ts"]?.numberValue ?? 0)"
                if key == lastDryRun { return }
                lastDryRun = key
            }
            let res = try await call("/api/data")
            let rev = Int(res?["rev"]?.numberValue ?? 0)
            let server = res?["state"]?.object
            let local = model.root   // read after the wait: what is here now
            let plan = SyncPlan.decide(base: base, localTs: local["_ts"]?.numberValue ?? 0, rev: rev, server: server)
            guard writes else { try dryRun(plan, local, server, rev); return }
            switch plan {
            case .upToDate:
                status = String(localized: "Up to date")
            case .push:
                if server == nil { base = .init(rev: rev, wid: nil, ts: 0) }
                try await push(model)
            case .adopt:
                guard let server else { return }
                model.takeServerCopy(server)
                base = .init(rev: rev, wid: server["_wid"]?.stringValue, ts: server["_ts"]?.numberValue ?? 0)
                note("took the server's copy, rev \(rev)")
                status = String(localized: "Up to date")
            case .merge:
                guard let server else { return }
                try mergeIn(model, server, rev: rev)
                try await push(model)
            }
        } catch {
            failed(error)
        }
    }

    /// Both copies' entries kept (SyncMerge); saved as a change this device now holds, while the
    /// marker keeps the old `ts`, so the merged copy still counts as unsent.
    private func mergeIn(_ model: AppModel, _ server: Object, rev: Int) throws {
        let local = model.root
        var merged = try SyncMerge.merge(local, server)
        merged["active"] = local["active"]   // the running workout never syncs
        model.change { $0 = merged }
        base = .init(rev: rev, wid: server["_wid"]?.stringValue, ts: base?.ts ?? 0)
        note("merged with server rev \(rev)")
    }

    /// Conditional on the revision this copy descends from; a 409 carries the server's copy, which
    /// is merged and pushed once more (twice at most).
    private func push(_ model: AppModel, attempt: Int = 0) async throws {
        var state = model.root
        state["active"] = nil
        var body: Object = ["state": .object(state), "stamped": .bool(true)]
        if let base {
            body["baseRev"] = .number(Double(base.rev))
            if let wid = base.wid { body["baseWid"] = .string(wid) }
        }
        do {
            let r = try await call("/api/data", "PUT", .object(body))
            base = .init(rev: Int(r?["rev"]?.numberValue ?? 0), wid: r?["wid"]?.stringValue, ts: state["_ts"]?.numberValue ?? 0)
            note("pushed, now rev \(base?.rev ?? 0)")
            status = String(localized: "Synced")
        } catch let e as HTTPError where e.status == 409 && attempt < 2 {
            guard let s = e.body?["state"]?.object else { throw e }
            try mergeIn(model, s, rev: Int(e.body?["rev"]?.numberValue ?? 0))
            try await push(model, attempt: attempt + 1)
        }
    }

    /// What a sync would do, written to the log; the merged copy goes to Documents/sync-dryrun.json.
    private func dryRun(_ plan: SyncPlan, _ local: Object, _ server: Object?, _ rev: Int) throws {
        let count = { (o: Object?) in o?["workouts"]?.arrayValue?.count ?? 0 }
        let ids = { (o: Object?) in Set((o?["workouts"]?.arrayValue ?? []).compactMap { $0.object?["id"]?.stringValue }) }
        var line = "dry run: \(plan.rawValue), server rev \(rev), workouts here \(count(local)), server \(count(server))"
        switch plan {
        case .merge:
            guard let server else { break }
            let merged = try SyncMerge.merge(local, server)
            let here = try SyncMerge.changes(merged, since: local), there = try SyncMerge.changes(merged, since: server)
            let dropped = ids(local).union(ids(server)).subtracting(ids(merged)).count
            line += ", merged \(count(merged)), would change \(here) here and \(there) on the server, \(dropped) workouts left out"
            try? JSONEncoder().encode(JSONValue.object(merged)).write(to: Self.dryFile, options: .atomic)
            status = String(localized: "Dry run: would change \(here) here and \(there) on the server")
        case .adopt: status = String(localized: "Dry run: would take the server's copy")
        case .push: status = String(localized: "Dry run: would send this phone's changes")
        case .upToDate: status = String(localized: "Up to date")
        }
        note(line)
    }

    // MARK: HTTP

    struct HTTPError: Error {
        let status: Int
        var body: Object?
    }

    private func call(_ path: String, _ method: String = "GET", _ body: JSONValue? = nil) async throws -> Object? {
        guard let remote, paired else { throw HTTPError(status: 401) }
        return try await request(base: remote.base!, token: remote.token, path, method, body)
    }

    private func request(base: String, token: String?, _ path: String, _ method: String, _ body: JSONValue?) async throws -> Object? {
        guard let url = URL(string: base + path) else { throw HTTPError(status: 0) }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token { req.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        if let body {
            req.httpBody = try JSONEncoder().encode(body)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await session.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        // Not JSON: a login page or a proxy answered in openGym's place.
        guard case .object(let o)? = try? JSONDecoder().decode(JSONValue.self, from: data) else { throw HTTPError(status: status) }
        guard (200..<300).contains(status) else { throw HTTPError(status: status, body: o) }
        return o
    }

    private func describe(_ error: Error) -> String {
        if let e = error as? HTTPError { return "HTTP \(e.status)" }
        return (error as? URLError).map { "network \($0.code.rawValue)" } ?? "\(error)"
    }

    private func failed(_ error: Error) {
        note("failed: \(describe(error))")
        status = switch (error as? HTTPError)?.status {
        case 401?: String(localized: "The server refused this phone. Pair it again.")
        case let s? where s > 0: String(localized: "The server answered with an error (\(s)).")
        default: String(localized: "The server could not be reached.")
        }
    }

    /// One line to the unified log and to Documents/sync-log.txt (the last 300 lines).
    private func note(_ line: String) {
        Self.log.info("\(line, privacy: .public)")
        let stamped = "\(Date.now.formatted(.iso8601)) \(line)"
        let old = (try? String(contentsOf: Self.logFile, encoding: .utf8))?.split(separator: "\n").suffix(299).map(String.init) ?? []
        try? (old + [stamped]).joined(separator: "\n").appending("\n").write(to: Self.logFile, atomically: true, encoding: .utf8)
    }
}
