import Foundation

/// What Hexplate's logic and labels read of an exercise. Same keys as the openGym catalogue
/// (frontend/src/lib/exercises-data.js) and as a custom exercise in the state document.
public struct Exercise: Decodable, Equatable, Sendable {
    public let id: String
    /// Stored lower-case; `displayName` is what a screen shows.
    public let name: String
    public let bodyPart: String?
    public let equipment: String?
    /// Set on a custom exercise to say the logged weight is help, not load.
    public let assisted: Bool?
    /// The muscle the catalogue files it under, and the ones that help.
    public let target: String?
    public let muscleGroup: String?
    public let secondary: [String]
    /// A position held for time rather than repeated.
    public let isHold: Bool
    /// Made by the user, not from the catalogue.
    public let isCustom: Bool
    /// A custom exercise's own text.
    public let about: String?
    /// The catalogue's muscle weights, worked out when the index was built.
    let storedWeights: [String: Double]
    /// Weights a custom exercise states itself.
    let explicitWeights: [String: Double]
    /// Accessories the exercise says it needs (`nd`), beside what its name implies.
    let needs: [String]

    enum CodingKeys: String, CodingKey {
        case id, name = "n", bodyPart = "bp", equipment = "eq", assisted
        case target = "tg", muscleGroup = "mg", secondary = "sm", hold = "hd", custom
        case about = "desc", storedWeights = "mw", explicitWeights = "muscleWeights", needs = "nd"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = c.string(.name) ?? ""
        bodyPart = c.string(.bodyPart)
        equipment = c.string(.equipment)
        assisted = c.bool(.assisted)
        target = c.string(.target)
        muscleGroup = c.string(.muscleGroup)
        secondary = (try? c.decode([String].self, forKey: .secondary)) ?? c.string(.secondary).map { [$0] } ?? []
        isHold = c.bool(.hold) == true
        isCustom = c.bool(.custom) == true
        about = c.string(.about)
        storedWeights = (try? c.decode([String: Double].self, forKey: .storedWeights)) ?? [:]
        explicitWeights = (try? c.decode([String: Double].self, forKey: .explicitWeights)) ?? [:]
        needs = (try? c.decode([String].self, forKey: .needs)) ?? []
    }

    /// A bench or a pull-up bar the exercise needs beside its equipment (lib/equipment.js accessoriesOf).
    public var accessories: [String] {
        guard !name.isEmpty, !["leverage machine", "sled machine", "assisted"].contains(equipment ?? "") else { return [] }
        var need: [String] = []
        if name.matches(#"\bbench\b|\bincline\b|\bdecline\b"#) { need.append("bench") }
        if name.matches(#"pull-up|pull up|chin-up|\bchin\b|hanging|dead hang|muscle-up|muscle up"#) { need.append("pull-up bar") }
        for a in needs where ["bench", "pull-up bar"].contains(a) && !need.contains(a) { need.append(a) }
        return need
    }

    public var displayName: String { Format.capWords(name) }

    public var isCardio: Bool { bodyPart == "cardio" }

    /// No load of its own: `w` on a set means added weight (lib/exercises.js isBodyweightEq).
    public var isBodyweightEquipment: Bool {
        ["body weight", "band", "resistance band"].contains(equipment)
    }

    /// An assistance machine: more weight is easier (lib/exercises.js assistedShape).
    public var isAssisted: Bool {
        assisted ?? (equipment == "leverage machine" && name.matches(#"\bassist(ed)?\b"#))
    }

    /// Done one arm or leg at a time, by its catalogue name (lib/exercises.js isOneLimb).
    public var isOneLimb: Bool {
        !isCustom && !isCardio
            && name.matches(#"\b(single|one)[\s-]+(arm|leg|hand)\b|\bunilateral\b"#)
            && !name.matches(#"stretch|\broll(er|ball)?\b|two to one|single leg (push|plank)|leg push up"#)
    }

    /// One bell at a time (lib/dumbbells.js ONE_ARM).
    var isOneArm: Bool { name.matches(#"\b(one|single)[- ]?(arm|hand|handed)\b"#) }
}

extension String {
    /// Case-insensitive regular expression test, as the JavaScript's `/…/i.test(name)`.
    func matches(_ pattern: String) -> Bool {
        range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }
}

/// The catalogue plus the profile's custom exercises, by id (lib/exercises.js EXIDX).
public struct ExerciseCatalog: Sendable {
    private var byId: [String: Exercise]
    public private(set) var meta = Meta()
    /// Every exercise once: the profile's own first, then the catalogue in its order.
    public private(set) var all: [Exercise]

    /// The catalogue's vocabulary: equipment, the muscles a body map can draw, and every spelling
    /// the dataset uses for them.
    public struct Meta: Decodable, Sendable {
        public var equipment: [String] = []
        public var accessories: [String] = []
        public var muscles: [String] = []
        public var muscleNames: [String: String] = [:]
        public var inert: [String] = []
        var alias: [String: String?] = [:]
        var byBodyPart: [String: [String: Double]] = [:]
        public var bodyParts: [String] { byBodyPart.keys.sorted() }
        public init() {}
    }

    public init(exercises: [Exercise], aliases: [String: String] = [:], meta: Meta = Meta()) {
        self.meta = meta
        all = exercises
        byId = Dictionary(exercises.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for (alias, id) in aliases { if let ex = byId[id] { byId[alias] = ex } }
    }

    public subscript(id: String) -> Exercise? { byId[id] }

    /// Exercises whose name holds every word of `query`, in catalogue order.
    public func search(_ query: String, limit: Int = 100) -> [Exercise] {
        let words = query.lowercased().split(separator: " ")
        guard !words.isEmpty else { return Array(all.prefix(limit)) }
        var out: [Exercise] = []
        for ex in all where words.allSatisfy({ ex.name.localizedCaseInsensitiveContains($0) }) {
            out.append(ex)
            if out.count == limit { break }
        }
        return out
    }

    /// A custom exercise replaces a catalogue one of the same id, as registerCustom does.
    public func adding(custom: [Exercise]) -> ExerciseCatalog {
        var copy = self
        for ex in custom { copy.byId[ex.id] = ex }
        let ids = Set(custom.map(\.id))
        copy.all = custom + all.filter { !ids.contains($0.id) }
        return copy
    }

    /// The 5,632 catalogue exercises (text only), generated by app/scripts/golden.sh.
    public static let builtIn: ExerciseCatalog = {
        struct File: Decodable { let exercises: [Exercise]; let aliases: [String: String]; let meta: Meta }
        guard let url = Bundle.module.url(forResource: "exercises", withExtension: "json"),
              let file = try? JSONDecoder().decode(File.self, from: Data(contentsOf: url))
        else { return ExerciseCatalog(exercises: []) }
        return ExerciseCatalog(exercises: file.exercises, aliases: file.aliases, meta: file.meta)
    }()

    // MARK: Muscles (lib/muscles.js)

    /// The drawable muscle a spelling means: "delts" is "deltoids", "hands" is nothing.
    public func muscle(_ spelling: String?) -> String? {
        let name = (spelling ?? "").lowercased().trimmingCharacters(in: .whitespaces)
        if meta.muscles.contains(name) { return name }
        return meta.alias[name] ?? nil
    }

    /// How hard an exercise trains each muscle, 1 for a prime mover (muscleWeightsOf).
    public func muscleWeights(of ex: Exercise) -> [String: Double] {
        if !ex.isCustom { return ex.storedWeights }
        let stated = ex.explicitWeights.filter { meta.muscles.contains($0.key) && $0.value >= 0 && $0.value <= 1 }
        if !stated.isEmpty { return stated }
        var out: [String: Double] = [:]
        func add(_ name: String?, _ w: Double) {
            if let slug = muscle(name) { out[slug] = max(out[slug] ?? 0, w) }
        }
        add(ex.target, 1)
        add(ex.muscleGroup, 0.4)
        ex.secondary.forEach { add($0, 0.4) }
        return out.isEmpty ? meta.byBodyPart[ex.bodyPart ?? ""] ?? [:] : out
    }

    /// The muscle an exercise is filed under, for a list's subtitle and filter.
    public func primaryMuscle(of ex: Exercise) -> String? {
        muscleWeights(of: ex).filter { meta.muscles.contains($0.key) }.max { a, b in
            a.value != b.value ? a.value < b.value : (meta.muscles.firstIndex(of: a.key) ?? 0) > (meta.muscles.firstIndex(of: b.key) ?? 0)
        }?.key
    }

    public func muscleName(_ slug: String) -> String { meta.muscleNames[slug] ?? Format.capWords(slug) }

    // MARK: Equipment (lib/equipment.js)

    /// What a gym profile holds; profiles saved before accessories existed count as having them.
    public static func equipment(of profile: [String: JSONValue]?) -> [String] {
        let have = (profile?["equipment"]?.arrayValue ?? []).compactMap(\.stringValue)
        guard let profile, profile["accV"] != .number(2) else { return have }
        var add = (profile["accV"]?.num ?? 0) < 1 ? ["bench", "pull-up bar"] : []
        if have.contains("roller") { add.append("massage ball") }
        var seen = Set<String>()
        return (have + add).filter { seen.insert($0).inserted }
    }

    /// Whether an exercise can be done with this equipment. Body weight is always there, and
    /// equipment the catalogue does not know is never held against an exercise.
    public func isAvailable(_ ex: Exercise, with equipment: [String]) -> Bool {
        if let eq = ex.equipment, !eq.isEmpty, eq != "body weight", meta.equipment.contains(eq), !equipment.contains(eq) { return false }
        return ex.accessories.allSatisfy(equipment.contains)
    }

    /// The gym profile the equipment filter is set to, nil when the filter is off.
    // ponytail: the "no dumbbells" pseudo-profile (lib/dumbbells.js ownsNoDumbbells) is not read.
    public static func activeProfile(_ root: [String: JSONValue]) -> [String: JSONValue]? {
        guard root["equipFilterOn"] == .bool(true), let id = root["activeEquipId"], id != .null else { return nil }
        return (root["equipProfiles"]?.arrayValue ?? []).compactMap(\.object).first { $0["id"] == id }
    }

    // MARK: How-to text

    public struct Text: Decodable, Sendable {
        public let about: String?
        public let steps: [String]?
        enum CodingKeys: String, CodingKey { case about = "d", steps = "i" }
    }

    /// The English description and steps of the catalogue's exercises, read on first use.
    public static let texts: [String: Text] = {
        guard let url = Bundle.module.url(forResource: "exercise-text", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONDecoder().decode([String: Text].self, from: data)) ?? [:]
    }()

    /// The body map's outlines (frontend/src/lib/body-paths.js, from MuscleMap by Melih Colpan, MIT).
    public static let bodyPathsURL = Bundle.module.url(forResource: "body-paths", withExtension: "json")
}
