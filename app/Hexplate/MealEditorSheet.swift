import HexplateCore
import SwiftUI

extension Nutrition.MealType {
    var localizedTitle: String {
        switch self {
        case .breakfast: String(localized: "Breakfast")
        case .lunch: String(localized: "Lunch")
        case .afternoonTea: String(localized: "Afternoon tea")
        case .dinner: String(localized: "Dinner")
        case .lateNight: String(localized: "Late night")
        }
    }

    var symbolName: String {
        switch self {
        case .breakfast: "sunrise"
        case .lunch: "sun.max"
        case .afternoonTea: "cup.and.saucer"
        case .dinner: "sunset"
        case .lateNight: "moon.stars"
        }
    }
}

/// Reusable AX5-safe meal-slot button grid (Breakfast / Lunch / Afternoon tea / Dinner / Late night).
/// Selected state combines filled tint, thicker border, checkmark icon, bold weight, and `.isSelected`
/// so selection is never color-only and stays legible across all user-chosen accent colors.
struct MealTypePicker: View {
    @Environment(\.colorScheme) private var colorScheme
    @ScaledMetric(relativeTo: .subheadline) private var chipMinWidth: CGFloat = 104

    @Binding var selection: Nutrition.MealType?

    var body: some View {
        let columns = [GridItem(.adaptive(minimum: chipMinWidth), spacing: 8)]
        LazyVGrid(columns: columns, spacing: 8) {
            ForEach(Nutrition.MealType.allCases) { type in
                let isSelected = (selection == type)
                Button {
                    selection = isSelected ? nil : type
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: isSelected ? "checkmark.circle.fill" : type.symbolName)
                            .font(.subheadline)
                            .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                            .accessibilityHidden(true)
                        Text(type.localizedTitle)
                            .font(.subheadline.weight(isSelected ? .semibold : .regular))
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(
                                isSelected
                                    ? Theme.accent.opacity(colorScheme == .dark ? 0.24 : 0.14)
                                    : Color(.tertiarySystemFill)
                            )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(
                                isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.secondary.opacity(0.25)),
                                lineWidth: isSelected ? 1.5 : 1
                            )
                    )
                    .contentShape(.rect(cornerRadius: 10))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(type.localizedTitle)
                .accessibilityAddTraits(isSelected ? [.isSelected] : [])
            }
        }
        .padding(.vertical, 2)
    }
}

/// Sheet for adding or editing a manual (or photo-backed / AI-estimated) meal entry.
struct MealEditorSheet: View {
    struct AIDraft: Equatable {
        let estimate: AIWire.MealEstimate
        let jpegData: Data?
        let mealType: Nutrition.MealType?
        let captured: MealImageProcessor.CaptureTimestamp?

        init(
            estimate: AIWire.MealEstimate,
            jpegData: Data?,
            mealType: Nutrition.MealType? = nil,
            captured: MealImageProcessor.CaptureTimestamp? = nil
        ) {
            self.estimate = estimate
            self.jpegData = jpegData
            self.mealType = mealType
            self.captured = captured
        }
    }

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let existing: Nutrition.Meal?
    let defaultDate: String
    let aiDraft: AIDraft?
    let pendingPhotoData: Data?
    let initialMealType: Nutrition.MealType?
    let hasExplicitMealType: Bool
    let captured: MealImageProcessor.CaptureTimestamp?
    let onReestimate: ((Nutrition.MealType?) -> Void)?

    init(
        existing: Nutrition.Meal? = nil,
        defaultDate: String,
        aiDraft: AIDraft? = nil,
        pendingPhotoData: Data? = nil,
        initialMealType: Nutrition.MealType? = nil,
        hasExplicitMealType: Bool = false,
        captured: MealImageProcessor.CaptureTimestamp? = nil,
        onReestimate: ((Nutrition.MealType?) -> Void)? = nil
    ) {
        self.existing = existing
        self.defaultDate = defaultDate
        self.aiDraft = aiDraft
        self.pendingPhotoData = pendingPhotoData
        self.initialMealType = initialMealType
        self.hasExplicitMealType = hasExplicitMealType
        self.captured = captured
        self.onReestimate = onReestimate
    }

    @State private var name = ""
    @State private var mealType: Nutrition.MealType?
    @State private var date = Date.now
    @State private var includeTime = true
    @State private var time = Date.now
    @State private var kcal = ""
    @State private var protein = ""
    @State private var carbs = ""
    @State private var fat = ""
    @State private var previewImage: UIImage?
    @State private var includedItems: [Bool] = []
    @State private var confirmDelete = false
    @State private var loaded = false

    private var canSave: Bool {
        let hasName = !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasMacro = [kcal, protein, carbs, fat].contains { (parseNumber($0) ?? 0) > 0 }
        return hasName || hasMacro
    }

    private var confidenceLabel: LocalizedStringKey {
        switch aiDraft?.estimate.confidence {
        case "high": "High"
        case "low": "Low"
        default: "Medium"
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                if let image = previewImage {
                    Section {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(maxWidth: .infinity, maxHeight: 180)
                            .clipShape(.rect(cornerRadius: 10))
                            .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                    }
                }

                if let estimate = aiDraft?.estimate,
                   estimate.plausibilityWarning || !estimate.warnings.isEmpty {
                    let codes = estimate.warnings.isEmpty ? ["plausibility"] : estimate.warnings
                    Section {
                        ForEach(codes, id: \.self) { code in
                            Label {
                                Text(AIClient.warningMessage(for: code))
                                    .font(.subheadline)
                            } icon: {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)
                            }
                        }
                    } header: {
                        Text("Check estimate")
                    }
                }

                Section("Meal type") {
                    MealTypePicker(selection: $mealType)
                }

                Section {
                    TextField("Meal name", text: $name)
                    DatePicker("Date", selection: $date, in: ...Date.now, displayedComponents: .date)
                    Toggle("Include time", isOn: $includeTime)
                    if includeTime {
                        DatePicker("Time", selection: $time, displayedComponents: .hourAndMinute)
                    }
                }

                Section("Macros") {
                    numberRow("Calories", unit: "kcal", text: $kcal)
                    numberRow("Protein", unit: "g", text: $protein)
                    numberRow("Carbs", unit: "g", text: $carbs)
                    numberRow("Fat", unit: "g", text: $fat)
                }

                if let estimate = aiDraft?.estimate, !estimate.items.isEmpty {
                    Section {
                        ForEach(Array(estimate.items.enumerated()), id: \.offset) { idx, item in
                            let isOnBinding = Binding<Bool>(
                                get: { idx < includedItems.count ? includedItems[idx] : true },
                                set: { newValue in
                                    if idx < includedItems.count {
                                        includedItems[idx] = newValue
                                        recalculateFromIncludedItems(estimate)
                                    }
                                }
                            )
                            let isIncluded = idx < includedItems.count ? includedItems[idx] : true
                            Toggle(isOn: isOnBinding) {
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(alignment: .firstTextBaseline) {
                                        Text(item.name)
                                            .font(.subheadline)
                                            .strikethrough(!isIncluded)
                                            .foregroundStyle(isIncluded ? .primary : .secondary)
                                        Spacer(minLength: 8)
                                        Text("\(Format.number(item.kcal, decimals: 0)) kcal")
                                            .font(.subheadline)
                                            .monospacedDigit()
                                            .foregroundStyle(.secondary)
                                    }
                                    if let portion = item.portion, !portion.isEmpty {
                                        Text(portion)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Text("P \(Format.number(item.protein, decimals: 1)) g · C \(Format.number(item.carbs, decimals: 1)) g · F \(Format.number(item.fat, decimals: 1)) g")
                                        .font(.caption)
                                        .monospacedDigit()
                                        .foregroundStyle(.secondary)
                                }
                                .opacity(isIncluded ? 1.0 : 0.6)
                            }
                        }
                    } header: {
                        Text("Detected items")
                    } footer: {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 4) {
                                Text("Confidence:")
                                Text(confidenceLabel)
                            }
                            if let assumptions = estimate.assumptions, !assumptions.isEmpty {
                                Text(assumptions)
                            }
                            Text("Include or exclude items to recalculate totals.")
                        }
                    }
                }

                if let onReestimate {
                    Section {
                        Button("Re-estimate with note", systemImage: "arrow.triangle.2.circlepath") {
                            onReestimate(mealType)
                        }
                    }
                }

                if existing != nil {
                    Section {
                        Button("Delete meal", role: .destructive) {
                            confirmDelete = true
                        }
                    }
                }
            }
            .keyboardDismissal()
            .navigationTitle(existing == nil ? "Log meal" : "Edit meal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(!canSave)
                }
            }
            .confirmationDialog("Delete this meal?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    if let existing { model.deleteMeal(id: existing.id) }
                    dismiss()
                }
            } message: {
                if existing?.photoId != nil {
                    Text("This meal will be removed from your log. The photo is removed from this device later.")
                } else {
                    Text("This meal will be removed from your log.")
                }
            }
            .onAppear(perform: loadInitial)
        }
    }

    private func numberRow(_ title: LocalizedStringKey, unit: String, text: Binding<String>) -> some View {
        LabeledContent {
            HStack(spacing: 4) {
                TextField("–", text: text)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                Text(unit).foregroundStyle(.secondary)
            }
        } label: {
            Text(title)
        }
    }

    private func parseNumber(_ s: String) -> Double? {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: ".")
        guard let v = Double(trimmed), v.isFinite, v > 0 else { return nil }
        return v
    }

    private func recalculateFromIncludedItems(_ estimate: AIWire.MealEstimate) {
        var sumKcal = 0.0
        var sumProtein = 0.0
        var sumCarbs = 0.0
        var sumFat = 0.0
        var anyIncluded = false
        for (idx, item) in estimate.items.enumerated() where idx < includedItems.count && includedItems[idx] {
            anyIncluded = true
            sumKcal += item.kcal
            sumProtein += item.protein
            sumCarbs += item.carbs
            sumFat += item.fat
        }
        guard anyIncluded else {
            kcal = ""
            protein = ""
            carbs = ""
            fat = ""
            return
        }
        kcal = sumKcal > 0 ? Format.number(sumKcal, decimals: 0) : ""
        protein = sumProtein > 0 ? Format.number(sumProtein, decimals: 1) : ""
        carbs = sumCarbs > 0 ? Format.number(sumCarbs, decimals: 1) : ""
        fat = sumFat > 0 ? Format.number(sumFat, decimals: 1) : ""
    }

    private func loadInitial() {
        guard !loaded else { return }
        loaded = true

        // Decode preview photo once so toggles and text edits never re-decode JPEG bytes (R18).
        if let raw = pendingPhotoData ?? aiDraft?.jpegData {
            previewImage = UIImage(data: raw)
        } else if let photoId = existing?.photoId {
            previewImage = MealPhotos.image(for: photoId)
        }

        if let existing {
            name = existing.name
            // Preserve existing mealType verbatim (including nil) so editing never churns legacy rows.
            mealType = existing.mealType
            date = Day.date(existing.date) ?? .now
            if let t = existing.time {
                includeTime = true
                if let parsed = dateFromTimeString(t) {
                    time = parsed
                }
            } else {
                includeTime = false
            }
            kcal = existing.kcal.map { Format.number($0) } ?? ""
            protein = existing.protein.map { Format.number($0) } ?? ""
            carbs = existing.carbs.map { Format.number($0) } ?? ""
            fat = existing.fat.map { Format.number($0) } ?? ""
        } else {
            date = Day.date(defaultDate) ?? .now
            let effectiveCaptured = aiDraft?.captured ?? captured
            if let cap = effectiveCaptured, cap.day == defaultDate, let capDate = dateFromTimeString(cap.time) {
                includeTime = true
                time = capDate
            } else {
                includeTime = (defaultDate == model.today)
                time = .now
            }

            if let draft = aiDraft {
                // Meal type carried from `.confirm` is treated as explicit (even when cleared to nil).
                mealType = draft.mealType
                // Display server totals verbatim without re-summing individually rounded items.
                let estimate = draft.estimate
                name = estimate.name
                kcal = estimate.kcal > 0 ? Format.number(estimate.kcal, decimals: 0) : ""
                protein = estimate.protein > 0 ? Format.number(estimate.protein, decimals: 1) : ""
                carbs = estimate.carbs > 0 ? Format.number(estimate.carbs, decimals: 1) : ""
                fat = estimate.fat > 0 ? Format.number(estimate.fat, decimals: 1) : ""
                includedItems = Array(repeating: true, count: estimate.items.count)
            } else if hasExplicitMealType {
                mealType = initialMealType
            } else if defaultDate == model.today {
                let hour = Calendar.current.component(.hour, from: Date.now)
                mealType = Nutrition.MealType.suggested(forHour: hour)
            } else {
                mealType = nil
            }
        }
    }

    private func dateFromTimeString(_ raw: String) -> Date? {
        let parts = raw.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2 else { return nil }
        return Calendar.current.date(from: DateComponents(hour: parts[0], minute: parts[1]))
    }

    private func save() {
        let day = Day.iso(date)
        let timeStr: String?
        if includeTime {
            let comps = Calendar.current.dateComponents([.hour, .minute], from: time)
            timeStr = String(format: "%02d:%02d", comps.hour ?? 12, comps.minute ?? 0)
        } else {
            timeStr = nil
        }

        // Persist the EXIF-stripped JPEG only on Save (never on Cancel).
        var savedPhotoId = existing?.photoId
        if existing == nil, let jpegData = pendingPhotoData ?? aiDraft?.jpegData {
            let candidateId = UUID().uuidString.lowercased()
            if (try? MealPhotos.save(jpegData, photoId: candidateId)) != nil {
                savedPhotoId = candidateId
            }
        }

        let mealSource: Nutrition.Source = existing?.source ?? ((aiDraft != nil || savedPhotoId != nil) ? .photo : .manual)
        let meal = Nutrition.Meal(
            id: existing?.id ?? RoutineOps.newId(now: model.now),
            date: day,
            time: timeStr,
            mealType: mealType,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            kcal: parseNumber(kcal),
            protein: parseNumber(protein),
            carbs: parseNumber(carbs),
            fat: parseNumber(fat),
            source: mealSource,
            photoId: savedPhotoId,
            ts: existing?.ts ?? 0
        )
        model.upsertMeal(meal)
        dismiss()
    }
}

/// Sheet for configuring user overrides under `nutritionGoals`.
struct NutritionGoalsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var kcal = ""
    @State private var protein = ""
    @State private var carbs = ""
    @State private var fat = ""
    @State private var proteinPerKg: Double = Nutrition.defaultProteinPerKg
    @State private var loaded = false

    private var weightKg: Double? {
        Nutrition.effectiveGoals(model.root).weightKgUsed
    }

    var body: some View {
        let stored = Nutrition.goals(model.root)
        let derivedPlaceholder: String = {
            guard let weightKg else { return "–" }
            let auto = Int((weightKg * proteinPerKg).rounded())
            return String(localized: "Auto (\(auto))")
        }()

        NavigationStack {
            Form {
                Section("Daily goals") {
                    goalRow("Calories", unit: "kcal", placeholder: "–", text: $kcal)
                    goalRow("Protein", unit: "g", placeholder: derivedPlaceholder, text: $protein)
                    goalRow("Carbs", unit: "g", placeholder: "–", text: $carbs)
                    goalRow("Fat", unit: "g", placeholder: "–", text: $fat)
                }

                Section {
                    Stepper(value: $proteinPerKg, in: 0.5...4.0, step: 0.1) {
                        LabeledContent("Protein per kg", value: "\(Format.number(proteinPerKg)) g/kg")
                            .monospacedDigit()
                    }
                } header: {
                    Text("Automatic protein goal")
                } footer: {
                    if let weightKg {
                        let auto = Int((weightKg * proteinPerKg).rounded())
                        Text("Used when no custom protein goal is set (\(Format.number(proteinPerKg)) g/kg × \(Format.number(weightKg)) kg = \(auto) g).")
                    } else {
                        Text("Used when no custom protein goal is set. Log your body weight to calculate automatically.")
                    }
                }

                if !stored.isEmpty {
                    Section {
                        Button("Reset to defaults", systemImage: "arrow.counterclockwise") {
                            model.setNutritionGoals(Nutrition.Goals())
                            dismiss()
                        }
                    }
                }
            }
            .keyboardDismissal()
            .navigationTitle("Nutrition goals")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                }
            }
            .onAppear(perform: loadInitial)
        }
    }

    private func goalRow(_ title: LocalizedStringKey, unit: String, placeholder: String, text: Binding<String>) -> some View {
        LabeledContent {
            HStack(spacing: 4) {
                TextField(placeholder, text: text)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                Text(unit).foregroundStyle(.secondary)
            }
        } label: {
            Text(title)
        }
    }

    private func parse(_ s: String) -> Double? {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: ".")
        guard let v = Double(trimmed), v.isFinite, v > 0 else { return nil }
        return v
    }

    private func loadInitial() {
        guard !loaded else { return }
        loaded = true
        let g = Nutrition.goals(model.root)
        kcal = g.kcal.map { Format.number($0) } ?? ""
        protein = g.protein.map { Format.number($0) } ?? ""
        carbs = g.carbs.map { Format.number($0) } ?? ""
        fat = g.fat.map { Format.number($0) } ?? ""
        proteinPerKg = g.proteinPerKg ?? Nutrition.defaultProteinPerKg
    }

    private func save() {
        let perKgRounded = (proteinPerKg * 10).rounded() / 10
        let perKgOverride: Double? = abs(perKgRounded - Nutrition.defaultProteinPerKg) < 0.001 ? nil : perKgRounded
        model.setNutritionGoals(Nutrition.Goals(
            kcal: parse(kcal),
            protein: parse(protein),
            carbs: parse(carbs),
            fat: parse(fat),
            proteinPerKg: perKgOverride
        ))
        dismiss()
    }
}
