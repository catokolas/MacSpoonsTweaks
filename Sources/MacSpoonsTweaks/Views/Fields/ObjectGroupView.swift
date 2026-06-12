import SwiftUI
import MacSpoonsTweaksKit

/// Collapsible group for nested config objects (e.g.
/// MouseTrackpadTweaks.middleClick). Recursively renders a
/// `ConfigFormView` against the inner `[String: ConfigValue]`.
struct ObjectGroupView: View {
    let field: ObjectField
    @Binding var nested: [String: ConfigValue]

    @State private var expanded: Bool = true

    var body: some View {
        DisclosureGroup(
            isExpanded: $expanded,
            content: {
                ConfigFormView(fields: field.fields, values: $nested)
                    .padding(.leading)
                    .padding(.top, 4)
            },
            label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(field.label ?? field.key)
                        .scaledFont(.headline)
                    if let desc = field.description {
                        Text(desc).scaledFont(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        )
    }
}
