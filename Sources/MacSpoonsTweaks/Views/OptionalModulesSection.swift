import SwiftUI
import MacSpoonsTweaksKit

/// "Optional native modules" section rendered in `SpoonDetailView`. One
/// row per `OptionalModule` from the Spoon's manifest. Each row shows
/// the require name, the description, an install-state pill, an action
/// button (`Install` / `Update` / `Remove`), and a clickable GitHub
/// link. After a successful install, a yellow banner reminds the user
/// to quit + relaunch Hammerspoon (native modules only `dlopen` at
/// process start).
struct OptionalModulesSection: View {
    let modules: [OptionalModule]
    @EnvironmentObject private var catalog: SpoonCatalogModel

    var body: some View {
        if !modules.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Optional native modules").scaledFont(.headline)
                ForEach(modules, id: \.name) { module in
                    OptionalModuleRow(module: module)
                }
            }
        }
    }
}

private struct OptionalModuleRow: View {
    let module: OptionalModule
    @EnvironmentObject private var catalog: SpoonCatalogModel
    @State private var actionInFlight = false
    @State private var lastError: String?
    @State private var justInstalled = false

    var body: some View {
        let status = catalog.moduleStatus(module)
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(module.name)
                    .font(.body.monospaced())
                Spacer()
                statusPill(status)
                actionButton(status)
            }
            Text(module.description)
                .scaledFont(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                Image(systemName: "link")
                    .foregroundStyle(.secondary)
                    .scaledFont(.caption2)
                Link(
                    "github.com/\(module.repo)",
                    destination: URL(
                        string: "https://github.com/\(module.repo)")!
                ).scaledFont(.caption)
            }
            if justInstalled {
                relaunchBanner
            }
            if let err = lastError {
                Text(err)
                    .scaledFont(.caption2)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(.gray.opacity(0.08)))
        .task { await catalog.refreshModuleLatestTag(module) }
    }

    private func statusPill(_ status: NativeModuleStatus) -> some View {
        let (label, color): (String, Color) = {
            if status.updateAvailable {
                return ("Update available", .orange)
            } else if status.installed {
                return (status.installedTag.map { "Installed \($0)" }
                        ?? "Installed", .green)
            } else {
                return ("Not installed", .secondary)
            }
        }()
        return Text(label)
            .scaledFont(.caption)
            .foregroundStyle(color)
    }

    @ViewBuilder
    private func actionButton(_ status: NativeModuleStatus) -> some View {
        if actionInFlight {
            ProgressView().controlSize(.small)
        } else if status.updateAvailable {
            Button("Update") {
                Task { await install() }
            }
        } else if status.installed {
            Button("Remove") {
                Task { await remove() }
            }
            .tint(.red)
        } else {
            Button("Install") {
                Task { await install() }
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var relaunchBanner: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .foregroundStyle(.orange)
            Text("Quit and relaunch Hammerspoon to load the new module.")
                .scaledFont(.caption)
            Spacer()
            Button("Dismiss") { justInstalled = false }
                .buttonStyle(.plain)
                .scaledFont(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(.orange.opacity(0.12)))
    }

    private func install() async {
        actionInFlight = true
        lastError = nil
        do {
            try await catalog.installModule(module)
            justInstalled = true
        } catch {
            lastError = String(describing: error)
        }
        actionInFlight = false
    }

    private func remove() async {
        actionInFlight = true
        lastError = nil
        do {
            try catalog.removeModule(module)
            justInstalled = false
        } catch {
            lastError = String(describing: error)
        }
        actionInFlight = false
    }
}
