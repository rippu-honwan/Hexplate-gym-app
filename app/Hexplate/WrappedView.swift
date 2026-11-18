import HexplateCore
import SwiftUI
import UserNotifications

/* "Your year" (openGym Wrapped.jsx, WrappedEntry.jsx, lib/wrapped-cards.js, wrapped-notify.js): the
   year's numbers (HexplateCore Wrapped) as full-screen story cards, each one a picture to share.
   Ways in: Home's card from Dec 1 to Jan 31, a row per year in Stats, and the one notification on
   Dec 1 at 18:00. Only `wrapped = {opened, dismissed, phone}` and `wrappedBody` are stored. */

struct WrappedCard: Identifiable {
    struct Tile { let label: String, value: String, wide: Bool }
    let id: String
    let kicker: String
    var big = "", unit = "", bigIsText = false
    var title = ""
    var lines: [String] = []
    var bars: [Int]?, barPeak = 0
    var tiles: [Tile]?
    var hideable = false
}

enum WrappedCards {
    static func nf(_ n: Double, _ maxDigits: Int = 0) -> String {
        n.formatted(.number.precision(.fractionLength(0...maxDigits)).locale(Theme.locale))
    }
    static func count(_ n: Double) -> String { nf(n, n < 10 && n.truncatingRemainder(dividingBy: 1) != 0 ? 1 : 0) }
    static func plural(_ one: String, _ other: String, _ n: Double, _ args: CustomStringConvertible...) -> String {
        var s = String(localized: String.LocalizationValue(n == 1 ? one : other))
        for (i, a) in args.enumerated() { s = s.replacingOccurrences(of: "{\(i)}", with: a.description) }
        return s
    }
    static func hours(_ ms: Double) -> Double { let h = ms / 3_600_000; return h < 10 ? (h * 10).rounded() / 10 : h.rounded() }
    static func volume(_ v: Double, _ unit: String) -> (value: String, unit: String) {
        if unit == "lb" { return (v >= 10000 ? v.formatted(.number.notation(.compactName).precision(.fractionLength(0...1)).locale(Theme.locale)) : nf(v), "lb") }
        if v >= 1000 { let t = v / 1000; return (nf(t, t < 100 ? 1 : 0), "t") }
        return (nf(v), "kg")
    }
    static func date(_ iso: String) -> String {
        Day.date(iso)?.formatted(.dateTime.month(.abbreviated).day().locale(Theme.locale)) ?? iso
    }
    static var calendar: Calendar { var c = Calendar(identifier: .gregorian); c.locale = Theme.locale; return c }

    static let thing: [String: (String, String)] = [
        "eiffel": ("That is {0} Eiffel Tower. Gustave would be proud.", "That is {0} Eiffel Towers. Gustave would be proud."),
        "iss": ("That is {0} International Space Station. Houston, we have gains.", "That is {0} International Space Stations. Houston, we have gains."),
        "whale": ("That is {0} blue whale. Lifted. By you.", "That is {0} blue whales. Lifted. By you."),
        "trex": ("That is {0} T. rex. Tiny arms, huge respect.", "That is {0} T. rexes. Tiny arms, huge respect."),
        "elephant": ("That is {0} elephant. They never forget, neither will your legs.", "That is {0} elephants. They never forget, neither will your legs."),
        "car": ("That is {0} car. Who needs a jack?", "That is {0} cars. Who needs a jack?"),
        "piano": ("That is {0} grand piano. Movers hate this one trick.", "That is {0} grand pianos. Movers hate this one trick."),
        "panda": ("That is {0} giant panda. Bamboo not included.", "That is {0} giant pandas. Bamboo not included."),
        "cat": ("That is {0} house cat. It did not approve.", "That is {0} house cats. None of them approved."),
    ]
    static let daypart: [String: String] = [
        "morning": "Mostly in the morning. The early bird gets the barbell.",
        "midday": "Mostly around lunch. Who needs a lunch break anyway?",
        "afternoon": "Mostly in the afternoon. The sweet spot.",
        "evening": "Mostly in the evening. Work, then work out.",
        "night": "Mostly late at night. The gym is all yours.",
    ]
    static let personality: [String: (String, String)] = [
        "early": ("Early bird", "Most of your sessions started before 9. The sun was still catching up."),
        "night": ("Night owl", "Most of your sessions started after 8 pm. The quiet gym is your gym."),
        "legs": ("Leg-day loyalist", "You never skipped leg day. Stairs fear you."),
        "streak": ("Clockwork", "Week after week after week. Your calendar knows your name."),
        "records": ("Record breaker", "So many new bests, your trophy shelf needs a trophy shelf."),
        "weekend": ("Weekend warrior", "Saturdays and Sundays are for lifting. Brunch can wait."),
        "cardio": ("Cardio comet", "Your heart is in great shape. Literally."),
        "marathon": ("In it for the long haul", "Long sessions, no rush. The gym is basically your second home."),
        "quick": ("In and out", "Short, sharp sessions. Efficiency is your love language."),
        "explorer": ("Explorer", "So many different exercises, boredom never stood a chance."),
        "upper": ("Upper-body enthusiast", "Chest, shoulders, arms. The mirror approves."),
        "steady": ("Steady and sure", "No drama, just showing up. That is how it is done."),
    ]

    /// The cards for one year, in Wrapped.cards' order, as words.
    // ponytail: weights use the profile unit (no per-exercise exUnit in the app yet); no muscle map on the top card.
    static func make(_ st: Wrapped.Stats, catalog: ExerciseCatalog) -> [WrappedCard] {
        let y = String(st.year), unit = st.unit
        let exName = { (id: String, fallback: String?) in catalog[id]?.displayName ?? fallback ?? id }
        let p = personality[Wrapped.personality(st)] ?? personality["steady"]!
        let (pName, pLine) = (tr(p.0), tr(p.1))
        var out: [WrappedCard] = []
        for id in Wrapped.cards(st) {
            switch id {
            case "intro":
                out.append(WrappedCard(id: id, kicker: tr("Your year in Hexplate"), big: y, title: tr("Grab a shake. This one is all about you."), lines: [tr("Tap to start")]))
            case "workouts":
                out.append(WrappedCard(id: id, kicker: tr("Showing up"), big: nf(Double(st.workouts)), title: tr("Workouts this year"), lines: [
                    st.perWeek >= 0.95 ? tr("About {0} a week. Like clockwork.", nf(st.perWeek, 1))
                        : tr("One every {0} weeks or so. Every single one counted.", nf(max(2, (1 / st.perWeek).rounded()))),
                ]))
            case "time":
                let h = hours(st.ms), movies = Int(st.ms / 7_200_000)
                let avg = Duration.milliseconds(st.avgMs).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
                out.append(WrappedCard(id: id, kicker: tr("Time well spent"), big: nf(h, h < 10 ? 1 : 0), title: tr("Hours of training"),
                                       lines: [tr("Your average session: {0}", avg)] + (movies >= 2 ? [tr("That is {0} movies you did not watch. Worth it.", nf(Double(movies)))] : [])))
            case "volume":
                let v = volume(st.volume, unit)
                let line = Wrapped.comparison(st.volumeKg).flatMap { c in thing[c.key].map { plural($0.0, $0.1, c.count, count(c.count)) } }
                out.append(WrappedCard(id: id, kicker: tr("Heavy lifting"), big: v.value, unit: v.unit, title: tr("Lifted in total"), lines: line.map { [$0] } ?? []))
            case "streak":
                let w = st.streak.weeks
                var lines: [String] = []
                if w > 1, let from = st.streak.from, let to = st.streak.to { lines.append(tr("From {0} to {1}.", date(from), date(Day.adding(6, to: to) ?? to))) }
                lines.append(w >= 12 ? tr("That is not a streak any more. That is a habit.") : tr("Every long streak starts with one week."))
                out.append(WrappedCard(id: id, kicker: tr("Consistency"), big: nf(Double(w)),
                                       title: plural("Week with a workout, your longest run", "Weeks in a row with a workout, your longest run", Double(w)), lines: lines))
            case "top":
                guard let t = st.topExercise else { continue }
                out.append(WrappedCard(id: id, kicker: tr("Your signature move"), big: exName(t.id, t.name), bigIsText: true,
                                       title: plural("{0} set this year", "{0} sets this year", Double(t.sets), nf(Double(t.sets))),
                                       lines: st.topMuscle.map { [tr("Most trained muscle: {0}", catalog.muscleName($0.id))] } ?? []))
            case "records":
                var lines: [String] = []
                if let b = st.biggestPr {
                    lines.append(tr("Biggest: {0}, {1}", exName(b.id, nil), Format.number(b.w) + " " + unit))
                    if let g = b.gain, g > 0 { lines.append(tr("That is {0} more than your best before {1}.", Format.number(g) + " " + unit, y)) }
                }
                out.append(WrappedCard(id: id, kicker: tr("Records"), big: nf(Double(st.prs)), title: tr("New personal records"), lines: lines))
            case "rhythm":
                guard let d = st.favDay else { continue }
                out.append(WrappedCard(id: id, kicker: tr("Your rhythm"), big: calendar.weekdaySymbols[d.day], bigIsText: true, title: tr("Your favourite day to train"),
                                       lines: st.daypart.flatMap { daypart[$0.part] }.map { [tr($0)] } ?? []))
            case "month":
                guard let m = st.bestMonth else { continue }
                out.append(WrappedCard(id: id, kicker: tr("Peak season"), big: calendar.standaloneMonthSymbols[m.month], bigIsText: true, title: tr("Your best month"),
                                       lines: [plural("{0} workout", "{0} workouts", Double(m.n), nf(Double(m.n)))], bars: st.months, barPeak: m.month))
            case "body":
                guard let b = st.body else { continue }
                let steady = abs(b.delta) < (unit == "lb" ? 1 : 0.5)
                out.append(WrappedCard(id: id, kicker: tr("Body weight"), big: steady ? "±0" : (b.delta > 0 ? "+" : "−") + Format.number(abs(b.delta)), unit: steady ? "" : unit,
                                       title: tr(steady ? "Steady all year" : b.delta < 0 ? "Down since your first weigh-in of the year" : "Up since your first weigh-in of the year"),
                                       lines: [tr("From {0} to {1}.", Format.number(b.from) + " " + unit, Format.number(b.to) + " " + unit),
                                               tr("Bodies change. You kept showing up, and that is the part that counts.")], hideable: true))
            case "personality":
                out.append(WrappedCard(id: id, kicker: tr("Your training personality"), big: pName, bigIsText: true, title: pLine))
            case "summary":
                let v = volume(st.volume, unit), h = hours(st.ms)
                var tiles = [WrappedCard.Tile(label: tr("Workouts"), value: nf(Double(st.workouts)), wide: false)]
                if st.ms > 0 { tiles.append(.init(label: tr("Hours"), value: nf(h, h < 10 ? 1 : 0), wide: false)) }
                if st.volume > 0 { tiles.append(.init(label: tr("Lifted in total"), value: v.value + " " + v.unit, wide: false)) }
                tiles.append(.init(label: tr("Longest streak"), value: plural("{0} week", "{0} weeks", Double(st.streak.weeks), nf(Double(st.streak.weeks))), wide: false))
                if st.prs > 0 { tiles.append(.init(label: tr("Records"), value: "🏆 " + nf(Double(st.prs)), wide: false)) }
                if let t = st.topExercise { tiles.append(.init(label: tr("Signature move"), value: exName(t.id, t.name), wide: true)) }
                tiles.append(.init(label: tr("Training personality"), value: pName, wide: true))
                out.append(WrappedCard(id: id, kicker: tr("Your {0} in Hexplate", y), title: tr("That is a wrap. See you in {0}.", String(st.year + 1)), tiles: tiles))
            default: continue
            }
        }
        return out
    }
}

/// One card's face: the stories show it, and the share picture is the same view rendered.
struct WrappedCardFace: View {
    let card: WrappedCard
    let year: Int
    var hideBody: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(card.kicker).font(.headline).foregroundStyle(Color.accentColor).lineLimit(1)
                Spacer()
                if card.id != "intro" {
                    Text(verbatim: String(year)).font(.subheadline.bold()).padding(.horizontal, 12).padding(.vertical, 4)
                        .background(Color.white.opacity(0.12), in: Capsule())
                }
            }
            Spacer(minLength: 24)
            VStack(alignment: .leading, spacing: 12) {
                if !card.big.isEmpty {
                    if card.bigIsText {
                        Text(card.big).font(.system(size: 46, weight: .heavy)).foregroundStyle(Color.accentColor).lineLimit(3).minimumScaleFactor(0.5)
                    } else {
                        (Text(card.big).font(.system(size: 96, weight: .heavy).monospacedDigit()).foregroundStyle(Color.accentColor)
                            + Text(card.unit.isEmpty ? "" : " " + card.unit).font(.system(size: 36, weight: .bold)).foregroundStyle(.secondary))
                            .lineLimit(1).minimumScaleFactor(0.4)
                    }
                }
                if !card.title.isEmpty { Text(card.title).font(card.tiles == nil ? .title2.bold() : .title.bold()) }
                ForEach(card.lines, id: \.self) { Text($0).font(.body).foregroundStyle(.secondary) }
                if let bars = card.bars { Bars(bars: bars, peak: card.barPeak).frame(height: 140).padding(.top, 12) }
                if let tiles = card.tiles { Tiles(tiles: tiles).padding(.top, 12) }
                if card.hideable, let hideBody {
                    Button("Leave body weight out of my year", action: hideBody).font(.footnote).padding(.top, 8)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 24)
            Divider().overlay(Color.white.opacity(0.2))
            Text(verbatim: "Hexplate").font(.headline).foregroundStyle(.secondary).padding(.top, 12)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background {
            ZStack {
                Color.black
                Circle().fill(Color.accentColor.opacity(0.22)).frame(width: 420).offset(x: 180, y: -320).blur(radius: 40)
                Circle().fill(Color.accentColor.opacity(0.1)).frame(width: 260).offset(x: -160, y: 260).blur(radius: 40)
            }
        }
        .clipped()
        .accessibilityElement(children: .contain)
    }

    private struct Bars: View {
        let bars: [Int], peak: Int
        var body: some View {
            let top = max(1, bars.max() ?? 1)
            let letters = WrappedCards.calendar.veryShortStandaloneMonthSymbols
            HStack(alignment: .bottom, spacing: 6) {
                ForEach(bars.indices, id: \.self) { i in
                    VStack(spacing: 6) {
                        GeometryReader { g in
                            VStack { Spacer(minLength: 0)
                                RoundedRectangle(cornerRadius: 4).fill(i == peak ? Color.accentColor : Color.accentColor.opacity(0.35))
                                    .frame(height: max(6, g.size.height * Double(bars[i]) / Double(top)))
                            }
                        }
                        Text(letters[i % 12]).font(.caption2.weight(i == peak ? .bold : .regular)).foregroundStyle(i == peak ? Color.accentColor : .secondary)
                    }
                }
            }
            .accessibilityHidden(true)
        }
    }

    private struct Tiles: View {
        let tiles: [WrappedCard.Tile]
        var body: some View {
            let small = tiles.filter { !$0.wide }, wide = tiles.filter(\.wide)
            VStack(spacing: 10) {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                    ForEach(small.indices, id: \.self) { tile(small[$0]) }
                }
                ForEach(wide.indices, id: \.self) { tile(wide[$0]) }
            }
        }
        func tile(_ t: WrappedCard.Tile) -> some View {
            VStack(alignment: .leading, spacing: 4) {
                Text(t.label).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Text(t.value).font(.title3.bold()).lineLimit(t.wide ? 2 : 1).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 14))
            .accessibilityElement(children: .combine)
        }
    }
}

/// The year as full-screen stories: swipe or tap through, share any card as a 9:16 picture.
struct WrappedStory: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let year: Int
    @State private var index = 0
    @State private var picture: Image?

    var body: some View {
        let st = model.history.flatMap { Wrapped.stats(model.root, history: $0, year: year, now: Date()) }
        let cards = st.map { WrappedCards.make($0, catalog: model.catalog) } ?? []
        VStack(spacing: 12) {
            HStack(spacing: 4) {
                ForEach(cards.indices, id: \.self) { i in
                    Capsule().fill(i <= index ? Color.white : Color.white.opacity(0.25)).frame(height: 3)
                }
            }
            .accessibilityHidden(true)
            HStack {
                Text(tr("Your {0} in Hexplate", year)).font(.headline)
                Spacer()
                if let picture, cards.indices.contains(index) {
                    ShareLink(item: picture, preview: SharePreview(cards[index].kicker, image: picture)) { Image(systemName: "square.and.arrow.up") }
                        .accessibilityLabel(Text("Share this card"))
                }
                Button("Close", systemImage: "xmark") { dismiss() }.labelStyle(.iconOnly).padding(.leading, 12)
            }
            .font(.title3)
            TabView(selection: $index) {
                ForEach(cards.indices, id: \.self) { i in
                    WrappedCardFace(card: cards[i], year: year, hideBody: { model.set("wrappedBody", .bool(false)) })
                        .clipShape(RoundedRectangle(cornerRadius: 24))
                        .contentShape(Rectangle())
                        .onTapGesture { withAnimation { index = min(cards.count - 1, index + 1) } }
                        .accessibilityLabel(tr("{0} of {1}", i + 1, cards.count))
                        .tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
        }
        .padding()
        .background(Color.black.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .task(id: "\(index)|\(cards.count)") {
            guard cards.indices.contains(index) else { return }
            let r = ImageRenderer(content: WrappedCardFace(card: cards[index], year: year).frame(width: 360, height: 640).environment(\.colorScheme, .dark))
            r.scale = 3
            picture = r.uiImage.map { Image(uiImage: $0) }
        }
        .task(id: st != nil) {
            // Opened once is enough for Home's card to go.
            guard st != nil, !Wrapped.yearList(model.root["wrapped"]?.object?["opened"]).contains(year) else { return }
            model.change { $0["wrapped"] = Wrapped.adding($0, "opened", year: year) }
        }
    }
}

/// Home, Dec 1 to Jan 31: "Your 2026 in Hexplate is ready", until opened or put away.
struct WrappedHomeSection: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        if let year = Wrapped.homeCardYear(model.root, now: Date()) {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text(tr("Your {0} in Hexplate is ready 🎉", year)).font(.headline)
                    Text("Workouts, records and one very honest personality test. Tap to see your year.").foregroundStyle(.secondary)
                }
                Button("Show me my year", systemImage: "sparkles") { model.wrappedYear = year }
            } header: {
                HStack {
                    Text("Your year in Hexplate")
                    Spacer()
                    Button("Not now", systemImage: "xmark") { model.change { $0["wrapped"] = Wrapped.adding($0, "dismissed", year: year) } }
                        .labelStyle(.iconOnly)
                }
            }
        }
    }
}

/// Stats: a row for every year with workouts.
struct WrappedYearsSection: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        let years = Wrapped.years(model.root)
        if !years.isEmpty {
            Section {
                ForEach(years, id: \.self) { y in
                    Button { model.wrappedYear = y } label: { Label(tr("Your {0} in Hexplate", y), systemImage: "sparkles") }
                }
            } header: {
                Text("Your year")
            } footer: {
                Text("Your year in Hexplate as stories, every card ready to share.")
            }
        }
    }
}

extension Int: @retroactive Identifiable { public var id: Int { self } }

/// The season's one notification, Dec 1 at 18:00 (Wrapped.notifyAt). Never asks for permission:
/// without it there is Home's card. `wrapped.phone` remembers the planned year.
// ponytail: a tap only opens the app, where Home's card is waiting; open the stories directly if asked.
@MainActor
enum WrappedNotify {
    static let id = "wrapped"

    static func sync(_ model: AppModel) {
        let s = model.root, center = UNUserNotificationCenter.current()
        let phone = s["wrapped"]?.object?["phone"]?.numberValue.map(Int.init)
        guard Wrapped.notifyOn(s) else {
            center.removePendingNotificationRequests(withIdentifiers: [id])
            if phone != nil { model.change { $0["wrapped"] = setPhone($0, nil) } }
            return
        }
        guard let at = Wrapped.notifyAt(s, now: Date()) else { return }
        let year = Calendar(identifier: .gregorian).component(.year, from: at)
        Task {
            guard await center.notificationSettings().authorizationStatus == .authorized else { return }
            let content = UNMutableNotificationContent()
            content.title = tr("Your {0} in Hexplate is ready 🎉", year)
            content.body = String(localized: "Workouts, records and one very honest personality test. Tap to see your year.")
            content.sound = .default
            let when = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day, .hour, .minute], from: at)
            try? await center.add(UNNotificationRequest(identifier: id, content: content, trigger: UNCalendarNotificationTrigger(dateMatching: when, repeats: false)))
            if phone != year { model.change { $0["wrapped"] = setPhone($0, year) } }
        }
    }

    /// `wrapped` as it is, with `phone` set.
    private static func setPhone(_ s: [String: JSONValue], _ year: Int?) -> JSONValue {
        var w = s["wrapped"]?.object ?? [:]
        w["phone"] = year.map { .number(Double($0)) } ?? .null
        return .object(w)
    }
}
