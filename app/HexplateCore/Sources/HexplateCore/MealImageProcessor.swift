import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum MealImageError: Error, Equatable, Sendable {
    case invalidImage
    case tooLarge
    case encodeFailed
}

/// Pure ImageIO meal photo preprocessor (Foundation + CoreGraphics + ImageIO + UniformTypeIdentifiers).
/// Downsamples any ImageIO-supported input (HEIC, JPEG, PNG) to at most `1600 px` on the longest
/// edge, bakes EXIF orientation into the pixel buffer, optionally extracts local wall-clock capture
/// time before stripping 100% of EXIF/GPS/TIFF/IPTC/comment metadata segments, and steps down
/// quality/size deterministically to stay under `1_100_000` bytes.
public enum MealImageProcessor {
    /// Local wall-clock capture timestamp extracted on-device prior to metadata stripping.
    /// Never transmitted to any server or logged publicly.
    public struct CaptureTimestamp: Equatable, Sendable {
        public let day: String
        public let time: String
        public let hour: Int

        public init(day: String, time: String, hour: Int) {
            self.day = day
            self.time = time
            self.hour = hour
        }
    }

    public struct PreparedImage: Equatable, Sendable {
        public let jpegData: Data
        public let captured: CaptureTimestamp?

        public init(jpegData: Data, captured: CaptureTimestamp? = nil) {
            self.jpegData = jpegData
            self.captured = captured
        }
    }

    /// 50 KB safety margin under Stage 5a's `1_150_000` decoded JPEG byte cap.
    public static let defaultMaxBytes = 1_100_000

    public static let qualityLadder: [(maxPixelSize: Int, quality: Double)] = [
        (1600, 0.82),
        (1600, 0.68),
        (1280, 0.72),
        (1280, 0.55),
        (960, 0.50),
        (800, 0.40),
    ]

    /// Off-main `nonisolated async` entry point returning metadata-stripped JPEG bytes only.
    public nonisolated static func prepareJPEG(
        from inputData: Data,
        maxBytes: Int = defaultMaxBytes
    ) async throws -> Data {
        try prepareJPEGSync(from: inputData, maxBytes: maxBytes)
    }

    public nonisolated static func prepareJPEGSync(
        from inputData: Data,
        maxBytes: Int = defaultMaxBytes
    ) throws -> Data {
        try prepareImageSync(from: inputData, maxBytes: maxBytes).jpegData
    }

    /// Single-pass off-main preparation from in-memory bytes (extracts local EXIF wall-clock
    /// timestamp from the single `CGImageSource` before encoding and stripping all metadata).
    public nonisolated static func prepareImage(
        from inputData: Data,
        maxBytes: Int = defaultMaxBytes
    ) async throws -> PreparedImage {
        try prepareImageSync(from: inputData, maxBytes: maxBytes)
    }

    public nonisolated static func prepareImageSync(
        from inputData: Data,
        maxBytes: Int = defaultMaxBytes
    ) throws -> PreparedImage {
        guard !inputData.isEmpty, maxBytes > 0 else {
            throw MealImageError.invalidImage
        }
        guard let source = CGImageSourceCreateWithData(inputData as CFData, nil),
              CGImageSourceGetCount(source) > 0 else {
            throw MealImageError.invalidImage
        }
        return try prepareFromSource(source, maxBytes: maxBytes)
    }

    /// Single-pass off-main preparation directly from a file URL (subsamples through ImageIO
    /// without loading full 48 MP bytes into memory; callers using `FileRepresentation` must invoke
    /// `prepareImageSync(fromFileURL:)` before the importing closure returns).
    public nonisolated static func prepareImage(
        fromFileURL url: URL,
        maxBytes: Int = defaultMaxBytes
    ) async throws -> PreparedImage {
        try prepareImageSync(fromFileURL: url, maxBytes: maxBytes)
    }

    public nonisolated static func prepareImageSync(
        fromFileURL url: URL,
        maxBytes: Int = defaultMaxBytes
    ) throws -> PreparedImage {
        guard maxBytes > 0 else {
            throw MealImageError.invalidImage
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) > 0 else {
            throw MealImageError.invalidImage
        }
        return try prepareFromSource(source, maxBytes: maxBytes)
    }

    /// Rotates an already-prepared JPEG clockwise by `quarterTurns` (`0...3` mod 4) in one single
    /// generation from `baseJPEG`, stripping all metadata segments and respecting `maxBytes`.
    public nonisolated static func rotate(
        _ baseJPEG: Data,
        quarterTurns: Int,
        maxBytes: Int = defaultMaxBytes
    ) async throws -> Data {
        try rotateSync(baseJPEG, quarterTurns: quarterTurns, maxBytes: maxBytes)
    }

    public nonisolated static func rotateSync(
        _ baseJPEG: Data,
        quarterTurns: Int,
        maxBytes: Int = defaultMaxBytes
    ) throws -> Data {
        guard !baseJPEG.isEmpty, maxBytes > 0, AIWire.isJPEG(baseJPEG) else {
            throw MealImageError.invalidImage
        }
        let turns = ((quarterTurns % 4) + 4) % 4
        if turns == 0 {
            guard baseJPEG.count <= maxBytes else { throw MealImageError.tooLarge }
            return baseJPEG
        }
        guard let source = CGImageSourceCreateWithData(baseJPEG as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw MealImageError.invalidImage
        }
        guard let rotated = rotatedCGImage(cgImage, quarterTurns: turns) else {
            throw MealImageError.encodeFailed
        }

        var producedAny = false
        for quality in [0.82, 0.72, 0.55, 0.40] {
            let encoded = try encodeAndStrip(rotated, quality: quality)
            producedAny = true
            if encoded.count <= maxBytes {
                return encoded
            }
        }
        // Fallback through full pixel-size ladder if rotated output still exceeds maxBytes.
        let encodedHigh = try encodeAndStrip(rotated, quality: 0.85)
        if encodedHigh.count <= maxBytes {
            return encodedHigh
        }
        if let resampled = try? prepareJPEGSync(from: encodedHigh, maxBytes: maxBytes) {
            return resampled
        }
        if producedAny {
            throw MealImageError.tooLarge
        }
        throw MealImageError.encodeFailed
    }

    private nonisolated static func prepareFromSource(
        _ source: CGImageSource,
        maxBytes: Int
    ) throws -> PreparedImage {
        let captured = extractCaptureTimestamp(from: source)
        var thumbnailCache: [Int: CGImage] = [:]
        var producedAny = false

        for step in qualityLadder {
            let cgImage: CGImage
            if let cached = thumbnailCache[step.maxPixelSize] {
                cgImage = cached
            } else {
                let thumbOptions: [CFString: Any] = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: step.maxPixelSize,
                    kCGImageSourceShouldCacheImmediately: true,
                ]
                guard let decoded = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions as CFDictionary) else {
                    throw MealImageError.invalidImage
                }
                thumbnailCache[step.maxPixelSize] = decoded
                cgImage = decoded
            }

            let stripped = try encodeAndStrip(cgImage, quality: step.quality)
            producedAny = true
            if stripped.count <= maxBytes {
                return PreparedImage(jpegData: stripped, captured: captured)
            }
        }

        if producedAny {
            throw MealImageError.tooLarge
        }
        throw MealImageError.encodeFailed
    }

    private nonisolated static func encodeAndStrip(_ cgImage: CGImage, quality: Double) throws -> Data {
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
            kCGImageDestinationLossyCompressionQuality: quality,
        ]
        CGImageDestinationAddImage(destination, cgImage, destOptions as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw MealImageError.encodeFailed
        }

        let stripped = stripMetadataSegments(outData as Data)
        guard AIWire.isJPEG(stripped) else {
            throw MealImageError.encodeFailed
        }
        return stripped
    }

    private nonisolated static func rotatedCGImage(_ image: CGImage, quarterTurns: Int) -> CGImage? {
        let w = image.width
        let h = image.height
        guard w > 0, h > 0 else { return nil }
        let outW = (quarterTurns % 2 == 1) ? h : w
        let outH = (quarterTurns % 2 == 1) ? w : h
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: outW,
            height: outH,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else {
            return nil
        }

        ctx.translateBy(x: CGFloat(outW) / 2.0, y: CGFloat(outH) / 2.0)
        // CoreGraphics uses a bottom-left origin, so clockwise visual rotation is negative radians.
        ctx.rotate(by: -CGFloat(quarterTurns) * (.pi / 2.0))
        ctx.draw(image, in: CGRect(x: -CGFloat(w) / 2.0, y: -CGFloat(h) / 2.0, width: CGFloat(w), height: CGFloat(h)))
        return ctx.makeImage()
    }

    /// Reads wall-clock capture timestamp from `{Exif}.DateTimeOriginal` (fallback `{TIFF}.DateTime`)
    /// using a fixed `en_US_POSIX` Gregorian parser with no timezone conversion.
    private nonisolated static func extractCaptureTimestamp(from source: CGImageSource) -> CaptureTimestamp? {
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return nil
        }
        let exifDate = (props[kCGImagePropertyExifDictionary] as? [CFString: Any])?[kCGImagePropertyExifDateTimeOriginal] as? String
        let tiffDate = (props[kCGImagePropertyTIFFDictionary] as? [CFString: Any])?[kCGImagePropertyTIFFDateTime] as? String
        guard let raw = exifDate ?? tiffDate else { return nil }
        return parseExifWallClock(raw)
    }

    public nonisolated static func parseExifWallClock(_ raw: String) -> CaptureTimestamp? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 19 else { return nil }
        let prefix = String(trimmed.prefix(19))

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        var calendar = Calendar(identifier: .gregorian)
        let utc = TimeZone(secondsFromGMT: 0)!
        calendar.timeZone = utc
        formatter.calendar = calendar
        formatter.timeZone = utc
        formatter.isLenient = false
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"

        guard let parsed = formatter.date(from: prefix) else { return nil }
        let comps = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: parsed)
        guard let year = comps.year, let month = comps.month, let day = comps.day,
              let hour = comps.hour, let minute = comps.minute,
              (1970...2100).contains(year) else {
            return nil
        }
        let iso = String(format: "%04d-%02d-%02d", year, month, day)
        guard Report.valid(iso) != nil else { return nil }
        let time = String(format: "%02d:%02d", hour, minute)
        return CaptureTimestamp(day: iso, time: time, hour: hour)
    }

    /// Walks JPEG marker segments before Start-Of-Scan (`0xFF 0xDA`) and removes metadata segments
    /// (`APP1` EXIF/GPS/TIFF/XMP, `APP13` IPTC, and `COM` comments) while preserving JFIF (`APP0`),
    /// color profile (`APP2`), quantization/Huffman tables, and entropy-coded pixel data intact.
    private nonisolated static func stripMetadataSegments(_ jpeg: Data) -> Data {
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
    public nonisolated static func hasStrippedMetadata(_ jpegData: Data) -> Bool {
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
