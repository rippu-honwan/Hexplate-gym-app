import HexplateCore
import SwiftUI

/// Month grid respecting `weekStart`, highlighting trained days with tap-to-open navigation.
struct TrainingCalendarView: View {
    let byDay: [String: [String]]
    let today: String
    let weekStart: Int
    let onSelectDay: (String, [String]) -> Void

    @Environment(\.colorScheme) private var scheme
    @State private var monthKey: String

    init(byDay: [String: [String]], today: String, weekStart: Int, onSelectDay: @escaping (String, [String]) -> Void) {
        self.byDay = byDay
        self.today = today
        self.weekStart = weekStart
        self.onSelectDay = onSelectDay
        _monthKey = State(initialValue: Self.monthPrefix(of: today))
    }

    private static let gregorian = Calendar(identifier: .gregorian)

    private static func monthPrefix(of iso: String) -> String {
        let prefix = String(iso.prefix(7))
        return Challenges.isMonthKey(prefix) ? prefix : "2026-01"
    }

    private var currentMonthKey: String { Self.monthPrefix(of: today) }

    private var firstDate: Date? { Day.date(monthKey + "-01") }

    private var monthTitle: String {
        firstDate?.formatted(.dateTime.year().month(.wide).locale(Theme.locale)) ?? monthKey
    }

    /// Narrow weekday letters in the profile's `weekStart` order (0 = Sun, 1 = Mon).
    private var weekdayHeaders: [String] {
        // 2026-01-04 is a known Sunday.
        guard let sunday = Day.date("2026-01-04") else { return [] }
        return (0..<7).compactMap { offset in
            let weekdayOffset = (weekStart + offset) % 7
            return Self.gregorian.date(byAdding: .day, value: weekdayOffset, to: sunday)?
                .formatted(.dateTime.weekday(.narrow).locale(Theme.locale))
        }
    }

    /// Weeks of 7 optional day numbers (`nil` for leading/trailing empty cells).
    private var weeks: [[Int?]] {
        guard let first = firstDate,
              let range = Self.gregorian.range(of: .day, in: .month, for: first) else { return [] }
        let weekday = Self.gregorian.component(.weekday, from: first) - 1 // 0 = Sun ... 6 = Sat
        let leading = (weekday - weekStart + 7) % 7
        var cells: [Int?] = Array(repeating: nil, count: leading) + range.map { Optional($0) }
        let remainder = cells.count % 7
        if remainder != 0 {
            cells.append(contentsOf: Array(repeating: nil, count: 7 - remainder))
        }
        return stride(from: 0, to: cells.count, by: 7).map { Array(cells[$0..<($0 + 7)]) }
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Button {
                    monthKey = Challenges.shift(monthKey, -1)
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.body.weight(.semibold))
                        .frame(width: 44, height: 44)
                        .contentShape(.rect)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Previous month")

                Spacer(minLength: 0)

                Text(monthTitle)
                    .font(.headline)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .accessibilityAddTraits(.isHeader)

                Spacer(minLength: 0)

                Button {
                    monthKey = Challenges.shift(monthKey, 1)
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.body.weight(.semibold))
                        .frame(width: 44, height: 44)
                        .contentShape(.rect)
                }
                .buttonStyle(.borderless)
                .disabled(monthKey >= currentMonthKey)
                .accessibilityLabel("Next month")
            }

            Grid(horizontalSpacing: 4, verticalSpacing: 6) {
                GridRow {
                    ForEach(Array(weekdayHeaders.enumerated()), id: \.offset) { _, letter in
                        Text(letter)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.5)
                            .frame(maxWidth: .infinity)
                    }
                }
                .accessibilityHidden(true)

                ForEach(Array(weeks.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(0..<7, id: \.self) { col in
                            if let day = row[col] {
                                dayCell(day: day)
                            } else {
                                Color.clear
                                    .frame(maxWidth: .infinity)
                                    .aspectRatio(1, contentMode: .fit)
                                    .accessibilityHidden(true)
                            }
                        }
                    }
                }
            }
        }
        .padding(.vertical, 4)
        .onChange(of: today) { oldToday, newToday in
            let oldMonth = Self.monthPrefix(of: oldToday)
            let newMonth = Self.monthPrefix(of: newToday)
            if monthKey == oldMonth && newMonth != oldMonth {
                monthKey = newMonth
            }
        }
    }

    @ViewBuilder
    private func dayCell(day: Int) -> some View {
        let iso = "\(monthKey)-\(String(format: "%02d", day))"
        let ids = byDay[iso] ?? []
        let trained = !ids.isEmpty
        let isToday = iso == today
        let isFuture = iso > today
        let trainedInk: Color = scheme == .dark ? .black : .white

        let cellContent = Text(verbatim: "\(day)")
            .font(.callout.weight(isToday || trained ? .semibold : .regular))
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .padding(3)
            .foregroundStyle(
                trained ? AnyShapeStyle(trainedInk)
                    : isToday ? AnyShapeStyle(.primary)
                    : isFuture ? AnyShapeStyle(.tertiary)
                    : AnyShapeStyle(.secondary)
            )
            .frame(maxWidth: .infinity)
            .aspectRatio(1, contentMode: .fit)
            .background {
                if trained {
                    Circle().fill(Theme.accent)
                } else if isToday {
                    Circle().strokeBorder(Theme.accent, lineWidth: 1.5)
                }
            }
            .overlay(alignment: .bottom) {
                if ids.count > 1 {
                    HStack(spacing: 2) {
                        Circle().fill(trainedInk.opacity(0.85)).frame(width: 3, height: 3)
                        Circle().fill(trainedInk.opacity(0.85)).frame(width: 3, height: 3)
                    }
                    .padding(.bottom, 3)
                }
            }

        if trained {
            Button {
                onSelectDay(iso, ids)
            } label: {
                cellContent.contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(spokenLabel(iso: iso, count: ids.count))
            .accessibilityAddTraits(.isButton)
        } else {
            cellContent
                .accessibilityLabel(spokenLabel(iso: iso, count: 0))
        }
    }

    private func spokenLabel(iso: String, count: Int) -> String {
        let dateText = Day.date(iso)?.formatted(.dateTime.day().month(.wide).locale(Theme.locale)) ?? iso
        guard count > 0 else { return dateText }
        let countText = count == 1 ? String(localized: "1 workout") : String(localized: "\(count) workouts")
        return "\(dateText), \(countText)"
    }
}
