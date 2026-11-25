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

        let output = try await MealImageProcessor.prepareJPEG(from: raw)

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

        // Verify longest side <= 1280 px and orientation 6 rotated 4032x3024 into portrait (height > width).
        let pixelWidth = try XCTUnwrap(props[kCGImagePropertyPixelWidth] as? Int)
        let pixelHeight = try XCTUnwrap(props[kCGImagePropertyPixelHeight] as? Int)
        XCTAssertLessThanOrEqual(max(pixelWidth, pixelHeight), 1280)
        XCTAssertGreaterThan(pixelHeight, pixelWidth, "Orientation 6 must be baked into portrait pixels")
        XCTAssertEqual(pixelHeight, 1280)
        XCTAssertEqual(pixelWidth, 960)

        // Verify the stripped JPEG decodes cleanly to a CGImage and contains no leaked metadata strings.
        let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(src, 0, nil))
        XCTAssertEqual(decoded.width, 960)
        XCTAssertEqual(decoded.height, 1280)
        let ascii = String(decoding: output, as: UTF8.self)
        XCTAssertFalse(ascii.contains("iPhone"))
        XCTAssertFalse(ascii.contains("Apple"))
        XCTAssertFalse(ascii.contains("2026:11:26"))
        XCTAssertFalse(ascii.contains("Exif"))
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
