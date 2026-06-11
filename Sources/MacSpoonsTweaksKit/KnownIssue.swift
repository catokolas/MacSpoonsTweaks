import Foundation

/// A bug, limitation, or "be aware of this" note attached to a Spoon's
/// manifest. Surfaced in `SpoonDetailView` as a warning card and as a
/// small triangle badge on the sidebar row, so users can spot a Spoon's
/// known gotchas before they install or commit to a config.
public struct KnownIssue: Decodable, Equatable, Sendable {
    public var title:       String
    public var description: String

    public init(title: String, description: String) {
        self.title       = title
        self.description = description
    }
}
