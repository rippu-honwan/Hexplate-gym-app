import Foundation

/// Pure wire types, request encoder, and `(status, code)` HTTP error mapping matching the Stage 5a
/// FastAPI endpoints (`GET /api/ai/status` and `POST /api/ai/meal`).
public enum AIWire {
    /// Matches Stage 5a `server/hexserver/ai.py` (`MAX_IMAGE_BYTES = 1_150_000`).
    public static let maxImageBytes = 1_150_000
    public static let maxNoteCharacters = 240
    /// Matches Stage 7b `server/hexserver/ai.py` (`MAX_COACH_MESSAGE_CHARS = 800`, Unicode scalars).
    public static let maxCoachMessageScalars = 800
    public static let maxCoachHistoryTurns = 10
    public static let maxCoachHistoryScalars = 1_200
    public static let maxCoachRequestBytes = 1_500_000

    // MARK: - DTOs

    public struct Status: Codable, Equatable, Sendable {
        public let configured: Bool
        public let model: String?
        public let dailyTokenCap: Int
        public let dailyTokensUsed: Int

        public init(configured: Bool, model: String?, dailyTokenCap: Int, dailyTokensUsed: Int) {
            self.configured = configured
            self.model = model
            self.dailyTokenCap = dailyTokenCap
            self.dailyTokensUsed = dailyTokensUsed
        }
    }

    public struct MealItemEstimate: Codable, Equatable, Sendable {
        public let name: String
        public let portion: String?
        public let kcal: Double
        public let protein: Double
        public let carbs: Double
        public let fat: Double

        public init(
            name: String,
            portion: String? = nil,
            kcal: Double,
            protein: Double,
            carbs: Double,
            fat: Double
        ) {
            self.name = name
            self.portion = portion
            self.kcal = kcal
            self.protein = protein
            self.carbs = carbs
            self.fat = fat
        }
    }

    public struct MealEstimate: Codable, Equatable, Sendable {
        public let name: String
        public let kcal: Double
        public let protein: Double
        public let carbs: Double
        public let fat: Double
        public let items: [MealItemEstimate]
        public let confidence: String
        public let assumptions: String?
        public let plausibilityWarning: Bool
        public let warnings: [String]

        public init(
            name: String,
            kcal: Double,
            protein: Double,
            carbs: Double,
            fat: Double,
            items: [MealItemEstimate],
            confidence: String,
            assumptions: String? = nil,
            plausibilityWarning: Bool,
            warnings: [String]
        ) {
            self.name = name
            self.kcal = kcal
            self.protein = protein
            self.carbs = carbs
            self.fat = fat
            self.items = items
            self.confidence = confidence
            self.assumptions = assumptions
            self.plausibilityWarning = plausibilityWarning
            self.warnings = warnings
        }
    }

    public struct CoachChatTurn: Codable, Equatable, Sendable {
        public let role: String
        public let content: String

        public init(role: String, content: String) {
            self.role = role
            self.content = content
        }
    }

    public struct CoachResponse: Equatable, Sendable {
        public let answer: String
        public let changes: [JSONValue]
        public let note: String?

        public init(answer: String, changes: [JSONValue], note: String? = nil) {
            self.answer = answer
            self.changes = changes
            self.note = note
        }
    }

    // MARK: - Typed Errors

    public enum ErrorKind: Error, Equatable, Sendable {
        case notPaired
        case notConfigured
        case unauthorized
        case upstreamAuth
        case payloadTooLarge
        case invalidImage
        case badRequest
        case noFoodDetected
        case rateLimited(retryAfter: Int?)
        case dailyCapReached(retryAfter: Int?)
        case busy(retryAfter: Int?)
        case timeout
        case networkLost
        case cancelled
        case serverError(code: String?, status: Int)
        case invalidResponse

        /// Transient conditions where tapping "Try again" with the same prepared image makes sense.
        /// `.dailyCapReached` is deliberately non-retryable until the rolling 24 h window clears.
        public var isRetryable: Bool {
            switch self {
            case .busy, .rateLimited, .timeout, .networkLost, .serverError:
                return true
            case .dailyCapReached, .notPaired, .notConfigured, .unauthorized, .upstreamAuth,
                 .payloadTooLarge, .invalidImage, .badRequest, .noFoodDetected, .cancelled, .invalidResponse:
                return false
            }
        }
    }

    // MARK: - Request Encoding

    private struct MealRequestBody: Encodable {
        let image_b64: String
        let note: String?
        let lang: String
        let meal_type: String?
    }

    private struct CoachRequestBody: Encodable {
        let message: String
        let context: CoachContext.Snapshot
        let lang: String
        let history: [CoachChatTurn]?
    }

    private struct CoachResponseEnvelope: Decodable {
        let answer: String
        let changes: [JSONValue]
        let note: String?
    }

    private struct ErrorEnvelope: Decodable {
        let error: String?
        let code: String?
    }

    /// Cleans a coach user message identically to `server/hexserver/ai.py`:
    /// collapses runs of ASCII control characters (`0x00...0x1F`, `0x7F`) into a single ASCII space,
    /// trims whitespace, truncates to `maxCoachMessageScalars` Unicode scalars, and trims again.
    public nonisolated static func cleanCoachMessage(_ raw: String) -> String {
        var out = String.UnicodeScalarView()
        var inControlRun = false
        for scalar in raw.unicodeScalars {
            let v = scalar.value
            if v <= 0x1F || v == 0x7F {
                if !inControlRun {
                    out.append(UnicodeScalar(0x20)!)
                    inControlRun = true
                }
            } else {
                out.append(scalar)
                inControlRun = false
            }
        }
        let trimmed = String(out).trimmingCharacters(in: .whitespacesAndNewlines)
        let scalars = trimmed.unicodeScalars
        if scalars.count <= maxCoachMessageScalars {
            return trimmed
        }
        return String(scalars.prefix(maxCoachMessageScalars)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Cleans one untrusted chat history turn identically to `server/hexserver/ai.py`
    /// `_escape_untrusted(..., max_len=1200)`: collapses ASCII control-char runs into one space,
    /// replaces each `<` and `>` with one space (without merging into control runs), trims Unicode
    /// whitespace/newlines, truncates to `maxCoachHistoryScalars` Unicode scalars, and trims again.
    public nonisolated static func cleanCoachHistoryText(_ raw: String) -> String {
        var out = String.UnicodeScalarView()
        var inControlRun = false
        for scalar in raw.unicodeScalars {
            let v = scalar.value
            if v <= 0x1F || v == 0x7F {
                if !inControlRun {
                    out.append(UnicodeScalar(0x20)!)
                    inControlRun = true
                }
            } else if v == 0x3C || v == 0x3E {
                out.append(UnicodeScalar(0x20)!)
                inControlRun = false
            } else {
                out.append(scalar)
                inControlRun = false
            }
        }
        let trimmed = String(out).trimmingCharacters(in: .whitespacesAndNewlines)
        let scalars = trimmed.unicodeScalars
        if scalars.count <= maxCoachHistoryScalars {
            return trimmed
        }
        return String(scalars.prefix(maxCoachHistoryScalars)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Filters and normalizes Coach conversation history to match server `sanitize_coach_history`:
    /// keeps only `user`/`assistant` roles with non-empty cleaned content and retains at most the
    /// latest `maxCoachHistoryTurns` turns.
    public nonisolated static func cleanCoachHistory(_ turns: [CoachChatTurn]) -> [CoachChatTurn] {
        var cleaned: [CoachChatTurn] = []
        cleaned.reserveCapacity(min(turns.count, maxCoachHistoryTurns))
        for turn in turns {
            guard turn.role == "user" || turn.role == "assistant" else { continue }
            let text = cleanCoachHistoryText(turn.content)
            guard !text.isEmpty else { continue }
            cleaned.append(CoachChatTurn(role: turn.role, content: text))
        }
        if cleaned.count <= maxCoachHistoryTurns {
            return cleaned
        }
        return Array(cleaned.suffix(maxCoachHistoryTurns))
    }

    /// Synchronous request builder for `POST /api/ai/coach`.
    /// Normalizes `message` and optional `history` by Unicode scalars, omits the `history` key when
    /// empty (preserving byte-for-byte golden fixture parity), encodes deterministically with sorted
    /// keys and unescaped slashes, and enforces `maxCoachRequestBytes`.
    public nonisolated static func encodeCoachRequest(
        message: String,
        snapshot: CoachContext.Snapshot,
        lang: String,
        history: [CoachChatTurn] = []
    ) throws -> Data {
        let cleaned = cleanCoachMessage(message)
        guard !cleaned.isEmpty else { throw ErrorKind.badRequest }
        let normalizedLang = lang.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedHistory = cleanCoachHistory(history)
        let payload = CoachRequestBody(
            message: cleaned,
            context: snapshot,
            lang: normalizedLang.isEmpty ? "zh" : normalizedLang,
            history: cleanedHistory.isEmpty ? nil : cleanedHistory
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(payload)
        guard data.count <= maxCoachRequestBytes else { throw ErrorKind.payloadTooLarge }
        return data
    }

    /// `nonisolated async` entry point so `@MainActor` callers run JSON serialization off-main.
    public nonisolated static func encodeCoachRequestAsync(
        message: String,
        snapshot: CoachContext.Snapshot,
        lang: String,
        history: [CoachChatTurn] = []
    ) async throws -> Data {
        try encodeCoachRequest(message: message, snapshot: snapshot, lang: lang, history: history)
    }

    public nonisolated static func decodeCoachResponse(from data: Data) throws -> CoachResponse {
        do {
            let env = try JSONDecoder().decode(CoachResponseEnvelope.self, from: data)
            for item in env.changes {
                guard case .object = item else { throw ErrorKind.invalidResponse }
            }
            return CoachResponse(answer: env.answer, changes: env.changes, note: env.note)
        } catch let err as ErrorKind {
            throw err
        } catch {
            throw ErrorKind.invalidResponse
        }
    }

    public static func isJPEG(_ data: Data) -> Bool {
        guard data.count >= 3 else { return false }
        let start = data.startIndex
        return data[start] == 0xFF && data[start + 1] == 0xD8 && data[start + 2] == 0xFF
    }

    /// Synchronous request builder for `POST /api/ai/meal`.
    /// Validates JPEG magic bytes and byte cap, trims/caps `note` at 240 characters, omits `meal_type`
    /// when nil/empty, and encodes without escaping `/` so base64 overhead stays strictly minimal.
    public static func encodeMealRequest(
        jpegData: Data,
        note: String?,
        lang: String,
        mealType: String? = nil
    ) throws -> Data {
        guard isJPEG(jpegData) else { throw ErrorKind.invalidImage }
        guard jpegData.count <= maxImageBytes else { throw ErrorKind.payloadTooLarge }

        let cleanedNote: String? = {
            guard let raw = note?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
                return nil
            }
            if raw.count <= maxNoteCharacters { return raw }
            return String(raw.prefix(maxNoteCharacters))
        }()

        let cleanedMealType: String? = {
            guard let raw = mealType?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
                return nil
            }
            return raw
        }()

        let normalizedLang = lang.trimmingCharacters(in: .whitespacesAndNewlines)
        let payload = MealRequestBody(
            image_b64: jpegData.base64EncodedString(),
            note: cleanedNote,
            lang: normalizedLang.isEmpty ? "zh" : normalizedLang,
            meal_type: cleanedMealType
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return try encoder.encode(payload)
    }

    /// `nonisolated async` entry point so `@MainActor` callers execute the ~1.5 MB base64 + JSON
    /// serialization off the main thread under Swift 6 (`SWIFT_APPROACHABLE_CONCURRENCY: NO`).
    public nonisolated static func encodeMealRequestAsync(
        jpegData: Data,
        note: String?,
        lang: String,
        mealType: String? = nil
    ) async throws -> Data {
        try encodeMealRequest(jpegData: jpegData, note: note, lang: lang, mealType: mealType)
    }

    // MARK: - Response Decoding & Error Mapping

    public static func decodeStatus(from data: Data) throws -> Status {
        do {
            return try JSONDecoder().decode(Status.self, from: data)
        } catch {
            throw ErrorKind.invalidResponse
        }
    }

    public static func decodeMealEstimate(from data: Data) throws -> MealEstimate {
        do {
            return try JSONDecoder().decode(MealEstimate.self, from: data)
        } catch {
            throw ErrorKind.invalidResponse
        }
    }

    /// Maps an HTTP error response from `/api/ai/*` strictly by `(status, code)` plus optional
    /// `Retry-After` integer header.
    public static func mapHTTPError(
        status: Int,
        body: Data?,
        retryAfterHeader: String?
    ) -> ErrorKind {
        let retryAfter = retryAfterHeader
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { Int($0) }
            .flatMap { $0 > 0 ? $0 : nil }

        let parsedCode: String? = body
            .flatMap { try? JSONDecoder().decode(ErrorEnvelope.self, from: $0) }?
            .code?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if status == 401 {
            return .unauthorized
        }

        switch parsedCode {
        case "ai-unconfigured":
            return .notConfigured
        case "ai-busy", "ai-upstream-busy":
            return .busy(retryAfter: retryAfter)
        case "rate-limited":
            return .rateLimited(retryAfter: retryAfter)
        case "daily-cap-exceeded":
            return .dailyCapReached(retryAfter: retryAfter)
        case "payload-too-large":
            return .payloadTooLarge
        case "invalid-image":
            return .invalidImage
        case "bad-request":
            return .badRequest
        case "no-food":
            return .noFoodDetected
        case "ai-upstream-auth":
            return .upstreamAuth
        case "ai-upstream-error":
            return .serverError(code: "ai-upstream-error", status: status)
        case "ai-timeout":
            return .timeout
        default:
            break
        }

        switch status {
        case 413:
            return .payloadTooLarge
        case 422:
            return .noFoodDetected
        case 429:
            return .rateLimited(retryAfter: retryAfter)
        case 504:
            return .timeout
        default:
            return .serverError(code: parsedCode, status: status)
        }
    }
}
