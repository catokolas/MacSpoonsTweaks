import SwiftUI
import MacSpoonsTweaksKit

/// Free-text editor for `.luaLiteral` fields. Multi-line monospace
/// TextEditor with a live-validation chip beneath it.
///
/// Validation hits the running Hammerspoon via the injected
/// `LuaRunner` (see `LuaRunnerEnvironment`) — wraps the user's
/// expression in `return (function() local v = (…); return type(v) end)()`
/// and shows the detected Lua type on success, the parse error on
/// failure, or a neutral state when there's no live Hammerspoon to
/// validate against.
///
/// Each keystroke debounces by 500ms before issuing the round-trip so
/// we don't fire `hs -c` on every character.
struct LuaLiteralEditor: View {
    let field: LuaLiteralField
    @Binding var value: String

    @Environment(\.luaRunner) private var luaRunner

    @State private var validation: LuaValidationResult? = nil
    @State private var validationTask: Task<Void, Never>? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            editor
            statusChip
        }
        .onAppear { scheduleValidation() }
        .onChange(of: value) { _, _ in scheduleValidation() }
        .onDisappear {
            validationTask?.cancel()
            validationTask = nil
        }
    }

    // MARK: - Subviews

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(field.label ?? field.key)
            if let desc = field.description {
                Text(desc).scaledFont(.caption)
                    .foregroundStyle(.secondary)
            } else if let hint = field.luaHint {
                Text(hint).scaledFont(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var editor: some View {
        TextEditor(text: $value)
            .font(.system(.body, design: .monospaced))
            .frame(minHeight: 60, maxHeight: 160)
            .padding(6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(borderColor, lineWidth: 1))
    }

    private var borderColor: Color {
        switch validation {
        case .ok:               return .green.opacity(0.6)
        case .syntaxError:      return .red.opacity(0.6)
        case .other, .none:     return .gray.opacity(0.3)
        }
    }

    @ViewBuilder
    private var statusChip: some View {
        switch validation {
        case .ok(let luaType):
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("Parses — Lua type: \(luaType)")
            }
            .scaledFont(.caption)
        case .syntaxError(let message):
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                Text(message)
                    .scaledFont(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(3)
                    .textSelection(.enabled)
            }
        case .other(let message):
            HStack(spacing: 6) {
                Image(systemName: "circle.dashed")
                    .foregroundStyle(.secondary)
                Text(message)
                    .scaledFont(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        case .none:
            // Pre-first-validation. Stay invisible to avoid a flash.
            Color.clear.frame(height: 1)
        }
    }

    // MARK: - Validation orchestration

    private func scheduleValidation() {
        validationTask?.cancel()
        let snapshot = value
        let runner   = luaRunner

        validationTask = Task { @MainActor in
            // 500ms debounce — fast enough to feel live, slow enough to
            // skip the round-trip while the user is mid-type.
            do {
                try await Task.sleep(nanoseconds: 500_000_000)
            } catch {
                return
            }
            if Task.isCancelled { return }

            guard let runner = runner else {
                validation = .other(
                    "No Hammerspoon connection — validation disabled.")
                return
            }
            let result = await runner.validateLua(snapshot)
            if Task.isCancelled { return }
            validation = result
        }
    }
}
