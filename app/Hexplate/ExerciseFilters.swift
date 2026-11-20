import HexplateCore
import SwiftUI

/// The equipment and muscle-group filters (ExerciseGroups) the exercise lists show under their
/// search field: the library and the add / swap pickers. Each takes any number of groups: an
/// exercise passes when it uses one of the equipment picked and trains one of the muscles picked.
struct ExerciseFilter: Equatable {
    var equipment: Set<String> = []
    var muscles: Set<String> = []

    var isOn: Bool { !equipment.isEmpty || !muscles.isEmpty }

    /// A group's label; "None" already means "nothing" elsewhere, so the equipment one gets its own.
    static func label(_ group: String) -> LocalizedStringKey { LocalizedStringKey(group == "None" ? "No equipment" : group) }

    /// The exercises that pass, those whose main muscle was picked before those that only help.
    func apply(_ list: [Exercise], _ c: ExerciseCatalog) -> [Exercise] {
        guard isOn else { return list }
        var main: [Exercise] = [], helping: [Exercise] = []
        for ex in list where equipment.isEmpty || equipment.contains(ExerciseGroups.equipment(of: ex)) {
            if muscles.isEmpty { main.append(ex); continue }
            let tags = ExerciseGroups.muscles(of: ex, catalog: c)
            if muscles.contains(tags[0]) { main.append(ex) } else if tags.contains(where: muscles.contains) { helping.append(ex) }
        }
        return main + helping
    }

    /// 0 when the exercise's main muscle was picked (or none was), 1 when it only helps.
    func tier(_ ex: Exercise, _ c: ExerciseCatalog) -> Int {
        muscles.isEmpty || muscles.contains(ExerciseGroups.muscle(of: ex, catalog: c)) ? 0 : 1
    }
}

/// A filtered list as two sections: the staples (ExerciseGroups.popular) first, then the rest.
struct ExerciseSections<Row: View>: View {
    let results: [Exercise]
    var tier: (Exercise) -> Int = { _ in 0 }
    @ViewBuilder let row: (Exercise) -> Row

    var body: some View {
        let split = ExerciseGroups.split(results, tier: tier)
        if !split.popular.isEmpty {
            Section("Popular") { ForEach(split.popular, id: \.id) { row($0) } }
        }
        if !split.rest.isEmpty {
            Section {
                ForEach(split.rest, id: \.id) { row($0) }
            } header: {
                HStack {
                    Text("All exercises")
                    Spacer()
                    Text(results.count.formatted()).monospacedDigit()
                }
            }
        }
    }
}

/// Two chips; each opens its list of options, every one with its picture.
struct ExerciseFilterBar: View {
    @Binding var filter: ExerciseFilter
    @State private var open: Kind?
    @Environment(\.colorScheme) private var scheme

    enum Kind: Identifiable { case equipment, muscle; var id: Self { self } }

    var body: some View {
        HStack(spacing: 8) {
            chip(.equipment, picked(.equipment), all: "All equipment")
            chip(.muscle, picked(.muscle), all: "All muscles")
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16).padding(.vertical, 6)
        .sheet(item: $open) { kind in
            FilterOptions(kind: kind, selection: kind == .equipment ? $filter.equipment : $filter.muscles)
                .presentationDetents([.medium, .large])
        }
    }

    /// The picked groups in the options' order, so the chip names the first one listed.
    private func picked(_ kind: Kind) -> [String] {
        kind == .equipment ? ExerciseGroups.equipment.filter(filter.equipment.contains)
            : ExerciseGroups.muscles.flatMap(\.groups).filter(filter.muscles.contains)
    }

    private func chip(_ kind: Kind, _ picked: [String], all: LocalizedStringKey) -> some View {
        // Ink on the accent: black on the bright dark-mode teal, white on the deeper light-mode one.
        let ink: Color = scheme == .dark ? .black : .white
        return Button { open = kind } label: {
            HStack(spacing: 6) {
                if let first = picked.first {
                    GroupIcon(kind: kind, name: first).frame(width: 18, height: 18).tint(ink)
                    Text(ExerciseFilter.label(first)).lineLimit(1)
                    if picked.count > 1 { Text(verbatim: "+\(picked.count - 1)").monospacedDigit() }
                } else {
                    Text(all).lineLimit(1)
                }
                Image(systemName: "chevron.down").font(.caption2.weight(.semibold))
            }
            .font(.subheadline.weight(.medium))
            .padding(.horizontal, 12).padding(.vertical, 7)
            .foregroundStyle(picked.isEmpty ? AnyShapeStyle(.primary) : AnyShapeStyle(ink))
            .background(picked.isEmpty ? AnyShapeStyle(.fill.tertiary) : AnyShapeStyle(Theme.accent), in: .capsule)
        }
        .buttonStyle(.plain)
    }
}

/// Tap options to tick any number of them; All clears the ticks.
private struct FilterOptions: View {
    @Environment(\.dismiss) private var dismiss
    let kind: ExerciseFilterBar.Kind
    @Binding var selection: Set<String>

    var body: some View {
        NavigationStack {
            List {
                Section { row(nil) }
                if kind == .equipment {
                    Section { ForEach(ExerciseGroups.equipment, id: \.self) { row($0) } }
                } else {
                    ForEach(ExerciseGroups.muscles, id: \.title) { part in
                        Section(LocalizedStringKey(part.title)) { ForEach(part.groups, id: \.self) { row($0) } }
                    }
                }
            }
            .navigationTitle(kind == .equipment ? "Equipment" : "Muscle group")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }

    private func row(_ name: String?) -> some View {
        let on = name.map(selection.contains) ?? selection.isEmpty
        return Button {
            if let name { if on { selection.remove(name) } else { selection.insert(name) } } else { selection = [] }
        } label: {
            HStack(spacing: 14) {
                Group {
                    if let name { GroupIcon(kind: kind, name: name) } else { Image(systemName: "square.grid.2x2").font(.title3) }
                }
                .frame(width: 36, height: 36)
                .foregroundStyle(.tint)
                Text(name.map(ExerciseFilter.label) ?? (kind == .equipment ? "All equipment" : "All muscles"))
                    .foregroundStyle(.primary)
                Spacer()
                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(on ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// An option's picture: the muscles lit on the body figure, or the equipment's outline.
struct GroupIcon: View {
    let kind: ExerciseFilterBar.Kind
    let name: String

    // ponytail: the body map has one back slug, so Lats and Upper Back differ only by the traps.
    private static let body: [String: (BodyMap.Side, [String])] = [
        "Abdominals": (.front, ["abs", "obliques"]), "Biceps": (.front, ["biceps"]), "Chest": (.front, ["chest"]),
        "Forearms": (.front, ["forearm"]), "Lats": (.back, ["upper-back"]), "Lower Back": (.back, ["lower-back"]),
        "Neck": (.front, ["trapezius"]), "Shoulders": (.front, ["deltoids"]), "Traps": (.back, ["trapezius"]),
        "Triceps": (.back, ["triceps"]), "Upper Back": (.back, ["upper-back", "trapezius"]),
        "Abductors": (.back, ["gluteal"]), "Adductors": (.front, ["adductors"]), "Calves": (.back, ["calves"]),
        "Glutes": (.back, ["gluteal"]), "Hamstrings": (.back, ["hamstring"]), "Quadriceps": (.front, ["quadriceps"]),
        "Full Body": (.front, ExerciseCatalog.builtIn.meta.muscles),
    ]
    private static let symbols = [
        "None": "figure.stand", "Dumbbell": "dumbbell.fill", "Machine": "gearshape.2.fill", "Plate": "circle.circle",
        "Cardio": "heart.fill", "Other": "ellipsis.circle",
    ]

    var body: some View {
        if kind == .muscle, let (side, slugs) = Self.body[name] {
            BodyMap(side: side, levels: Dictionary(uniqueKeysWithValues: slugs.map { ($0, 1.0) }), zoom: name == "Full Body" ? [] : slugs)
        } else if kind == .equipment, let shape = EquipmentShape(name) {
            shape.aspectRatio(1, contentMode: .fit)
        } else {
            Image(systemName: Self.symbols[name] ?? "ellipsis.circle").resizable().scaledToFit().padding(4)
        }
    }
}

/// Outlines for the equipment SF Symbols lack, drawn in a unit square.
private struct EquipmentShape: Shape {
    let name: String

    init?(_ name: String) {
        guard ["Barbell", "Kettlebell", "Resistance Band", "Suspension Band"].contains(name) else { return nil }
        self.name = name
    }

    func path(in r: CGRect) -> Path {
        func p(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: r.minX + x * r.width, y: r.minY + y * r.height) }
        func box(_ x: Double, _ y: Double, _ w: Double, _ h: Double, _ c: Double = 0.03) -> Path {
            Path(roundedRect: CGRect(origin: p(x, y), size: CGSize(width: w * r.width, height: h * r.height)), cornerRadius: c * r.width)
        }
        let line = StrokeStyle(lineWidth: 0.08 * r.width, lineCap: .round, lineJoin: .round)
        var out = Path()
        switch name {
        case "Barbell":
            out.addPath(box(0.02, 0.46, 0.96, 0.08))
            for x in [0.14, 0.76] { out.addPath(box(x, 0.2, 0.1, 0.6)) }
            for x in [0.26, 0.69] { out.addPath(box(x, 0.3, 0.05, 0.4)) }
        case "Kettlebell":
            out.addEllipse(in: CGRect(origin: p(0.18, 0.36), size: CGSize(width: 0.64 * r.width, height: 0.58 * r.height)))
            var handle = Path()
            handle.move(to: p(0.3, 0.44))
            handle.addCurve(to: p(0.7, 0.44), control1: p(0.22, 0.02), control2: p(0.78, 0.02))
            out.addPath(handle.strokedPath(line))
        case "Resistance Band":
            var band = Path()
            band.move(to: p(0.12, 0.62))
            band.addCurve(to: p(0.88, 0.38), control1: p(0.4, 0.1), control2: p(0.6, 0.9))
            out.addPath(band.strokedPath(line))
            out.addPath(box(0.02, 0.56, 0.18, 0.14, 0.05))
            out.addPath(box(0.8, 0.3, 0.18, 0.14, 0.05))
        default: // Suspension Band
            out.addEllipse(in: CGRect(origin: p(0.42, 0.02), size: CGSize(width: 0.16 * r.width, height: 0.16 * r.height)))
            var straps = Path()
            straps.move(to: p(0.5, 0.16)); straps.addLine(to: p(0.25, 0.76))
            straps.move(to: p(0.5, 0.16)); straps.addLine(to: p(0.75, 0.76))
            out.addPath(straps.strokedPath(line))
            out.addPath(box(0.1, 0.76, 0.3, 0.12, 0.05))
            out.addPath(box(0.6, 0.76, 0.3, 0.12, 0.05))
        }
        return out
    }
}
