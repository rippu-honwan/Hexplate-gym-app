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
}
