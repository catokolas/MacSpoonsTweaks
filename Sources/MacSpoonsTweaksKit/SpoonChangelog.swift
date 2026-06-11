import Foundation

/// "What's new" data the UI shows when the user clicks the View
/// changes button next to an Update action. Built by a
/// `SpoonChangelogProvider` from whatever the underlying catalog
/// source can offer — full git history for `gitCommitForSubdir`
/// sources, the GitHub Commits API for `zipETag` sources.
public struct SpoonChangelog: Sendable, Equatable {
    /// Commits between the installed and latest refs, newest first.
    public var commits:    [SpoonCommit]
    /// Best link to the user-facing diff/commits page. `nil` only when
    /// no canonical URL can be derived.
    public var compareURL: URL?
    /// True iff the commit list bounds the exact installed → latest
    /// range (i.e. the installed ref was a real SHA, not a placeholder
    /// or an opaque zip ETag).
    public var precise:    Bool
    /// Optional caveat surfaced as a banner in the sheet. Use when
    /// `precise == false` to explain why the list is approximate.
    public var note:       String?

    public init(
        commits:    [SpoonCommit],
        compareURL: URL?    = nil,
        precise:    Bool    = true,
        note:       String? = nil
    ) {
        self.commits    = commits
        self.compareURL = compareURL
        self.precise    = precise
        self.note       = note
    }
}

public struct SpoonCommit: Sendable, Equatable, Identifiable {
    public var sha:     String   // full hex SHA; UI shortens
    public var subject: String   // first line of the commit message
    public var author:  String
    public var date:    Date
    public var url:     URL      // commit page on GitHub

    public var id: String { sha }

    public init(
        sha: String, subject: String,
        author: String, date: Date, url: URL
    ) {
        self.sha     = sha
        self.subject = subject
        self.author  = author
        self.date    = date
        self.url     = url
    }
}
