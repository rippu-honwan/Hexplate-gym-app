import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum MealImageError: Error, Equatable, Sendable {
    case invalidImage
    case tooLarge
    case encodeFailed
}

/// Pure ImageIO meal photo preprocessor (Foundation + ImageIO + UniformTypeIdentifiers).
/// Downsamples any ImageIO-supported input (HEIC, JPEG, PNG) to at most `1280 px` on the longest
/// edge, bakes EXIF orientation into the pixel buffer, strips 100% of EXIF/GPS/TIFF/IPTC/comment
/// metadata segments, and steps down quality/size deterministically to stay under `1_100_000` bytes.
public enum MealImageProcessor {
    /// 50 KB safety margin under Stage 5a's `1_150_000` decoded JPEG byte cap.
    public static let defaultMaxBytes = 1_100_000

    public static let qualityLadder: [(maxPixelSize: Int, quality: Double)] = [
        (1280, 0.72),
        (1280, 0.55),
        (960, 0.50),
        (800, 0.40),
    ]

    /// Off-main `nonisolated async` entry point under Swift 6 (`SWIFT_APPROACHABLE_CONCURRENCY: NO`).
    public nonisolated static func prepareJPEG(
        from inputData: Data,
        maxBytes: Int = defaultMaxBytes
    ) async throws -> Data {
        try prepareJPEGSync(from: inputData, maxBytes: maxBytes)
    }

    public static func prepareJPEGSync(
        from inputData: Data,
        maxBytes: Int = defaultMaxBytes
    ) throws -> Data {
        guard !inputData.isEmpty, maxBytes > 0 else {
            throw MealImageError.invalidImage
        }
        guard let source = CGImageSourceCreateWithData(inputData as CFData, nil),
              CGImageSourceGetCount(source) > 0 else {
            throw MealImageError.invalidImage
        }

        var producedAny = false

        for step in qualityLadder {
            let thumbOptions: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: step.maxPixelSize,
                kCGImageSourceShouldCacheImmediately: true,
            ]
            guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions as CFDictionary) else {
                throw MealImageError.invalidImage
            }

            let outData = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(
                outData as CFMutableData,
                UTType.jpeg.identifier as CFString,
                1,
                nil
            ) else {
                throw MealImageError.encodeFailed
            }

            let destOptions: [CFString: Any] = [
                kCGImageDestinationLossyCompressionQuality: step.quality,
            ]
            CGImageDestinationAddImage(destination, cgImage, destOptions as CFDictionary)
            guard CGImageDestinationFinalize(destination) else {
                throw MealImageError.encodeFailed
            }

            let stripped = stripMetadataSegments(outData as Data)
            guard AIWire.isJPEG(stripped) else {
                throw MealImageError.encodeFailed
            }
            producedAny = true
            if stripped.count <= maxBytes {
                return stripped
            }
        }

        if producedAny {
            throw MealImageError.tooLarge
        }
        throw MealImageError.encodeFailed
    }

    /// Walks JPEG marker segments before Start-Of-Scan (`0xFF 0xDA`) and removes metadata segments
    /// (`APP1` EXIF/GPS/TIFF/XMP, `APP13` IPTC, and `COM` comments) while preserving JFIF (`APP0`),
    /// color profile (`APP2`), quantization/Huffman tables, and entropy-coded pixel data intact.
    private static func stripMetadataSegments(_ jpeg: Data) -> Data {
        let bytes = [UInt8](jpeg)
        guard bytes.count >= 4, bytes[0] == 0xFF, bytes[1] == 0xD8 else {
            return jpeg
        }

        var out = Data()
        out.reserveCapacity(bytes.count)
        out.append(contentsOf: [0xFF, 0xD8])

        var i = 2
        while i + 1 < bytes.count {
            // Skip any fill 0xFF padding bytes before marker.
            guard bytes[i] == 0xFF else { return jpeg }
            while i < bytes.count && bytes[i] == 0xFF { i += 1 }
            guard i < bytes.count else { break }

            let marker = bytes[i]
            i += 1

            // Start of Scan (0xDA) or End of Image (0xD9): copy remainder verbatim.
            if marker == 0xDA || marker == 0xD9 {
                out.append(0xFF)
                out.append(marker)
                if i < bytes.count {
                    out.append(contentsOf: bytes[i...])
                }
                return out
            }

            // Standalone markers without length (RST0..RST7, TEM).
            if (marker >= 0xD0 && marker <= 0xD7) || marker == 0x01 {
                out.append(0xFF)
                out.append(marker)
                continue
            }

            guard i + 1 < bytes.count else { return jpeg }
            let segLen = (Int(bytes[i]) << 8) | Int(bytes[i + 1])
            guard segLen >= 2, i + segLen <= bytes.count else { return jpeg }

            let isMetadata = (marker == 0xE1 || marker == 0xED || marker == 0xFE)
            if !isMetadata {
                out.append(0xFF)
                out.append(marker)
                out.append(contentsOf: bytes[i..<(i + segLen)])
            }
            i += segLen
        }

        return out
    }

    /// Inspects JPEG metadata via ImageIO and verifies `{GPS}`, `{Exif}`, and `{IPTC}` dictionaries
    /// are absent, `{TIFF}` contains neither `Make` nor `Model`, and orientation is absent or `1`.
    public static func hasStrippedMetadata(_ jpegData: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(jpegData as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return false
        }
        if props[kCGImagePropertyGPSDictionary] != nil { return false }
        if props[kCGImagePropertyExifDictionary] != nil { return false }
        if props[kCGImagePropertyIPTCDictionary] != nil { return false }
        if let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            if tiff[kCGImagePropertyTIFFMake] != nil || tiff[kCGImagePropertyTIFFModel] != nil {
                return false
            }
        }
        if let orientation = props[kCGImagePropertyOrientation] as? Int, orientation != 1 {
            return false
        }
        return true
    }
}
