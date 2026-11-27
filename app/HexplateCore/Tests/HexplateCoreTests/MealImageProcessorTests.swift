import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import HexplateCore

final class MealImageProcessorTests: XCTestCase {
    /// Builds a 4032x3024 JPEG in memory containing GPS coordinates, EXIF DateTimeOriginal,
    /// TIFF Make/Model, and EXIF Orientation 6 (90 deg CW portrait).
    private func makeAnnotatedCameraJPEG(width: Int = 4032, height: Int = 3024) throws -> Data {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            throw MealImageError.encodeFailed
        }

        // Paint distinct colored blocks so JPEG encoder has realistic image content.
        ctx.setFillColor(CGColor(red: 0.88, green: 0.52, blue: 0.24, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.setFillColor(CGColor(red: 0.20, green: 0.65, blue: 0.35, alpha: 1))
        ctx.fill(CGRect(x: 200, y: 200, width: width / 2, height: height / 2))

        guard let cgImage = ctx.makeImage() else {
            throw MealImageError.encodeFailed
        }

        let mutable = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            mutable as CFMutableData,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw MealImageError.encodeFailed
        }

        let metadata: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: 0.9,
            kCGImagePropertyOrientation: 6, // Right-top (portrait photo stored landscape)
            kCGImagePropertyGPSDictionary: [
                kCGImagePropertyGPSLatitude: 35.6812,
                kCGImagePropertyGPSLatitudeRef: "N",
                kCGImagePropertyGPSLongitude: 139.7671,
                kCGImagePropertyGPSLongitudeRef: "E",
            ],
            kCGImagePropertyExifDictionary: [
                kCGImagePropertyExifDateTimeOriginal: "2026:11:26 12:34:56",
            ],
            kCGImagePropertyTIFFDictionary: [
                kCGImagePropertyTIFFMake: "Apple",
                kCGImagePropertyTIFFModel: "iPhone 18 Pro",
                kCGImagePropertyTIFFOrientation: 6,
            ],
        ]

        CGImageDestinationAddImage(dest, cgImage, metadata as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return mutable as Data
    }

    func testPrepareJPEGResizesBakesOrientationAndStripsAllSensitiveMetadata() async throws {
        let raw = try makeAnnotatedCameraJPEG()

        // Sanity check: raw fixture genuinely contains sensitive metadata before processing.
        XCTAssertFalse(MealImageProcessor.hasStrippedMetadata(raw))

        let prepared = try await MealImageProcessor.prepareImage(from: raw)
        let output = prepared.jpegData

        // Local EXIF wall-clock capture timestamp is extracted prior to stripping.
        XCTAssertEqual(prepared.captured, MealImageProcessor.CaptureTimestamp(day: "2026-11-26", time: "12:34", hour: 12))

        XCTAssertLessThanOrEqual(output.count, MealImageProcessor.defaultMaxBytes)
        XCTAssertTrue(AIWire.isJPEG(output))
        XCTAssertTrue(MealImageProcessor.hasStrippedMetadata(output))

        // Verify ImageIO properties directly on output bytes.
        let src = try XCTUnwrap(CGImageSourceCreateWithData(output as CFData, nil))
        let props = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any])
        XCTAssertNil(props[kCGImagePropertyGPSDictionary], "GPS dictionary must be stripped")
        XCTAssertNil(props[kCGImagePropertyExifDictionary], "EXIF dictionary must be stripped")
        if let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            XCTAssertNil(tiff[kCGImagePropertyTIFFMake], "TIFF Make must be stripped")
            XCTAssertNil(tiff[kCGImagePropertyTIFFModel], "TIFF Model must be stripped")
        }
        if let orientation = props[kCGImagePropertyOrientation] as? Int {
            XCTAssertEqual(orientation, 1, "Orientation must be baked in as normal (1)")
        }

        // Verify longest side <= 1600 px and orientation 6 rotated 4032x3024 into portrait (height > width).
        let pixelWidth = try XCTUnwrap(props[kCGImagePropertyPixelWidth] as? Int)
        let pixelHeight = try XCTUnwrap(props[kCGImagePropertyPixelHeight] as? Int)
        XCTAssertLessThanOrEqual(max(pixelWidth, pixelHeight), 1600)
        XCTAssertGreaterThan(pixelHeight, pixelWidth, "Orientation 6 must be baked into portrait pixels")
        XCTAssertEqual(pixelHeight, 1600)
        XCTAssertEqual(pixelWidth, 1200)

        // Verify the stripped JPEG decodes cleanly to a CGImage and contains no leaked metadata strings.
        let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(src, 0, nil))
        XCTAssertEqual(decoded.width, 1200)
        XCTAssertEqual(decoded.height, 1600)
        let ascii = String(decoding: output, as: UTF8.self)
        XCTAssertFalse(ascii.contains("iPhone"))
        XCTAssertFalse(ascii.contains("Apple"))
        XCTAssertFalse(ascii.contains("2026:11:26"))
        XCTAssertFalse(ascii.contains("Exif"))
    }

    func testPrepareImageFromFileURLAndSingleGenerationRotate() async throws {
        let raw = try makeAnnotatedCameraJPEG(width: 2400, height: 1600)
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("hexplate-meal-test-\(UUID().uuidString).jpg")
        try raw.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let prepared = try MealImageProcessor.prepareImageSync(fromFileURL: tmp)
        XCTAssertEqual(prepared.captured, MealImageProcessor.CaptureTimestamp(day: "2026-11-26", time: "12:34", hour: 12))
        XCTAssertTrue(MealImageProcessor.hasStrippedMetadata(prepared.jpegData))

        // Orientation 6 turned 2400x1600 into portrait (1067x1600).
        let baseSrc = try XCTUnwrap(CGImageSourceCreateWithData(prepared.jpegData as CFData, nil))
        let baseImg = try XCTUnwrap(CGImageSourceCreateImageAtIndex(baseSrc, 0, nil))
        XCTAssertGreaterThan(baseImg.height, baseImg.width)

        // 0 turns (mod 4) returns identical bytes without re-encoding.
        let zeroTurns = try await MealImageProcessor.rotate(prepared.jpegData, quarterTurns: 4)
        XCTAssertEqual(zeroTurns, prepared.jpegData)

        // 1 quarter turn CW swaps width and height into landscape and keeps metadata stripped.
        let rotated90 = try await MealImageProcessor.rotate(prepared.jpegData, quarterTurns: 1)
        XCTAssertTrue(MealImageProcessor.hasStrippedMetadata(rotated90))
        XCTAssertLessThanOrEqual(rotated90.count, MealImageProcessor.defaultMaxBytes)
        let rotSrc = try XCTUnwrap(CGImageSourceCreateWithData(rotated90 as CFData, nil))
        let rotImg = try XCTUnwrap(CGImageSourceCreateImageAtIndex(rotSrc, 0, nil))
        XCTAssertEqual(rotImg.width, baseImg.height)
        XCTAssertEqual(rotImg.height, baseImg.width)
    }

    func testParseExifWallClockValidation() {
        XCTAssertEqual(
            MealImageProcessor.parseExifWallClock("2026:11:27 08:15:42"),
            MealImageProcessor.CaptureTimestamp(day: "2026-11-27", time: "08:15", hour: 8)
        )
        XCTAssertNil(MealImageProcessor.parseExifWallClock("2026:02:30 08:00:00"))
        XCTAssertNil(MealImageProcessor.parseExifWallClock("not-a-date"))
        XCTAssertNil(MealImageProcessor.parseExifWallClock(""))
    }

    func testPrepareJPEGThrowsTooLargeWhenCapExhaustsLadder() throws {
        let raw = try makeAnnotatedCameraJPEG(width: 1600, height: 1200)
        XCTAssertThrowsError(try MealImageProcessor.prepareJPEGSync(from: raw, maxBytes: 512)) { error in
            XCTAssertEqual(error as? MealImageError, .tooLarge)
        }
    }

    func testPrepareJPEGThrowsInvalidImageForCorruptBytes() {
        XCTAssertThrowsError(try MealImageProcessor.prepareJPEGSync(from: Data("corrupt-bytes".utf8))) { error in
            XCTAssertEqual(error as? MealImageError, .invalidImage)
        }
    }
}
