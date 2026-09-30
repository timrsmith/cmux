public import Foundation

/// A non-interactive close the app refused because a panel it would have
/// closed holds unsaved edits.
///
/// Automation cannot answer the Save / Don't Save / Cancel prompt, so instead
/// of discarding the edits the app closes nothing and reports which files need
/// saving. The coordinator turns this into the stable ``errorCode`` error whose
/// `message` is the app's localized sentence and whose `data.files` lists the
/// names, so callers can act on the structure instead of parsing text. An
/// explicit `force` on the command skips this check.
public struct ControlUnsavedChangesRefusal: Sendable, Equatable {
    /// The stable error code; an identifier, never localized.
    public static let errorCode = "unsaved_changes"

    /// The dirty file names, in close order.
    public let fileNames: [String]
    /// The localized, user-facing reason (names the files; mentions `--force`
    /// where the caller has one).
    public let message: String

    /// Creates a refusal.
    ///
    /// - Parameters:
    ///   - fileNames: The dirty file names, in close order.
    ///   - message: The localized reason.
    public init(fileNames: [String], message: String) {
        self.fileNames = fileNames
        self.message = message
    }

    /// The error's `data` payload: `files` plus the caller's identity keys.
    func errorData(_ identity: [String: JSONValue] = [:]) -> JSONValue {
        var data = identity
        data["files"] = .array(fileNames.map { .string($0) })
        return .object(data)
    }

    /// The fully shaped error result.
    func errorResult(_ identity: [String: JSONValue] = [:]) -> ControlCallResult {
        .err(code: Self.errorCode, message: message, data: errorData(identity))
    }
}
