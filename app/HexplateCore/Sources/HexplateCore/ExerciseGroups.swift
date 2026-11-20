import Foundation

/// The exercise pickers' two filters (equipment and muscle group, Hevy-style coarse groups over
/// the catalogue's 34 equipment kinds and 22 targets) and the staples listed first.
/// Group keys are the English labels a screen shows (localised there).
public enum ExerciseGroups {
    public static let equipment = ["None", "Barbell", "Dumbbell", "Kettlebell", "Machine", "Plate", "Resistance Band", "Suspension Band", "Other"]
    public static let muscles: [(title: String, groups: [String])] = [
        ("Upper Body", ["Abdominals", "Biceps", "Chest", "Forearms", "Lats", "Lower Back", "Neck", "Shoulders", "Traps", "Triceps", "Upper Back"]),
        ("Lower Body", ["Abductors", "Adductors", "Calves", "Glutes", "Hamstrings", "Quadriceps"]),
        ("Other", ["Cardio", "Full Body", "Other"]),
    ]

    private static let equipmentOf: [String: String] = [
        "body weight": "None",
        "barbell": "Barbell", "ez barbell": "Barbell", "olympic barbell": "Barbell", "trap bar": "Barbell", "landmine": "Barbell",
        "dumbbell": "Dumbbell", "kettlebell": "Kettlebell",
        "cable": "Machine", "leverage machine": "Machine", "smith machine": "Machine", "sled machine": "Machine", "assisted": "Machine",
        "elliptical machine": "Machine", "stationary bike": "Machine", "skierg machine": "Machine", "stepmill machine": "Machine",
        "upper body ergometer": "Machine",
        "weight plate": "Plate", "band": "Resistance Band", "resistance band": "Resistance Band", "suspension trainer": "Suspension Band",
    ]

    /// The catalogue's targets (`tg`) and, for a custom exercise, its main muscle's slug.
    // ponytail: hip flexors go to Other and serratus to Chest; Hevy's list has neither.
    private static let muscleOf: [String: String] = [
        "abs": "Abdominals", "obliques": "Abdominals", "biceps": "Biceps", "pectorals": "Chest", "chest": "Chest",
        "serratus anterior": "Chest", "serratus": "Chest", "forearms": "Forearms", "forearm": "Forearms", "lats": "Lats",
        "spine": "Lower Back", "lower-back": "Lower Back", "levator scapulae": "Neck", "delts": "Shoulders", "deltoids": "Shoulders",
        "traps": "Traps", "trapezius": "Traps", "triceps": "Triceps", "upper back": "Upper Back", "upper-back": "Upper Back",
        "abductors": "Abductors", "adductors": "Adductors", "calves": "Calves", "shins": "Calves", "tibialis": "Calves",
        "glutes": "Glutes", "gluteal": "Glutes", "hamstrings": "Hamstrings", "hamstring": "Hamstrings",
        "quads": "Quadriceps", "quadriceps": "Quadriceps", "cardiovascular system": "Cardio",
    ]

    /// The catalogue's helper muscles (`sm`, `mg`) beyond the target names above. Hands, feet,
    /// ankles and hip flexors name no group, so they tag nothing.
    private static let helperOf: [String: String] = [
        "core": "Abdominals", "lower abs": "Abdominals", "abdominals": "Abdominals", "shoulders": "Shoulders",
        "rear deltoids": "Shoulders", "rotator cuff": "Shoulders", "lower back": "Lower Back", "rhomboids": "Upper Back",
        "back": "Upper Back", "latissimus dorsi": "Lats", "upper chest": "Chest", "grip muscles": "Forearms",
        "wrist flexors": "Forearms", "wrist extensors": "Forearms", "wrists": "Forearms", "brachialis": "Biceps",
        "soleus": "Calves", "groin": "Adductors", "inner thighs": "Adductors", "sternocleidomastoid": "Neck",
    ]

    public static func equipment(of ex: Exercise) -> String { equipmentOf[ex.equipment ?? ""] ?? "Other" }

    /// Every group the exercise trains: its main one (`muscle(of:)`) first, then the helpers.
    public static func muscles(of ex: Exercise, catalog c: ExerciseCatalog = .builtIn) -> [String] {
        var out = [muscle(of: ex, catalog: c)]
        for name in [ex.muscleGroup ?? ""] + ex.secondary {
            if let g = muscleOf[name] ?? helperOf[name], g != "Cardio", !out.contains(g) { out.append(g) }
        }
        return out
    }

    public static func muscle(of ex: Exercise, catalog c: ExerciseCatalog = .builtIn) -> String {
        if ex.isCardio || ex.target == "cardiovascular system" { return "Cardio" }
        // ponytail: the catalogue files deadlifts under full body; lifters look for them by target.
        if ex.bodyPart == "full body", !ex.name.contains("deadlift") { return "Full Body" }
        if ex.bodyPart == "neck" { return "Neck" }
        return muscleOf[ex.target ?? ""] ?? c.primaryMuscle(of: ex).flatMap { muscleOf[$0] } ?? "Other"
    }

    /// Staples most programmes use, listed first in a picker, in this order.
    // ponytail: hand-picked, not usage data; add ids here when a staple is missing.
    public static let popular: [String] = [
        // chest
        "0025", "0047", "0289", "0314", "0577", "0748", "0308", "0155", "1030", "0662", "0251", "0009", "0375", "3124", "5738",
        // legs
        "0043", "0042", "0770", "0739", "5516", "0743", "1760", "0534", "2290", "0336", "0431", "1004",
        "0032", "0085", "1459", "0117", "0811", "3322", "1060", "2146", "1409", "1206", "0549",
        "0585", "0586", "0599", "0605", "0594", "0597", "0598",
        // back
        "2330", "0198", "0652", "1326", "0017", "0841", "0027", "0293", "0292", "0541", "1323", "0861", "1350", "1351",
        "0499", "1080", "1503", "0095", "0406", "0604", "0548", "0489",
        // shoulders
        "1162", "0091", "0426", "0405", "0603", "0334", "0178", "0907", "4847", "0378", "0602", "5658", "5607", "0233",
        // arms
        "0031", "0294", "0313", "0318", "6406", "0868", "0575",
        "0241", "0200", "0194", "5873", "2188", "0607", "0814", "0129", "0126", "0364", "2133",
        // core, neck, full body, cardio
        "0274", "0175", "0472", "0620", "0463", "0687", "0705", "0407", "1403", "1043",
        "0028", "0551", "1160", "0685", "2612", "2138", "0798", "2192", "2311",
    ]
    private static let rank = Dictionary(popular.enumerated().map { ($1, $0) }) { a, _ in a }

    /// A filtered list split into the staples (by `tier`, then in `popular` order) and everything
    /// else (as given). The pickers' tier puts a picked main muscle before a picked helper.
    public static func split(_ list: [Exercise], tier: (Exercise) -> Int = { _ in 0 }) -> (popular: [Exercise], rest: [Exercise]) {
        let top = list.filter { rank[$0.id] != nil }.map { ($0, tier($0)) }
            .sorted { $0.1 != $1.1 ? $0.1 < $1.1 : rank[$0.0.id]! < rank[$1.0.id]! }.map(\.0)
        return (top, list.filter { rank[$0.id] == nil })
    }
}
