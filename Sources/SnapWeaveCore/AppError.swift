import Foundation

/// Common error contract used at module boundaries. Implementations expose a
/// stable code for diagnostics and a Chinese recovery message for the UI.
public protocol SnapWeaveError: Error {
    var errorCode: String { get }
    var userMessage: String { get }
    var recoverySuggestion: String? { get }
    var isRetryable: Bool { get }
}

public extension SnapWeaveError {
    var recoverySuggestion: String? { nil }
    var isRetryable: Bool { false }
}

public struct UserFacingError: LocalizedError, Sendable {
    public let errorCode: String
    public let userMessage: String
    public let recoverySuggestion: String?
    public let isRetryable: Bool

    public init(error: Error) {
        if let error = error as? SnapWeaveError {
            errorCode = error.errorCode
            userMessage = error.userMessage
            recoverySuggestion = error.recoverySuggestion
            isRetryable = error.isRetryable
        } else {
            errorCode = "SW-UNKNOWN"
            userMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            recoverySuggestion = nil
            isRetryable = false
        }
    }

    public var errorDescription: String? {
        if let recoverySuggestion, !recoverySuggestion.isEmpty {
            return "\(userMessage)\n\(recoverySuggestion)"
        }
        return userMessage
    }
}
