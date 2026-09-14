import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public final class StitchSession: @unchecked Sendable {
    public let axis: StitchAxis
    public let limits: StitchLimits
    public private(set) var frameCount = 0
    public private(set) var direction: StitchDirection?
    public private(set) var pixelSize: CGSize = .zero
    public private(set) var lastCheckpoint: StitchCheckpoint?

    private let estimator: OverlapEstimator
    private var lastFrame: CGImage?
    private var segments: [(url: URL, size: CGSize)] = []
    private var pendingSegments: [(image: CGImage, prepend: Bool)] = []
    private var nextSegmentIndex = 0
    private let directory: URL
    private var consecutiveFailures = 0
    private let lock = NSLock()

    public init(axis: StitchAxis, limits: StitchLimits = .init(), estimator: OverlapEstimator = .init()) throws {
        self.axis = axis
        self.limits = limits
        self.estimator = estimator
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SnapWeave-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    @discardableResult
    public func append(_ frame: CGImage) throws -> OverlapMatch? {
        lock.lock()
        defer { lock.unlock() }
        guard let previous = lastFrame else {
            try enqueue(frame, prepend: false)
            lastFrame = frame
            frameCount = 1
            pixelSize = CGSize(width: frame.width, height: frame.height)
            return nil
        }
        guard previous.width == frame.width, previous.height == frame.height else {
            throw StitchError.incompatibleFrameSize
        }
        let estimate = estimator.analyze(previous: previous, next: frame, axis: axis)
        let match: OverlapMatch
        switch estimate {
        case let .match(value): match = value
        case .unchanged: return nil
        case let .ambiguous(confidence, _), let .insufficient(confidence, _):
            throw StitchError.noReliableOverlap(confidence: confidence)
        }
        return try append(frame, using: match)
    }

    public func appendAnalyzed(_ frame: CGImage) throws -> StitchAppendResult {
        lock.lock()
        defer { lock.unlock() }
        guard let previous = lastFrame else {
            try enqueue(frame, prepend: false)
            lastFrame = frame
            frameCount = 1
            pixelSize = CGSize(width: frame.width, height: frame.height)
            return .initial
        }
        guard previous.width == frame.width, previous.height == frame.height else {
            return .paused(.viewportChanged)
        }

        let change = FrameChangeDetector.changeRatio(previous, frame)
        if change < 0.002 { return .unchanged }
        switch estimator.analyze(previous: previous, next: frame, axis: axis) {
        case .unchanged:
            return .unchanged
        case let .match(match):
            if let direction, direction != match.direction { return .paused(.directionReversed) }
            let accepted = try append(frame, using: match)
            consecutiveFailures = 0
            return .accepted(accepted)
        case .ambiguous:
            consecutiveFailures += 1
            return consecutiveFailures < 3 ? .waitingForMoreFrames : .paused(.ambiguousPattern)
        case let .insufficient(_, coverage):
            consecutiveFailures += 1
            if change > 0.45 && coverage < 0.3 {
                return consecutiveFailures < 4 ? .waitingForMoreFrames : .paused(.animationInterference)
            }
            return consecutiveFailures < 3 ? .waitingForMoreFrames : .paused(.insufficientOverlap)
        }
    }

    public func retryCurrentSegment() {
        lock.lock()
        defer { lock.unlock() }
        consecutiveFailures = 0
    }

    /// Writes only session metadata. Segment images remain in the existing
    /// temporary directory and are never copied into diagnostics.
    @discardableResult
    public func writeCheckpoint() throws -> StitchCheckpoint {
        lock.lock()
        defer { lock.unlock() }
        // Flush before taking the metadata snapshot so checkpoint segmentNames
        // always describe every accepted frame on disk.
        try flushPendingSegments()
        let checkpoint = StitchCheckpoint(
            axis: axis,
            frameCount: frameCount,
            direction: direction,
            pixelSize: pixelSize,
            segmentNames: segments.map { $0.url.lastPathComponent }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(checkpoint)
        try data.write(to: directory.appendingPathComponent("checkpoint.json"), options: .atomic)
        lastCheckpoint = checkpoint
        return checkpoint
    }

    private func append(_ frame: CGImage, using match: OverlapMatch) throws -> OverlapMatch {
        if let direction, direction != match.direction { throw StitchError.directionReversed }
        direction = match.direction

        let strip: CGImage?
        if axis == .horizontal {
            let newWidth = frame.width - match.overlap
            let x = match.direction == .forward ? match.overlap : 0
            strip = frame.cropping(to: CGRect(x: x, y: 0, width: newWidth, height: frame.height))
        } else {
            let newHeight = frame.height - match.overlap
            let y = match.direction == .forward ? match.overlap : 0
            strip = frame.cropping(to: CGRect(x: 0, y: y, width: frame.width, height: newHeight))
        }
        guard let strip, strip.width > 0, strip.height > 0 else {
            throw StitchError.noReliableOverlap(confidence: match.confidence)
        }
        let proposed = CGSize(
            width: pixelSize.width + (axis == .horizontal ? CGFloat(strip.width) : 0),
            height: pixelSize.height + (axis == .vertical ? CGFloat(strip.height) : 0)
        )
        let axisLength = axis == .horizontal ? Int(proposed.width) : Int(proposed.height)
        guard axisLength <= limits.maximumAxisLength,
              Int(proposed.width * proposed.height) <= limits.maximumPixelCount else {
            throw StitchError.limitReached
        }
        try enqueue(strip, prepend: match.direction == .backward)
        lastFrame = frame
        frameCount += 1
        pixelSize = proposed
        return match
    }

    public func render() throws -> CGImage {
        lock.lock()
        defer { lock.unlock() }
        try flushPendingSegments()
        let width = Int(pixelSize.width)
        let height = Int(pixelSize.height)
        guard width > 0, height > 0,
              let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { throw StitchError.cannotCreateImage }

        var cursor = 0
        for segment in segments {
            guard let source = CGImageSourceCreateWithURL(segment.url as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { continue }
            if axis == .horizontal {
                context.draw(image, in: CGRect(x: cursor, y: 0, width: image.width, height: image.height))
                cursor += image.width
            } else {
                // Core Graphics has a bottom-left canvas; place the first captured segment at the top.
                let y = height - cursor - image.height
                context.draw(image, in: CGRect(x: 0, y: y, width: image.width, height: image.height))
                cursor += image.height
            }
        }
        guard let result = context.makeImage() else { throw StitchError.cannotCreateImage }
        return result
    }

    private func store(_ image: CGImage, prepend: Bool) throws {
        let url = directory.appendingPathComponent(String(format: "%06d.png", nextSegmentIndex))
        nextSegmentIndex += 1
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw StitchError.cannotCreateImage
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw StitchError.cannotCreateImage }
        let entry = (url, CGSize(width: image.width, height: image.height))
        if prepend { segments.insert(entry, at: 0) } else { segments.append(entry) }
    }

    /// Most scrolling is forward. Keep a bounded batch of strips in memory and
    /// flush it as one disk transaction; backward inserts are flushed eagerly
    /// so their ordering stays exact.
    private func enqueue(_ image: CGImage, prepend: Bool) throws {
        if prepend {
            try store(image, prepend: true)
            return
        }
        pendingSegments.append((image, false))
        if pendingSegments.count >= 8 { try flushPendingSegments() }
    }

    private func flushPendingSegments() throws {
        guard !pendingSegments.isEmpty else { return }
        // Remove each entry only after a successful encode. If disk I/O fails,
        // the unflushed tail remains available for a later retry/checkpoint.
        while !pendingSegments.isEmpty {
            let segment = pendingSegments[0]
            try store(segment.image, prepend: segment.prepend)
            pendingSegments.removeFirst()
        }
    }
}
