import XCTest
@testable import WatchCore

final class SetRepCountTests: XCTestCase {
    struct Case: Decodable { let file: String; let reps: Int; let hz: Double; let every25: [Double] }

    /// t and [ax, ay, az] from a motion CSV: a fixture, or the watch's own file (a `# {json}` line first).
    static func read(_ url: URL) throws -> ([Double], [[Double]]) {
        var lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
        if lines.first?.hasPrefix("# ") == true { lines.removeFirst() }
        let head = lines.removeFirst().split(separator: ",").map(String.init)
        let col = ["t", "ax", "ay", "az"].map { head.firstIndex(of: $0)! }
        let rows = lines.map { $0.split(separator: ",").map { Double($0)! } }
        return (rows.map { $0[col[0]] }, (1...3).map { c in rows.map { $0[col[c]] } })
    }

    private func check(_ cases: [Case], in folder: URL) throws {
        for c in cases {
            let (t, axes) = try Self.read(folder.appendingPathComponent(c.file))
            XCTAssertEqual(SetRepCount.count(t: t, axes: axes), c.reps, c.file)
            let (s, hz) = try XCTUnwrap(SetRepCount.project(t: t, axes: axes))
            XCTAssertEqual(hz, c.hz, accuracy: 1e-9, c.file)
            // The main axis' sign is arbitrary: compare up to it.
            let sign: Double = s[0] * c.every25[0] < 0 ? -1 : 1
            let scale = c.every25.map(abs).max() ?? 1
            for (k, v) in c.every25.enumerated() {
                XCTAssertEqual(sign * s[k * 25], v, accuracy: 1e-6 * scale, "\(c.file) sample \(k * 25)")
            }
        }
    }

    /// The same numbers as analysis/rep_count.py on the committed fixtures
    /// (`python3 analysis/rep_count.py --golden Fixtures/set-rep-count.json Fixtures/reps-*.csv Fixtures/fusion-*.csv`).
    func testMatchesThePythonCounter() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "set-rep-count", withExtension: "json", subdirectory: "Fixtures"))
        let cases = try JSONDecoder().decode([Case].self, from: Data(contentsOf: url))
        XCTAssertEqual(cases.count, 5)
        try check(cases, in: url.deletingLastPathComponent())
    }

    /// The user's own recordings stay off the repo. To check them too, write their golden file and run
    /// `HEXPLATE_MOTION=<folder> HEXPLATE_GOLDEN=<json> swift test --filter SetRepCount`.
    func testMatchesThePythonCounterOnLocalData() throws {
        let env = ProcessInfo.processInfo.environment
        guard let dir = env["HEXPLATE_MOTION"], let golden = env["HEXPLATE_GOLDEN"] else { throw XCTSkip("no local motion data") }
        let cases = try JSONDecoder().decode([Case].self, from: Data(contentsOf: URL(fileURLWithPath: golden)))
        try check(cases, in: URL(fileURLWithPath: dir))
    }

    func testAStillWristIsNoRep() {
        let t = (0..<500).map { Double($0) / 50 }
        XCTAssertEqual(SetRepCount.count(t: t, axes: [t.map { _ in 0 }, t.map { _ in 0 }, t.map { _ in 0 }]), 0)
        XCTAssertEqual(SetRepCount.count(t: [0], axes: [[0], [0], [0]]), 0)
    }

    func testCountsCleanReps() {
        // 10 reps, 3 s each, between 3 s of stillness at either end.
        let hz = 50.0, t = (0..<Int(36 * hz)).map { Double($0) / hz }
        let ax = t.map { s in s < 3 || s >= 33 ? 0 : 0.2 * sin(2 * .pi * (s - 3) / 3) }
        // ponytail: 9 here (Python too): the first peak out of stillness stands only half as tall. Real
        // sets show no such bias (mean error +0.05 on 65), so the threshold stays as evaluated.
        XCTAssertEqual(SetRepCount.count(t: t, axes: [ax, ax.map { $0 / 2 }, t.map { _ in 0 }]), 9)
    }
}
