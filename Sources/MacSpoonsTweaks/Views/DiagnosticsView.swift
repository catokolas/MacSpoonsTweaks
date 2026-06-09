import SwiftUI
import AppKit
import MacSpoonsTweaksKit

/// Sheet-presented log of the last N `hs -c` invocations. Lets you
/// inspect exactly what the app sent to Hammerspoon and what came
/// back — the fastest debug loop for "why didn't my Apply work?".
struct DiagnosticsView: View {
    @EnvironmentObject var catalog: SpoonCatalogModel
    @Environment(\.dismiss) private var dismiss

    /// Row that the user has expanded to see the full script + result.
    @State private var expanded: BridgeInvocation.ID?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if catalog.recentInvocations.isEmpty {
                emptyState
            } else {
                invocationList
            }
        }
        .frame(minWidth: 600, minHeight: 400)
    }

    // MARK: - Sections

    private var header: some View {
        HStack {
            Image(systemName: "stethoscope")
                .foregroundStyle(.secondary)
            Text("Diagnostics").font(.headline)
            Text("(\(catalog.recentInvocations.count) of " +
                 "\(catalog.recorder.capacity) calls)")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button("Clear") {
                catalog.recorder.clear()
                catalog.recentInvocations = []
                expanded = nil
            }
            .disabled(catalog.recentInvocations.isEmpty)
            Button("Close") { dismiss() }
        }
        .padding(12)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Spacer()
            Image(systemName: "stethoscope")
                .imageScale(.large)
                .foregroundStyle(.tertiary)
            Text("No bridge calls recorded yet.")
                .foregroundStyle(.secondary)
            Text("Try clicking Apply on a Spoon — every `hs -c` call lands here.")
                .font(.caption).foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var invocationList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(catalog.recentInvocations) { inv in
                    Divider()
                    row(for: inv)
                }
                Divider()
            }
        }
    }

    private func row(for inv: BridgeInvocation) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                expanded = (expanded == inv.id) ? nil : inv.id
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: inv.result.isSuccess
                          ? "checkmark.circle.fill"
                          : "exclamationmark.triangle.fill")
                        .foregroundStyle(inv.result.isSuccess
                                         ? .green : .red)
                        .frame(width: 18)
                    Text(formatTime(inv.timestamp))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 90, alignment: .leading)
                    Text(formatDuration(inv.durationSeconds))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 60, alignment: .trailing)
                    Text(firstLine(of: inv.script))
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: expanded == inv.id
                          ? "chevron.down" : "chevron.right")
                        .foregroundStyle(.tertiary)
                        .imageScale(.small)
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded == inv.id {
                expandedDetail(for: inv)
            }
        }
    }

    private func expandedDetail(for inv: BridgeInvocation) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            labeledBlock(title: "Script",
                         text: inv.script,
                         monospaced: true)
            switch inv.result {
            case .success(let stdout):
                labeledBlock(
                    title: "Stdout",
                    text: stdout.isEmpty ? "(empty)" : stdout,
                    monospaced: true)
            case .failure(let message):
                labeledBlock(
                    title: "Error",
                    text: message,
                    monospaced: false,
                    tone: .red)
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
    }

    private func labeledBlock(
        title: String,
        text: String,
        monospaced: Bool,
        tone: Color = .primary
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.caption.bold())
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(text, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc").imageScale(.small)
                }
                .buttonStyle(.plain)
                .help("Copy to clipboard")
            }
            ScrollView(.vertical) {
                Text(text)
                    .font(.system(
                        monospaced ? .body : .body,
                        design: monospaced ? .monospaced : .default))
                    .foregroundStyle(tone)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(8)
            }
            .frame(maxHeight: 200)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(.gray.opacity(0.08)))
        }
    }

    // MARK: - Formatting

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    private func formatTime(_ date: Date) -> String {
        return Self.timeFormatter.string(from: date)
    }

    private func formatDuration(_ seconds: Double) -> String {
        let ms = seconds * 1000
        if ms < 1.0 { return String(format: "%.2fms", ms) }
        return String(format: "%.0fms", ms)
    }

    private func firstLine(of script: String) -> String {
        guard let nl = script.firstIndex(of: "\n") else { return script }
        return String(script[..<nl]) + " …"
    }
}
