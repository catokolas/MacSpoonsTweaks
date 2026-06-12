import SwiftUI
import MacSpoonsTweaksKit

/// Add/remove rows over a `[String]` slot. Each row is a `TextField`
/// bound to its index in the array.
struct StringListEditor: View {
    let field: StringListField
    @Binding var value: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(field.label ?? field.key)
                Spacer()
                Button {
                    value.append("")
                } label: {
                    Image(systemName: "plus.circle")
                }
                .buttonStyle(.plain)
                .help("Add row")
            }
            if let desc = field.description {
                Text(desc).scaledFont(.caption).foregroundStyle(.secondary)
            }
            ForEach(value.indices, id: \.self) { idx in
                HStack {
                    TextField(
                        field.itemPlaceholder ?? "",
                        text: $value[idx]
                    )
                    .textFieldStyle(.roundedBorder)
                    Button {
                        // Remove only if the index is still valid — SwiftUI
                        // can hand us a stale closure if rows shift.
                        if idx < value.count {
                            value.remove(at: idx)
                        }
                    } label: {
                        Image(systemName: "minus.circle")
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                    .help("Remove row")
                }
            }
            if value.isEmpty {
                Text("(empty — click + to add)")
                    .scaledFont(.caption).foregroundStyle(.tertiary)
            }
        }
    }
}
