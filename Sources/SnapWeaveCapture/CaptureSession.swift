import Foundation

public enum CaptureSessionState: String, Sendable {
    case idle, selecting, capturing, editing, completed, cancelled, failed
}

public struct CaptureSessionToken: Hashable, Sendable {
    public let id: UUID
    public init(id: UUID) { self.id = id }
}

public enum CaptureSessionKind: String, Sendable {
    case standard, scrolling, delayed, pin, textExtraction, gif
}

/// A small scheduler around the registry. It keeps admission policy in one
/// place while the AppKit coordinator remains responsible for presentation.
@MainActor
public final class CaptureSessionScheduler {
    private var active: [CaptureSessionToken: CaptureSessionKind] = [:]

    public init() {}

    public func canStart(_ kind: CaptureSessionKind) -> Bool {
        // CaptureSessionRegistry intentionally exposes one current UI session;
        // serial admission prevents a later selection from invalidating an
        // earlier asynchronous callback and losing its result.
        active.isEmpty
    }

    public func register(_ token: CaptureSessionToken, kind: CaptureSessionKind) -> Bool {
        guard canStart(kind) else { return false }
        active[token] = kind
        return true
    }

    public func finish(_ token: CaptureSessionToken) { active.removeValue(forKey: token) }
    public var activeCount: Int { active.count }
}

@MainActor
public final class CaptureSessionRegistry {
    public private(set) var state: CaptureSessionState = .idle
    public private(set) var current: CaptureSessionToken?
    public var onTransition: ((CaptureSessionToken, CaptureSessionState) -> Void)?

    public init() {}

    public func begin(_ initialState: CaptureSessionState = .selecting) -> CaptureSessionToken {
        begin(CaptureSessionToken(id: UUID()), initialState: initialState)
    }

    @discardableResult
    public func begin(_ token: CaptureSessionToken, initialState: CaptureSessionState = .selecting) -> CaptureSessionToken {
        current = token
        state = initialState
        onTransition?(token, initialState)
        return token
    }

    @discardableResult
    public func transition(_ next: CaptureSessionState, for token: CaptureSessionToken) -> Bool {
        guard current == token else { return false }
        state = next
        onTransition?(token, next)
        return true
    }

    public func finish(_ token: CaptureSessionToken, state finalState: CaptureSessionState = .completed) {
        guard current == token else { return }
        state = finalState
        onTransition?(token, finalState)
        current = nil
        state = .idle
    }

    public func isCurrent(_ token: CaptureSessionToken) -> Bool { current == token }
}
