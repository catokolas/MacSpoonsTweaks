import SwiftUI
import AppKit
import MacSpoonsTweaksKit

/// Recorder-style picker for a modifier-only chord (no main key). UX
/// mirrors `HotkeyRecorderField`: a chip showing the current chord, a
/// Record button to capture a new one, and a Clear button to reset to
/// the manifest default. While recording, the chip shows live preview
/// of whatever modifiers the user is currently holding; releasing all
/// modifiers commits the **max set observed** during the session — so
/// pressing Cmd then adding Alt then releasing records `⌥⌘`, not the
/// transient `⌘` on the way down.
///
/// Storage is `ConfigValue.stringList`, so the snippet generator emits
/// the same Lua `{ "alt" }` literal it would for any other string list.
struct ModifierComboFieldView: View {
    let field: ModifierComboField
    @Binding var value: [String]

    @State private var recording: Bool = false
    @State private var monitor: Any?
    @State private var maxHeld: Set<String> = []
    @State private var liveHeld: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Text(field.label ?? field.key)
                    .scaledFont(.body)
                Spacer()
                chip
                recordButton
                clearButton
            }
            if let desc = field.description {
                Text(desc)
                    .scaledFont(.caption)
                    .foregroundStyle(.secondary)
            }
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
                Text(liveHeld.isEmpty
                     ? "Hold modifier(s)… (Esc to cancel)"
                     : formatMods(liveHeld))
                    .scaledFont(.body,
                                design: liveHeld.isEmpty
                                        ? .default : .monospaced)
                    .foregroundStyle(liveHeld.isEmpty ? .secondary : .primary)
            } else if !value.isEmpty {
                Text(formatMods(value))
                    .scaledFont(.body, design: .monospaced)
            } else {
                Text(formatMods(field.default))
                    .scaledFont(.body, design: .monospaced)
                    .foregroundStyle(.tertiary)
                    .help("Manifest default")
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
        if !value.isEmpty && value != field.default {
            return .accentColor.opacity(0.12)
        }
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
        .help(recording ? "Cancel recording" : "Record new modifier(s)")
    }

    private var clearButton: some View {
        Button {
            value = field.default
        } label: {
            Image(systemName: "xmark.circle")
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .disabled(value == field.default)
        .help(value == field.default
              ? "Already at default"
              : "Reset to manifest default")
    }

    // MARK: - Formatting

    private func formatMods(_ mods: [String]) -> String {
        Hotkey.sortedMods(mods).map(Hotkey.modGlyph).joined()
    }

    // MARK: - Capture

    private func startMonitoring() {
        maxHeld = []
        liveHeld = []
        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.flagsChanged, .keyDown]) { event in
            // Bare Escape cancels.
            if event.type == .keyDown {
                if event.keyCode == 53 {
                    recording = false
                }
                // Eat any keypress during recording — we only want mods.
                return nil
            }
            // flagsChanged.
            let mods = activeMods(event.modifierFlags)
            liveHeld = Hotkey.sortedMods(mods)
            if mods.isEmpty {
                // Released everything. If anything was held during this
                // session, commit the max set; otherwise quietly stop.
                if !maxHeld.isEmpty {
                    value = Hotkey.sortedMods(Array(maxHeld))
                }
                recording = false
            } else {
                maxHeld.formUnion(mods)
            }
            return nil
        }
    }

    private func stopMonitoring() {
        if let m = monitor {
            NSEvent.removeMonitor(m)
            monitor = nil
        }
        maxHeld = []
        liveHeld = []
    }

    /// Same modifier extraction as `HotkeyRecorderField`, plus `fn` —
    /// modifier-only chords can include `fn`, which `hs.eventtap`
    /// surfaces via `flags.fn` even though `hs.hotkey.bind` doesn't.
    private func activeMods(_ flags: NSEvent.ModifierFlags) -> [String] {
        let masked = flags.intersection(.deviceIndependentFlagsMask)
        var out: [String] = []
        if masked.contains(.control)  { out.append("ctrl") }
        if masked.contains(.option)   { out.append("alt") }
        if masked.contains(.shift)    { out.append("shift") }
        if masked.contains(.command)  { out.append("cmd") }
        if masked.contains(.function) { out.append("fn") }
        return out
    }
}
