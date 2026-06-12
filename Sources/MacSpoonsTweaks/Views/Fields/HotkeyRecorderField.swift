import SwiftUI
import AppKit
import MacSpoonsTweaksKit

/// One-row hotkey recorder. Displays the current binding (or a greyed
/// default), provides a Record button that captures the next key chord
/// via an in-process `NSEvent` monitor, and a Clear button that resets
/// the override.
///
/// `binding == nil` means "use the manifest default". `binding != nil`
/// means "user overrode" — that's what gets persisted in
/// `state.spoons[name].hotkeys[action]`.
struct HotkeyRecorderField: View {
    let actionLabel: String
    let `default`: HotkeyBinding?
    @Binding var binding: HotkeyBinding?
    /// Compact rendering for inline placement next to an adjacent
    /// control (e.g. the Active toggle in the SpoonDetailView footer).
    /// Skips the trailing label and the leading Spacer so the chip +
    /// buttons stay tight to whatever sits next to them.
    var compact: Bool = false

    @State private var recording: Bool = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: compact ? 4 : 10) {
            if !compact {
                Text(actionLabel)
                    .scaledFont(.body)
                Spacer()
            }
            chip
            recordButton
            clearButton
        }
        .onChange(of: recording) { _, isRecording in
            if isRecording { startMonitoring() }
            else { stopMonitoring() }
        }
        .onDisappear { stopMonitoring() }
    }

    // MARK: - Subviews

    private var chip: some View {
        Group {
            if recording {
                Text("Press a chord… (Esc to cancel)")
                    .scaledFont(.body)
                    .foregroundStyle(.secondary)
            } else if let b = binding {
                Text(Hotkey.formatBinding(b))
                    .scaledFont(.body, design: .monospaced)
            } else if let d = `default` {
                Text(Hotkey.formatBinding(d))
                    .scaledFont(.body, design: .monospaced)
                    .foregroundStyle(.tertiary)
                    .help("Manifest default — click Record to override")
            } else {
                Text("—")
                    .scaledFont(.body)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(chipBackground))
    }

    private var chipBackground: Color {
        if recording { return .red.opacity(0.18) }
        if binding != nil { return .accentColor.opacity(0.12) }
        return .gray.opacity(0.1)
    }

    private var recordButton: some View {
        Button {
            recording.toggle()
        } label: {
            Image(systemName:
                recording ? "stop.circle.fill" : "record.circle")
                .foregroundStyle(recording ? .red : .accentColor)
        }
        .buttonStyle(.plain)
        .help(recording ? "Cancel recording" : "Record new chord")
    }

    private var clearButton: some View {
        Button {
            binding = nil
        } label: {
            Image(systemName: "xmark.circle")
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .disabled(binding == nil)
        .help(binding == nil
              ? "No override set"
              : "Clear override (use default)")
    }

    // MARK: - Capture

    private func startMonitoring() {
        // .keyDown only — modifier-only events ride `flagsChanged` and
        // we don't want them registering as a chord.
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) {
            event in handleKeyDown(event)
        }
    }

    private func stopMonitoring() {
        if let m = monitor {
            NSEvent.removeMonitor(m)
            monitor = nil
        }
    }

    /// Returns `nil` to swallow the event so the captured chord doesn't
    /// also trigger whatever it would normally do in the host window.
    private func handleKeyDown(_ event: NSEvent) -> NSEvent? {
        let mods = activeMods(event.modifierFlags)
        // Bare Escape cancels recording. Escape WITH modifiers is still
        // a valid binding (the user wants e.g. Cmd+Esc → toggle).
        if event.keyCode == 53 && mods.isEmpty {
            recording = false
            return nil
        }
        if let captured = captureBinding(from: event, mods: mods) {
            binding = captured
            recording = false
        }
        // Either captured or unable-to-capture — either way, eat the
        // event so a stray binding doesn't accidentally execute.
        return nil
    }

    /// Extract the four hotkey-relevant modifiers from an NSEvent's
    /// flag set, in input order (we'll let `Hotkey.sortedMods` impose
    /// display order downstream).
    private func activeMods(_ flags: NSEvent.ModifierFlags) -> [String] {
        let masked = flags.intersection(.deviceIndependentFlagsMask)
        var out: [String] = []
        if masked.contains(.control) { out.append("ctrl") }
        if masked.contains(.option)  { out.append("alt") }
        if masked.contains(.shift)   { out.append("shift") }
        if masked.contains(.command) { out.append("cmd") }
        return out
    }

    private func captureBinding(
        from event: NSEvent, mods: [String]
    ) -> HotkeyBinding? {
        let keyCode = Int(event.keyCode)
        if let specialName = Hotkey.keyName(forKeyCode: keyCode) {
            return HotkeyBinding(mods: mods, key: specialName)
        }
        // Letters / digits / punctuation: use the layout-aware char.
        // `charactersIgnoringModifiers` gives us the "unshifted" form,
        // which is what Hammerspoon's bindSpec expects.
        if let chars = event.charactersIgnoringModifiers,
           !chars.isEmpty {
            return HotkeyBinding(mods: mods, key: chars.lowercased())
        }
        return nil
    }
}
