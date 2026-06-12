import SwiftUI
import MacSpoonsTweaksKit

/// "Manage catalogs…" sheet. Lists the two built-in sources (read-only)
/// followed by every user-added catalog. The bottom half is an
/// add-catalog form that probes the GitHub repo for a
/// `spoons.json` before persisting.
struct ManageCatalogsView: View {
    @EnvironmentObject private var catalog: SpoonCatalogModel
    @Environment(\.dismiss) private var dismiss

    @State private var userConfigs: [CustomCatalogConfig] = []
    @State private var newOwner    = ""
    @State private var newRepo     = ""
    @State private var newBranch   = "main"
    @State private var newDesc     = ""
    @State private var addInFlight = false
    @State private var addError:   String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Catalogs").scaledFont(.title2, weight: .bold)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }

            builtInsList
            Divider()
            userList
            Divider()
            addForm
            Spacer(minLength: 0)
            footer
        }
        .padding(20)
        // Flexible sizing so larger Dynamic Type presets don't clip
        // the form fields or wrap the catalog rows.
        .frame(minWidth: 600, idealWidth: 700,
               minHeight: 560, idealHeight: 640)
        .onAppear { userConfigs = catalog.customCatalogConfigs() }
    }

    private var builtInsList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Built-in").scaledFont(.headline)
            BuiltInRow(
                id: "catokolas",
                owner: "catokolas",
                repo: "HS_SpoonsContrib",
                description: "Curated Spoons + manifests this app reads")
            BuiltInRow(
                id: "hammerspoon-official",
                owner: "Hammerspoon",
                repo: "Spoons",
                description: "Upstream collection")
        }
    }

    private var userList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("User-added").scaledFont(.headline)
            if userConfigs.isEmpty {
                Text("(none — add one below)")
                    .scaledFont(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(userConfigs, id: \.id) { cfg in
                    UserCatalogRow(config: cfg) {
                        userConfigs = catalog.customCatalogConfigs()
                    }
                }
            }
        }
    }

    private var addForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Add a catalog").scaledFont(.headline)
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "info.circle")
                    .foregroundStyle(.secondary)
                    .imageScale(.small)
                Text("Catalogs must be hosted on github.com. Enter the repository as `owner/repo` — the app fetches `spoons.json` from `raw.githubusercontent.com/<owner>/<repo>/<branch>/spoons.json`.")
                    .scaledFont(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                // minWidth lets the fields grow with larger Dynamic
                // Type presets — fixed widths used to truncate the
                // placeholder at Accessibility sizes.
                TextField("owner", text: $newOwner)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 130)
                Text("/")
                TextField("repo", text: $newRepo)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 200)
                TextField("branch", text: $newBranch)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 80)
            }
            TextField("Description (optional)", text: $newDesc)
                .textFieldStyle(.roundedBorder)
            HStack {
                if addInFlight { ProgressView().controlSize(.small) }
                if let err = addError {
                    Text(err)
                        .scaledFont(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
                Spacer()
                Button("Add") {
                    Task { await runAdd() }
                }
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.borderedProminent)
                .disabled(addInFlight
                          || newOwner.trimmingCharacters(in: .whitespaces).isEmpty
                          || newRepo.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private var footer: some View {
        Text("Catalogs must publish a spoons.json matching the schema. See DEVELOPERS.md → \"Compatible catalog format\".")
            .scaledFont(.caption)
            .foregroundStyle(.secondary)
    }

    private func runAdd() async {
        addInFlight = true
        addError = nil
        let ok = await catalog.addCustomCatalog(
            owner:       newOwner.trimmingCharacters(in: .whitespaces),
            repo:        newRepo.trimmingCharacters(in: .whitespaces),
            branch:      newBranch.trimmingCharacters(in: .whitespaces),
            description: newDesc.isEmpty ? nil : newDesc)
        addInFlight = false
        if ok {
            newOwner = ""; newRepo = ""; newDesc = ""
            newBranch = "main"
            userConfigs = catalog.customCatalogConfigs()
        } else {
            addError = "Couldn't reach spoons.json at "
                + "raw.githubusercontent.com/\(newOwner)/\(newRepo)/\(newBranch)/spoons.json"
        }
    }
}

private struct BuiltInRow: View {
    let id:          String
    let owner:       String
    let repo:        String
    let description: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.fill")
                .foregroundStyle(.secondary)
                .imageScale(.small)
                .help("Built-in — can't be removed")
            VStack(alignment: .leading, spacing: 1) {
                Text("\(owner)/\(repo)").scaledFont(.body)
                Text(description)
                    .scaledFont(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("", isOn: .constant(true)).disabled(true).labelsHidden()
        }
        .padding(.vertical, 2)
    }
}

private struct UserCatalogRow: View {
    let config: CustomCatalogConfig
    let onChange: () -> Void
    @EnvironmentObject private var catalog: SpoonCatalogModel
    @State private var busy = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "folder.badge.gearshape")
                .foregroundStyle(.secondary)
                .imageScale(.small)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(config.owner)/\(config.repo)").scaledFont(.body)
                HStack(spacing: 4) {
                    Text("branch: \(config.branch)")
                    if let desc = config.description, !desc.isEmpty {
                        Text("·")
                        Text(desc)
                    }
                }
                .scaledFont(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            if busy {
                ProgressView().controlSize(.small)
            }
            Toggle("", isOn: Binding(
                get: { config.enabled },
                set: { enabled in
                    Task {
                        busy = true
                        await catalog.setCatalogEnabled(
                            id: config.id, enabled: enabled)
                        onChange()
                        busy = false
                    }
                }))
            .labelsHidden()
            .disabled(busy)
            Button {
                Task {
                    busy = true
                    await catalog.removeCustomCatalog(id: config.id)
                    onChange()
                    busy = false
                }
            } label: {
                Image(systemName: "minus.circle.fill")
                    .foregroundStyle(.red)
            }
            .buttonStyle(.plain)
            .disabled(busy)
            .help("Remove")
        }
        .padding(.vertical, 2)
    }
}
