import HexplateCore
import SwiftUI

/* The week streak and the monthly challenges (openGym Streak.jsx, Challenges.jsx): Home's
   challenge card and its parties, Stats' streak with its badges and the trophy shelf. The
   numbers come from HexplateCore (WidgetData.streak, Challenges); only what was shown and
   which picks were made is stored (streakSeen, challenges). */

/// An openGym "{0}" template, translated, with its arguments in.
func tr(_ key: String, _ args: CustomStringConvertible...) -> String {
    var s = String(localized: String.LocalizationValue(key))
    for (i, a) in args.enumerated() { s = s.replacingOccurrences(of: "{\(i)}", with: a.description) }
    return s
}

enum Medal {
    /// Bronze to legend: the streak's five milestones take one each, a month's three challenges the first three.
    static let tiers: [Color] = [
        Color(red: 0.80, green: 0.50, blue: 0.20), Color(red: 0.75, green: 0.75, blue: 0.78), Color(red: 1.0, green: 0.84, blue: 0.04),
        Color(red: 0.55, green: 0.85, blue: 0.95), Color(red: 0.75, green: 0.35, blue: 0.95),
    ]
    static func view(_ tier: Int?) -> some View {
        Image(systemName: tier == nil ? "medal" : "medal.fill")
            .foregroundStyle(tier.map { tiers[min($0, tiers.count - 1)] } ?? Color.secondary)
    }
}

private func monthLabel(_ key: String, short: Bool = false) -> String {
    guard let d = Day.date(key + "-15") else { return key }
    return d.formatted(.dateTime.month(short ? .abbreviated : .wide).year().locale(Theme.locale))
}

/// A party line, gone after a while or on a tap.
private struct Party: View {
    let text: String
    let icon: AnyView
    let close: () -> Void

    var body: some View {
        Button(action: close) {
            HStack(spacing: 12) {
                icon.font(.title)
                Text(text).font(.headline).multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.success, trigger: text)
        .task { try? await Task.sleep(for: .seconds(7)); close() }
    }
}

// MARK: - Home

/// Home: a week done or a badge reached, said once (`streakSeen` remembers it, synced).
struct StreakPartySection: View {
    @Environment(AppModel.self) private var model
    @State private var party: (kind: String, weeks: Int)?

    var body: some View {
        let s = model.root, today = model.today
        let info = WidgetData.streak(s, today: today)
        let tally = Schedule.weekTally(s, today: today)
        let c = WidgetData.celebration(s, info, done: tally.done, planned: tally.planned)
        Group {
            if let party {
                Section {
                    Party(text: party.kind == "badge" ? tr("{0} weeks in a row. New badge!", party.weeks) : tr("Week done. The flame lives on."),
                          icon: party.kind == "badge"
                              ? AnyView(Medal.view(WidgetData.badges.firstIndex(of: party.weeks) ?? 2))
                              : AnyView(Image(systemName: "flame.fill").foregroundStyle(.orange))) { self.party = nil }
                }
            }
        }
        .task(id: c?.seen) {
            guard let c else { return }
            // Remembered at once: it shows for this visit, and never again.
            model.change { $0["streakSeen"] = c.seen }
            party = (c.kind, c.weeks)
        }
    }
}

/// Home: this month's challenges. The × hides them until next month; off with Monthly challenges.
struct ChallengesSection: View {
    @Environment(AppModel.self) private var model
    @State private var party: (text: String, gold: Bool, n: Int)?

    private var key: String { String(model.today.prefix(7)) }
    private var num: (Double) -> String { Challenges.number(Theme.locale) }

    var body: some View {
        let s = model.root
        if let history = model.history, Challenges.on(s), !history.workouts.isEmpty, s["challengesHidden"] != .string(key) {
            let m = Challenges.month(s, history: history, key: key)
            let progress = Challenges.progress(s, history: history, month: m)
            let done = progress.filter(\.done).count
            let gold = !progress.isEmpty && done == progress.count
            let prev = Challenges.clean(s["challenges"])[Challenges.shift(key, -1)]
            let newMonth = (Int(model.today.suffix(2)) ?? 99) <= 3 && prev.map { p in !p.picked.isEmpty && !p.picked.allSatisfy { p.done.contains($0.id) } } == true
            Section {
                ForEach(progress, id: \.id) { ChallengeRow(p: $0, unit: model.settings.unit, num: num) }
                if gold {
                    Label("Gold month. Take a bow.", systemImage: "crown.fill")
                } else if newMonth {
                    Text("New month, new challenges.").foregroundStyle(.secondary)
                }
                if let party {
                    Party(text: party.gold ? tr("All three done. Gold month!") : tr("Challenge done: {0}. New badge!", party.text),
                          icon: party.gold ? AnyView(Image(systemName: "crown.fill").foregroundStyle(Medal.tiers[2])) : AnyView(Medal.view(min(2, party.n - 1)))) { self.party = nil }
                }
            } header: {
                HStack {
                    Text("This month’s challenges")
                    Spacer()
                    Text(verbatim: "\(monthLabel(key)) · \(tr("{0} of {1} done", done, progress.count))")
                    Button("Hide until next month", systemImage: "xmark") { model.set("challengesHidden", .string(key)) }
                        .labelStyle(.iconOnly)
                }
            }
            .task(id: "\(key)|\(m.stored)|\(Challenges.newlyDone(m, progress).joined(separator: ","))") {
                keep(m, progress, history: history)
            }
        }
    }

    /// The month's picks once shown, and every challenge reached as done (its badge); last month's
    /// reached on its last evening and only seen now still count, quietly.
    private func keep(_ m: Challenges.Current, _ progress: [Challenges.Progress], history: History) {
        let fresh = Challenges.newlyDone(m, progress)
        let now = model.now
        if !fresh.isEmpty {
            model.change { Challenges.save(&$0, key: key, picked: m.picked, done: fresh, now: now) }
            let stored = Challenges.clean(model.root["challenges"])[key]
            let gold = stored.map { s in !s.picked.isEmpty && s.picked.allSatisfy { s.done.contains($0.id) } } ?? false
            if let p = progress.first(where: { $0.id == fresh[0] }) {
                let t = Challenges.title(Challenges.Pick(id: p.id, n: p.n, u: p.u), unit: model.settings.unit, num: num)
                party = (tr(t.key, t.arg ?? t.count.map(num) ?? ""), gold, stored?.done.count ?? 1)
            }
        } else if !m.stored {
            model.change { Challenges.save(&$0, key: key, picked: m.picked, now: now) }
        }
        let prevKey = Challenges.shift(key, -1)
        if let pm = Challenges.clean(model.root["challenges"])[prevKey], !pm.picked.isEmpty {
            let pc = Challenges.Current(key: prevKey, picked: pm.picked, done: pm.done, stored: true)
            let late = Challenges.newlyDone(pc, Challenges.progress(model.root, history: history, month: pc))
            if !late.isEmpty { model.change { Challenges.save(&$0, key: prevKey, picked: pm.picked, done: late, now: now) } }
        }
    }
}

private struct ChallengeRow: View {
    let p: Challenges.Progress
    let unit: String
    let num: (Double) -> String

    var body: some View {
        let t = Challenges.title(Challenges.Pick(id: p.id, n: p.n, u: p.u), unit: unit, num: num)
        let title = tr(t.key, t.arg ?? t.count.map(num) ?? "")
        HStack(spacing: 12) {
            Image(systemName: p.done ? "checkmark.circle.fill" : p.icon)
                .foregroundStyle(p.done ? Theme.accent : Color.secondary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(title)
                    Spacer()
                    Text(Challenges.count(p, unit: unit, num: num)).font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                }
                ProgressView(value: min(1, max(0, p.pct))).tint(p.done ? Theme.accent : nil)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Stats

/// Stats: the streak, its best, the freezes, the badges and how far the next one is.
struct StreakSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let st = WidgetData.streak(model.root, today: model.today)
        Section {
            HStack(alignment: .center) {
                Image(systemName: "flame.fill").font(.largeTitle).foregroundStyle(st.current > 0 ? Color.orange : Color.secondary)
                Text("\(st.current)").font(.largeTitle.bold().monospacedDigit())
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    Text(tr("Best: {0}", st.best)).foregroundStyle(.secondary)
                    HStack(spacing: 4) {
                        ForEach(0..<WidgetData.freezeMax, id: \.self) { i in
                            Image(systemName: "snowflake").foregroundStyle(i < st.freezes ? Color.cyan : Color.secondary.opacity(0.4))
                        }
                    }
                    .accessibilityElement()
                    .accessibilityLabel(tr("Streak freezes: {0} of {1}", st.freezes, WidgetData.freezeMax))
                }
            }
            HStack {
                ForEach(Array(WidgetData.badges.enumerated()), id: \.offset) { i, b in
                    VStack(spacing: 2) {
                        Medal.view(st.badges.contains(b) ? i : nil).font(.title2)
                        Text("\(b)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            if let next = st.next {
                ProgressView(value: Double(min(st.current, next)), total: Double(next)) {
                    Text(tr("Next badge at {0} weeks.", next)).font(.subheadline)
                } currentValueLabel: {
                    Text(verbatim: "\(st.current) / \(next)")
                }
            }
        } header: {
            Text("Week streak")
        } footer: {
            Text((st.next == nil ? tr("Every badge collected. Legend.") + " " : "")
                 + (st.freezes >= WidgetData.freezeMax ? tr("Freezes full. A missed week uses one, no harm done.")
                    : st.toNextFreeze == 1 ? tr("One more week with a workout earns a freeze.") : tr("{0} more weeks with a workout earn a freeze.", st.toNextFreeze)))
        }
    }
}

/// Stats: the trophy shelf, one row per month with a badge.
struct TrophyShelfSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let shelf = Challenges.shelf(model.root)
        if Challenges.on(model.root) || !shelf.isEmpty {
            Section {
                if shelf.isEmpty {
                    Text("Every challenge you finish puts a badge here, one shelf per month.").foregroundStyle(.secondary)
                }
                ForEach(shelf, id: \.key) { m in
                    HStack {
                        Text(monthLabel(m.key))
                        if m.gold { Image(systemName: "crown.fill").foregroundStyle(Medal.tiers[2]) }
                        Spacer()
                        ForEach(0..<m.done, id: \.self) { i in Medal.view(m.gold ? 2 : min(i, 2)) }
                        ForEach(0..<max(0, m.total - m.done), id: \.self) { _ in Medal.view(nil) }
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel((m.gold ? tr("Gold month") + ": " : "") + tr("{0}: {1} of {2} challenges", monthLabel(m.key), m.done, m.total))
                }
            } header: {
                Text("Trophy shelf")
            }
        }
    }
}
