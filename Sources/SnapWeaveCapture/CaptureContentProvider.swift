import AppKit
import ScreenCaptureKit

/// Coalesces simultaneous ScreenCaptureKit discovery requests and briefly caches
/// the result so consecutive captures do not rediscover the entire desktop.
@MainActor
public final class CaptureContentProvider {
    public static let shared = CaptureContentProvider()

    private var cachedContent: SCShareableContent?
    private var cachedAt = Date.distantPast
    private var inFlight: Task<SCShareableContent, Error>?
    private let lifetime: TimeInterval = 1

    public init() {}

    public func content(forceRefresh: Bool = false) async throws -> SCShareableContent {
        if !forceRefresh, let cachedContent, Date().timeIntervalSince(cachedAt) < lifetime {
            return cachedContent
        }
        if let inFlight { return try await inFlight.value }

        let task = Task {
            try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        }
        inFlight = task
        do {
            let content = try await task.value
            cachedContent = content
            cachedAt = Date()
            inFlight = nil
            return content
        } catch {
            inFlight = nil
            throw error
        }
    }

    public func invalidate() {
        cachedContent = nil
        cachedAt = .distantPast
    }

    /// Explicitly cancel an outstanding discovery and release its captured
    /// shareable-content graph when the app is going inactive or terminating.
    public func cancelPendingRequest() {
        inFlight?.cancel()
        inFlight = nil
        invalidate()
    }
}
