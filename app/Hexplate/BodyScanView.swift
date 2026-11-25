import Charts
import HexplateCore
import SwiftUI

/// Segmental body map with anatomical L/R callouts (arms, legs, trunk) and Muscle/Fat toggle.
struct SegmentalBodyCard: View {
    let scan: BodyData.Scan
    let female: Bool
    @Binding var metric: BodyData.SegmentMetric

    @Environment(\.dynamicTypeSize) private var typeSize

    private var unit: String { metric == .muscle ? "kg" : "%" }

    private var values: (armL: Double?, armR: Double?, trunk: Double?, legL: Double?, legR: Double?) {
        switch metric {
        case .muscle:
            (scan.muscleArmL, scan.muscleArmR, scan.muscleTrunk, scan.muscleLegL, scan.muscleLegR)
        case .fat:
            (scan.fatArmL, scan.fatArmR, scan.fatTrunk, scan.fatLegL, scan.fatLegR)
        }
    }

    private func formatted(_ value: Double?) -> String {
        guard let value else { return "–" }
        return "\(Format.number(value)) \(unit)"
    }

    var body: some View {
        let shading = BodyData.segmentShading(for: scan, metric: metric)
        let v = values

        VStack(spacing: 12) {
            Picker("Segment metric", selection: $metric) {
                Text("Muscle").tag(BodyData.SegmentMetric.muscle)
                Text("Body fat").tag(BodyData.SegmentMetric.fat)
            }
            .pickerStyle(.segmented)

            if typeSize.isAccessibilitySize {
                VStack(spacing: 10) {
                    BodyMap(side: .front, levels: shading.levels, sideLevels: shading.sideLevels, female: female)
                        .frame(height: 190)
                        .accessibilityHidden(true)

                    VStack(spacing: 6) {
                        stackedRow("Left arm", value: formatted(v.armL))
                        stackedRow("Right arm", value: formatted(v.armR))
                        stackedRow("Trunk", value: formatted(v.trunk))
                        stackedRow("Left leg", value: formatted(v.legL))
                        stackedRow("Right leg", value: formatted(v.legR))
                    }
                }
            } else {
                // Front view: viewer's left is anatomical right; viewer's right is anatomical left.
                HStack(alignment: .center, spacing: 8) {
                    VStack(alignment: .trailing, spacing: 28) {
                        callout("Right arm", value: formatted(v.armR), alignment: .trailing)
                        callout("Right leg", value: formatted(v.legR), alignment: .trailing)
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)

                    BodyMap(side: .front, levels: shading.levels, sideLevels: shading.sideLevels, female: female)
                        .frame(width: 112, height: 205)
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 28) {
                        callout("Left arm", value: formatted(v.armL), alignment: .leading)
                        callout("Left leg", value: formatted(v.legL), alignment: .leading)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                LabeledContent("Trunk", value: formatted(v.trunk))
                    .font(.subheadline)
                    .monospacedDigit()
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
    }

    private func callout(_ label: LocalizedStringKey, value: String, alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(value)
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .accessibilityElement(children: .combine)
    }

    private func stackedRow(_ label: LocalizedStringKey, value: String) -> some View {
        LabeledContent(label, value: value)
            .font(.subheadline)
            .monospacedDigit()
    }
}

/// Pushed body composition detail view: latest segmental map, trends chart, and scan history.
/// Sheet presentation is owned by `NutritionView` via `onEditScan` so only one sheet owner exists.
struct BodyScanView: View {
    private enum TrendMetric: String, CaseIterable, Identifiable {
        case bodyFat
        case muscleMass
        case skeletalMuscle
        case weight

        var id: String { rawValue }

        var title: LocalizedStringKey {
            switch self {
            case .bodyFat: "Body fat"
            case .muscleMass: "Muscle mass"
            case .skeletalMuscle: "Skeletal muscle"
            case .weight: "Weight"
            }
        }

        func value(in scan: BodyData.Scan) -> Double? {
            switch self {
            case .bodyFat: scan.bodyFat
            case .muscleMass: scan.muscleMass
            case .skeletalMuscle: scan.skeletalMuscle
            case .weight: scan.weight
            }
        }
    }

    @Environment(AppModel.self) private var model
    let onEditScan: (String?) -> Void

    @State private var segmentMetric: BodyData.SegmentMetric = .muscle
    @State private var trendMetric: TrendMetric = .bodyFat

    var body: some View {
        let scans = BodyData.scanHistory(model.root)
        let female = model.root["body"] == .string("female")

        List {
            if let latest = scans.last {
                Section {
                    if latest.hasSegmentalMuscle || latest.hasSegmentalFat {
                        SegmentalBodyCard(scan: latest, female: female, metric: $segmentMetric)
                    }
                    overviewRows(for: latest)
                } header: {
                    Text(Day.date(latest.day)?.formatted(.dateTime.day().month(.wide).year().locale(Theme.locale)) ?? latest.day)
                }

                let points: [(day: String, date: Date, value: Double)] = scans.compactMap { s in
                    guard let d = Day.date(s.day), let v = trendMetric.value(in: s) else { return nil }
                    return (s.day, d, v)
                }

                if scans.count >= 2 {
                    Section("Trends") {
                        Picker("Metric", selection: $trendMetric) {
                            ForEach(TrendMetric.allCases) { m in
                                Text(m.title).tag(m)
                            }
                        }
                        .pickerStyle(.segmented)

                        if points.count >= 2 {
                            Chart(points, id: \.day) { p in
                                LineMark(x: .value("Day", p.date), y: .value("Value", p.value))
                                PointMark(x: .value("Day", p.date), y: .value("Value", p.value)).symbolSize(24)
                            }
                            .chartYScale(domain: .automatic(includesZero: false))
                            .frame(height: 170)
                            .accessibilityLabel("Body composition over time")
                        } else {
                            Text("Log at least two scans with this metric to see a trend.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section("Scan history") {
                    ForEach(scans.reversed()) { scan in
                        Button {
                            onEditScan(scan.day)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(Day.date(scan.day)?.formatted(.dateTime.day().month(.abbreviated).year().locale(Theme.locale)) ?? scan.day)
                                        .foregroundStyle(.primary)
                                    let parts = [
                                        scan.bodyFat.map { "\(Format.number($0))%" },
                                        scan.muscleMass.map { "\(Format.number($0)) kg" },
                                        scan.weight.map { "\(Format.number($0)) \(model.settings.unit)" },
                                    ].compactMap { $0 }
                                    if !parts.isEmpty {
                                        Text(parts.joined(separator: " · "))
                                            .font(.subheadline)
                                            .monospacedDigit()
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                    }
                }
            } else {
                Section {
                    Text("No body scans yet.")
                        .foregroundStyle(.secondary)
                    Button("Add scan", systemImage: "figure.arms.open") {
                        onEditScan(nil)
                    }
                }
            }
        }
        .navigationTitle("Body scans")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Add scan", systemImage: "plus") { onEditScan(nil) }
            }
        }
    }

    @ViewBuilder
    private func overviewRows(for scan: BodyData.Scan) -> some View {
        if let w = scan.weight {
            LabeledContent("Body weight", value: "\(Format.number(w, decimals: model.settings.weightDecimals)) \(model.settings.unit)")
                .monospacedDigit()
        }
        if let bf = scan.bodyFat {
            LabeledContent("Body fat", value: "\(Format.number(bf)) %").monospacedDigit()
        }
        if let mm = scan.muscleMass {
            LabeledContent("Muscle mass", value: "\(Format.number(mm)) kg").monospacedDigit()
        }
        if let sm = scan.skeletalMuscle {
            LabeledContent("Skeletal muscle mass", value: "\(Format.number(sm)) kg").monospacedDigit()
        }
        if let vf = scan.visceralFat {
            LabeledContent("Visceral fat index", value: Format.number(vf)).monospacedDigit()
        }
        if let smi = scan.smi {
            LabeledContent("SMI (kg/m2)", value: Format.number(smi)).monospacedDigit()
        }
        if let bmi = scan.bmi {
            LabeledContent("BMI", value: Format.number(bmi)).monospacedDigit()
        }
        if let bmr = scan.bmr {
            LabeledContent("BMR (kcal)", value: Format.number(bmr, decimals: 0)).monospacedDigit()
        }
    }
}

/// Grouped weekly body composition scan form saving through `BodyData.saveMeasurements` and `AppModel.logWeight`.
struct BodyScanSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let initialDay: String?

    @State private var date = Date.now
    @State private var weight = ""
    @State private var initialWeight: Double?
    @State private var texts: [String: String] = [:]
    @State private var initialized = false

    private static let overviewIds = [
        "bodyFat", "scale-fatMass", "scale-visceral", "scale-muscleMass", "scale-muscle",
        "scale-bone", "scale-water", "scale-smi", "scale-bmi", "scale-bmr",
    ]
    private static let segmentalFatIds = [
        "scale-fatArmL", "scale-fatArmR", "scale-fatTrunk", "scale-fatLegL", "scale-fatLegR",
    ]
    private static let segmentalMuscleIds = [
        "scale-muscleArmL", "scale-muscleArmR", "scale-muscleTrunk", "scale-muscleLegL", "scale-muscleLegR",
    ]

    private var fieldsById: [String: BodyData.Field] {
        Dictionary(uniqueKeysWithValues: BodyData.compositionFields.map { ($0.id, $0) })
    }

    var body: some View {
        let lookup = fieldsById
        NavigationStack {
            Form {
                Section {
                    DatePicker("Date", selection: $date, in: ...Date.now, displayedComponents: .date)
                    row("Body weight", unit: model.settings.unit, text: $weight)
                }

                fieldSection("Overview", ids: Self.overviewIds, lookup: lookup)
                fieldSection("Segmental fat (%)", ids: Self.segmentalFatIds, lookup: lookup)
                fieldSection("Segmental muscle (kg)", ids: Self.segmentalMuscleIds, lookup: lookup)
            }
            .keyboardDismissal()
            .navigationTitle("Body scan")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                }
            }
            .onAppear {
                if !initialized {
                    initialized = true
                    if let initialDay, let parsed = Day.date(initialDay) {
                        date = parsed
                    }
                }
                loadForDate()
            }
            .onChange(of: date) { loadForDate() }
        }
    }

    private func fieldSection(_ title: LocalizedStringKey, ids: [String], lookup: [String: BodyData.Field]) -> some View {
        Section(title) {
            ForEach(ids.compactMap { lookup[$0] }) { f in
                row(LocalizedStringKey(f.name), unit: f.unit, text: Binding(
                    get: { texts[f.id] ?? "" },
                    set: { texts[f.id] = $0 }
                ))
            }
        }
    }

    private func row(_ title: LocalizedStringKey, unit: String, text: Binding<String>) -> some View {
        LabeledContent {
            HStack(spacing: 4) {
                TextField("–", text: text)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                if !unit.isEmpty { Text(unit).foregroundStyle(.secondary) }
            }
        } label: {
            Text(title)
        }
    }

    private func number(_ s: String) -> Double? {
        let cleaned = s.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: ".")
        guard let v = Double(cleaned), v.isFinite else { return nil }
        return v
    }

    private func loadForDate() {
        let day = Day.iso(date)
        let values = BodyData.values(model.root, day: day)
        texts = values.mapValues { Format.number($0, decimals: 2) }
        let existingWeight = BodyData.weights(model.root).last { $0.day == day }?.weight
        initialWeight = existingWeight
        weight = existingWeight.map { Format.number($0, decimals: model.settings.weightDecimals) } ?? ""
    }

    private func save() {
        let day = Day.iso(date)
        let before = BodyData.values(model.root, day: day)
        var changes: [String: Double?] = [:]
        for f in BodyData.compositionFields {
            let v = number(texts[f.id] ?? "")
            if v != before[f.id] {
                changes[f.id] = .some(v)
            }
        }
        if !changes.isEmpty {
            model.saveMeasurements(changes, on: day, fields: BodyData.compositionFields)
        }
        if let w = number(weight), w > 0, w != initialWeight {
            model.logWeight(w, on: day)
        }
        dismiss()
    }
}
