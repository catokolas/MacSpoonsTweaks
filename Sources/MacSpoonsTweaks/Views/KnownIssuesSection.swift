import SwiftUI
import MacSpoonsTweaksKit

/// "Known issues" warning card. Rendered in `SpoonDetailView` between
/// the provenance note and the optional native modules section so the
/// gotchas land above any install / configure actions. Empty arrays
/// render nothing.
struct KnownIssuesSection: View {
    let issues: [KnownIssue]

    var body: some View {
        if !issues.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("Known issues")
                        .scaledFont(.headline)
                    Text("(\(issues.count))")
                        .foregroundStyle(.secondary)
                        .scaledFont(.subheadline)
                }
                ForEach(issues, id: \.title) { issue in
                    KnownIssueRow(issue: issue)
                }
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(.orange.opacity(0.08)))
        }
    }
}

private struct KnownIssueRow: View {
    let issue: KnownIssue

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(issue.title).scaledFont(.body, weight: .bold)
            Text(issue.description)
                .scaledFont(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
