import XCTest
@testable import HexplateCore

final class AIWireTests: XCTestCase {
    private var tinyJPEG: Data {
        // JPEG magic header + bytes that produce `/` in base64 (0xFF, 0xD8, 0xFF, 0xFF, 0xFF, 0xFF -> "/9j///8=")
        Data([0xFF, 0xD8, 0xFF, 0xFF, 0xFF, 0xFF, 0xD9])
    }

    func testEncodeMealRequestUsesExactServerKeysAndNoSlashEscaping() async throws {
        let longNote = "  " + String(repeating: "a", count: 280) + "  "
        let encoded = try await AIWire.encodeMealRequestAsync(
            jpegData: tinyJPEG,
            note: longNote,
            lang: "en"
        )
        let rawText = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        XCTAssertFalse(rawText.contains("\\/"), "Base64 slashes must not be escaped")
        XCTAssertTrue(rawText.contains("\"image_b64\""))
        XCTAssertFalse(rawText.contains("\"image\":"))

        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(json["image_b64"] as? String, tinyJPEG.base64EncodedString())
        XCTAssertEqual(json["lang"] as? String, "en")
        XCTAssertEqual((json["note"] as? String)?.count, AIWire.maxNoteCharacters)
    }

    func testEncodeMealRequestRejectsNonJPEGAndOversizedData() {
        XCTAssertThrowsError(try AIWire.encodeMealRequest(jpegData: Data("not-a-jpeg".utf8), note: nil, lang: "zh")) { error in
            XCTAssertEqual(error as? AIWire.ErrorKind, .invalidImage)
        }

        var oversized = Data([0xFF, 0xD8, 0xFF])
        oversized.append(Data(repeating: 0x00, count: AIWire.maxImageBytes))
        XCTAssertThrowsError(try AIWire.encodeMealRequest(jpegData: oversized, note: nil, lang: "zh")) { error in
            XCTAssertEqual(error as? AIWire.ErrorKind, .payloadTooLarge)
        }
    }

    func testDecodeServerStatusAndMealEstimateVerbatimShapes() throws {
        let statusJSON = Data("""
        {"configured":true,"model":"gpt-4o-mini","dailyTokenCap":200000,"dailyTokensUsed":12345}
        """.utf8)
        let status = try AIWire.decodeStatus(from: statusJSON)
        XCTAssertTrue(status.configured)
        XCTAssertEqual(status.model, "gpt-4o-mini")
        XCTAssertEqual(status.dailyTokenCap, 200_000)
        XCTAssertEqual(status.dailyTokensUsed, 12_345)

        let mealJSON = Data("""
        {
          "name": "Chicken Teriyaki Bowl",
          "kcal": 640,
          "protein": 46.2,
          "carbs": 68.5,
          "fat": 19.1,
          "items": [
            {"name": "Grilled chicken", "kcal": 310, "protein": 40.0, "carbs": 4.5, "fat": 14.0},
            {"name": "Steamed rice", "kcal": 330, "protein": 6.2, "carbs": 64.0, "fat": 5.1}
          ],
          "confidence": "medium",
          "plausibilityWarning": true,
          "warnings": ["macro-kcal-mismatch"]
        }
        """.utf8)
        let estimate = try AIWire.decodeMealEstimate(from: mealJSON)
        XCTAssertEqual(estimate.name, "Chicken Teriyaki Bowl")
        XCTAssertEqual(estimate.kcal, 640)
        XCTAssertEqual(estimate.protein, 46.2, accuracy: 1e-6)
        XCTAssertEqual(estimate.items.count, 2)
        XCTAssertEqual(estimate.confidence, "medium")
        XCTAssertTrue(estimate.plausibilityWarning)
        XCTAssertEqual(estimate.warnings, ["macro-kcal-mismatch"])
    }

    func testMapHTTPErrorCoversFullStage5aMatrix() {
        func body(_ code: String?, _ error: String = "err") -> Data {
            if let code {
                return Data(#"{"error":"\#(error)","code":"\#(code)"}"#.utf8)
            }
            return Data(#"{"error":"\#(error)"}"#.utf8)
        }

        XCTAssertEqual(AIWire.mapHTTPError(status: 401, body: body(nil, "not signed in"), retryAfterHeader: nil), .unauthorized)
        XCTAssertEqual(AIWire.mapHTTPError(status: 503, body: body("ai-unconfigured"), retryAfterHeader: nil), .notConfigured)
        XCTAssertEqual(AIWire.mapHTTPError(status: 503, body: body("ai-busy"), retryAfterHeader: "5"), .busy(retryAfter: 5))
        XCTAssertEqual(AIWire.mapHTTPError(status: 503, body: body("ai-upstream-busy"), retryAfterHeader: "30"), .busy(retryAfter: 30))
        XCTAssertEqual(AIWire.mapHTTPError(status: 429, body: body("rate-limited"), retryAfterHeader: "12"), .rateLimited(retryAfter: 12))

        let dailyCap = AIWire.mapHTTPError(status: 429, body: body("daily-cap-exceeded"), retryAfterHeader: "7200")
        XCTAssertEqual(dailyCap, .dailyCapReached(retryAfter: 7200))
        XCTAssertFalse(dailyCap.isRetryable)

        XCTAssertEqual(AIWire.mapHTTPError(status: 413, body: body("payload-too-large"), retryAfterHeader: nil), .payloadTooLarge)
        XCTAssertEqual(AIWire.mapHTTPError(status: 400, body: body("invalid-image"), retryAfterHeader: nil), .invalidImage)
        XCTAssertEqual(AIWire.mapHTTPError(status: 400, body: body("bad-request"), retryAfterHeader: nil), .badRequest)
        XCTAssertEqual(AIWire.mapHTTPError(status: 422, body: body("no-food"), retryAfterHeader: nil), .noFoodDetected)
        XCTAssertEqual(AIWire.mapHTTPError(status: 502, body: body("ai-upstream-auth"), retryAfterHeader: nil), .upstreamAuth)
        XCTAssertEqual(AIWire.mapHTTPError(status: 502, body: body("ai-upstream-error"), retryAfterHeader: nil), .serverError(code: "ai-upstream-error", status: 502))
        XCTAssertEqual(AIWire.mapHTTPError(status: 504, body: body("ai-timeout"), retryAfterHeader: nil), .timeout)
    }

    // MARK: - Stage 7b Coach Wire & Golden Parity

    /// Hand-maintained golden fixture (`server/tests/fixtures/coach_request_sample.json`); this Swift
    /// test is the arbiter closing both directions (`encodeCoachRequest` == `request`, and encoded
    /// `snapshot.semanticContext` == `expectedSemanticContext`) against Python `test_ai_coach.py`.
    func testCoachRequestAndSemanticContextMatchGoldenFixture() async throws {
        let testFile = URL(fileURLWithPath: #filePath)
        let repoRoot = testFile
            .deletingLastPathComponent() // HexplateCoreTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // HexplateCore
            .deletingLastPathComponent() // app
            .deletingLastPathComponent() // repo root
        let fixtureURL = repoRoot.appendingPathComponent("server/tests/fixtures/coach_request_sample.json")
        let fixtureData = try Data(contentsOf: fixtureURL)
        let fixture = try JSONDecoder().decode(JSONValue.self, from: fixtureData)
        guard case .object(let fixtureObj) = fixture,
              let expectedRequest = fixtureObj["request"],
              let expectedSemantic = fixtureObj["expectedSemanticContext"] else {
            XCTFail("Malformed coach_request_sample.json")
            return
        }

        let snapshot = CoachContext.Snapshot(
            today: "2026-11-26",
            timezone: "Asia/Tokyo",
            unit: "kg",
            scheduleMode: "rotation",
            allowedOps: ["skip", "swap_exercise", "set_sets", "add"],
            rotationOnDate: "2026-11-26",
            rotationNote: "Rotation queue is active on 2026-11-26; move_day is disallowed.",
            activeProgramme: nil,
            recentWorkouts: [
                CoachContext.WorkoutSummary(
                    date: "2026-11-25",
                    name: "Pull",
                    routineId: "r-pull",
                    setsDone: 12,
                    volume: 3200,
                    topMuscles: ["upper-back"]
                ),
            ],
            recovery: CoachContext.RecoverySummary(
                globalAcute: 24,
                globalChronic: 20,
                globalRatio: 1.2,
                recoveringMuscles: [
                    CoachContext.MuscleRecoveryEntry(slug: "chest", fatigue: 0.62, hoursToRecovered: 11.5),
                ]
            ),
            readiness: CoachContext.ReadinessSnapshot(
                verdict: "good",
                score: 78,
                sleepHours: 7.5,
                hrvMs: 62,
                hrvDeltaPct: -0.05,
                rhrBpm: 54,
                rhrDeltaBpm: 1,
                missingSignals: [],
                calibratingSignals: [],
                sleepProvisional: false
            ),
            todayNutrition: CoachContext.NutritionSnapshot(
                hexplate: Nutrition.Macros(kcal: 1100, protein: 80, carbs: 120, fat: 30),
                external: nil,
                total: Nutrition.Macros(kcal: 1100, protein: 80, carbs: 120, fat: 30),
                goals: CoachContext.NutritionGoalsSnapshot(
                    kcal: 2400,
                    protein: 160,
                    proteinIsDerived: true,
                    carbs: nil,
                    fat: nil,
                    proteinPerKg: 2,
                    weightKgUsed: 80
                )
            ),
            plan: [
                CoachContext.DayPlanEntry(
                    date: "2026-11-26",
                    weekday: "Thu",
                    digest: "0123456789abcdef",
                    locked: nil,
                    isRest: false,
                    isAIClone: false,
                    isQueueSession: true,
                    routineAlias: "R1",
                    routineId: "r-push",
                    routineName: "Push",
                    exercises: [
                        CoachContext.SlotSummary(
                            slotIndex: 0,
                            alias: "E1",
                            exerciseId: "ex-bench",
                            name: "Barbell Bench Press",
                            mode: "reps",
                            sets: 4,
                            reps: 8,
                            sec: nil,
                            hasProgrammePct: true
                        ),
                        CoachContext.SlotSummary(
                            slotIndex: 1,
                            alias: "E2",
                            exerciseId: "ex-plank",
                            name: "Forearm Plank",
                            mode: "time",
                            sets: 3,
                            reps: nil,
                            sec: 60,
                            hasProgrammePct: false
                        ),
                        CoachContext.SlotSummary(
                            slotIndex: 2,
                            alias: "E3",
                            exerciseId: "ex-run",
                            name: "Treadmill Run",
                            mode: "cardio",
                            sets: 1,
                            reps: nil,
                            sec: nil,
                            hasProgrammePct: false
                        ),
                    ]
                ),
                CoachContext.DayPlanEntry(
                    date: "2026-11-27",
                    weekday: "Fri",
                    digest: "fedcba9876543210",
                    locked: .logged,
                    isRest: false,
                    isAIClone: false,
                    isQueueSession: false,
                    routineAlias: "R2",
                    routineId: "r-pull",
                    routineName: "Pull",
                    exercises: [
                        CoachContext.SlotSummary(
                            slotIndex: 0,
                            alias: "E4",
                            exerciseId: "ex-row",
                            name: "Barbell Row",
                            mode: "reps",
                            sets: 3,
                            reps: 10,
                            sec: nil,
                            hasProgrammePct: false
                        ),
                    ]
                ),
                CoachContext.DayPlanEntry(
                    date: "2026-11-28",
                    weekday: "Sat",
                    digest: "aaaa1111bbbb2222",
                    locked: nil,
                    isRest: true,
                    isAIClone: false,
                    isQueueSession: false,
                    routineAlias: nil,
                    routineId: nil,
                    routineName: nil,
                    exercises: []
                ),
            ],
            routineAliases: [
                CoachContext.RoutineAlias(alias: "R1", id: "r-push", name: "Push"),
                CoachContext.RoutineAlias(alias: "R2", id: "r-pull", name: "Pull"),
            ],
            exerciseAliases: [
                CoachContext.ExerciseAlias(alias: "E1", id: "ex-bench", name: "Barbell Bench Press", target: "chest", equipment: "barbell", mode: "reps"),
                CoachContext.ExerciseAlias(alias: "E2", id: "ex-plank", name: "Forearm Plank", target: "abs", equipment: "body weight", mode: "time"),
                CoachContext.ExerciseAlias(alias: "E3", id: "ex-run", name: "Treadmill Run", target: nil, equipment: nil, mode: "cardio"),
                CoachContext.ExerciseAlias(alias: "E4", id: "ex-row", name: "Barbell Row", target: "upper-back", equipment: "barbell", mode: "reps"),
                CoachContext.ExerciseAlias(alias: "E5", id: "ex-db-press", name: "Dumbbell Bench Press", target: "chest", equipment: "dumbbell", mode: "reps"),
            ]
        )

        let encodedReq = try await AIWire.encodeCoachRequestAsync(
            message: "Short on time today, lighten chest slightly.",
            snapshot: snapshot,
            lang: "en"
        )
        let decodedReq = try JSONDecoder().decode(JSONValue.self, from: encodedReq)
        XCTAssertEqual(decodedReq, expectedRequest)

        let semEncoder = JSONEncoder()
        semEncoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let encodedSem = try semEncoder.encode(snapshot.semanticContext)
        let decodedSem = try JSONDecoder().decode(JSONValue.self, from: encodedSem)
        XCTAssertEqual(decodedSem, expectedSemantic)

        // Empty message rejected with .badRequest.
        XCTAssertThrowsError(try AIWire.encodeCoachRequest(message: "  \n\t ", snapshot: snapshot, lang: "en")) { err in
            XCTAssertEqual(err as? AIWire.ErrorKind, .badRequest)
        }
    }

    func testCleanCoachMessageUnicodeScalarParityAndDecodeCoachResponse() throws {
        // ZWJ family emoji = 7 Unicode scalars; matches Python clean_coach_message identically.
        let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{200D}\u{1F466}"
        XCTAssertEqual(family.unicodeScalars.count, 7)
        let exact800 = String(repeating: family, count: 114) + "ab"
        XCTAssertEqual(exact800.unicodeScalars.count, 800)
        XCTAssertEqual(AIWire.cleanCoachMessage(" \t\n" + exact800 + "\r\n "), exact800)

        let over800 = String(repeating: family, count: 115) // 805 scalars
        let cleaned = AIWire.cleanCoachMessage(over800)
        XCTAssertEqual(cleaned.unicodeScalars.count, 800)
        XCTAssertEqual(AIWire.cleanCoachMessage("hello\u{0000}\u{0007}\nworld"), "hello world")

        let validJSON = Data("""
        {"answer":"Reduced bench sets.","changes":[{"type":"skip","date":"2026-11-26"}],"note":null}
        """.utf8)
        let resp = try AIWire.decodeCoachResponse(from: validJSON)
        XCTAssertEqual(resp.answer, "Reduced bench sets.")
        XCTAssertEqual(resp.changes.count, 1)
        XCTAssertNil(resp.note)

        let noChangeJSON = Data("""
        {"answer":"Rest well.","changes":[],"note":"no_valid_plan_change"}
        """.utf8)
        let resp2 = try AIWire.decodeCoachResponse(from: noChangeJSON)
        XCTAssertEqual(resp2.changes, [])
        XCTAssertEqual(resp2.note, "no_valid_plan_change")

        let badChanges = Data("""
        {"answer":"Bad","changes":["not-an-object"],"note":null}
        """.utf8)
        XCTAssertThrowsError(try AIWire.decodeCoachResponse(from: badChanges)) { err in
            XCTAssertEqual(err as? AIWire.ErrorKind, .invalidResponse)
        }
    }
}
