import Foundation
import CoreGraphics

public enum CaptureMode: String, CaseIterable, Sendable {
    case standard
    case vertical
    case horizontal

    public var displayName: String {
        switch self {
        case .standard: "普通截图"
        case .vertical: "上下长截图"
        case .horizontal: "左右长截图"
        }
    }
}

public enum StitchAxis: Sendable {
    case vertical
    case horizontal
}

public enum ScrollDriver: String, CaseIterable, Sendable {
    case automatic
    case manual

    public var displayName: String { self == .automatic ? "自动滚动" : "手动滚动" }
    public static let `default`: ScrollDriver = .manual
}

public enum StitchDirection: Int, Sendable {
    case forward = 1
    case backward = -1
}

public struct StitchLimits: Sendable {
    public var maximumAxisLength: Int
    public var maximumPixelCount: Int

    public init(maximumAxisLength: Int = 100_000, maximumPixelCount: Int = 200_000_000) {
        self.maximumAxisLength = maximumAxisLength
        self.maximumPixelCount = maximumPixelCount
    }
}

public struct OverlapMatch: Equatable, Sendable {
    public let overlap: Int
    public let confidence: Double
    public let direction: StitchDirection
    public let orthogonalOffset: Int
    public let ambiguity: Double
    public let effectiveCoverage: Double

    public init(
        overlap: Int,
        confidence: Double,
        direction: StitchDirection,
        orthogonalOffset: Int = 0,
        ambiguity: Double = 1,
        effectiveCoverage: Double = 1
    ) {
        self.overlap = overlap
        self.confidence = confidence
        self.direction = direction
        self.orthogonalOffset = orthogonalOffset
        self.ambiguity = ambiguity
        self.effectiveCoverage = effectiveCoverage
    }
}

public enum StitchPauseReason: String, Equatable, Sendable {
    case animationInterference
    case ambiguousPattern
    case insufficientOverlap
    case directionReversed
    case viewportChanged

    public var message: String {
        switch self {
        case .animationInterference: "画面仍在变化，请稍等稳定后重试。"
        case .ambiguousPattern: "检测到重复纹理，无法安全确定拼接位置。"
        case .insufficientOverlap: "当前画面与上一段重叠不足，请回到上一位置后重试。"
        case .directionReversed: "检测到明显反向滚动，请回到原方向后继续。"
        case .viewportChanged: "截图区域或窗口尺寸发生变化，请恢复后重试。"
        }
    }
}

public enum StitchAppendResult: Equatable, Sendable {
    case initial
    case accepted(OverlapMatch)
    case unchanged
    case waitingForMoreFrames
    case paused(StitchPauseReason)
}

public enum OverlapEstimate: Equatable, Sendable {
    case match(OverlapMatch)
    case unchanged
    case ambiguous(confidence: Double, coverage: Double)
    case insufficient(confidence: Double, coverage: Double)
}

public enum StitchError: LocalizedError, Equatable, SnapWeaveError {
    case incompatibleFrameSize
    case noReliableOverlap(confidence: Double)
    case directionReversed
    case limitReached
    case cannotCreateImage

    public var errorDescription: String? {
        switch self {
        case .incompatibleFrameSize: "截图区域尺寸发生变化，请恢复窗口大小后重试。"
        case let .noReliableOverlap(confidence): "未找到可靠的重叠区域（置信度 \(Int(confidence * 100))%）。"
        case .directionReversed: "检测到明显反向滚动，已暂停拼接。"
        case .limitReached: "长图已达到安全尺寸上限。"
        case .cannotCreateImage: "无法生成拼接图片。"
        }
    }

    public var errorCode: String {
        switch self {
        case .incompatibleFrameSize: "STITCH-VIEWPORT"
        case .noReliableOverlap: "STITCH-OVERLAP"
        case .directionReversed: "STITCH-DIRECTION"
        case .limitReached: "STITCH-LIMIT"
        case .cannotCreateImage: "STITCH-OUTPUT"
        }
    }

    public var userMessage: String { errorDescription ?? "长截图处理失败。" }
    public var recoverySuggestion: String? {
        switch self {
        case .incompatibleFrameSize, .directionReversed: "恢复窗口大小和滚动方向后重试当前段。"
        case .noReliableOverlap: "让画面稳定并保留更多重叠区域后重试。"
        case .limitReached: "缩小选区或完成当前已拼接部分。"
        case .cannotCreateImage: "检查磁盘空间后重试。"
        }
    }
    public var isRetryable: Bool { self != .limitReached }
}
