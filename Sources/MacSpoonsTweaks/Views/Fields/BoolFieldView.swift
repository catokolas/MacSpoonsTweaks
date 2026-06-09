import SwiftUI
import MacSpoonsTweaksKit

struct BoolFieldView: View {
    let field: BoolField
    @Binding var value: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Toggle(field.label ?? field.key, isOn: $value)
            if let desc = field.description {
                Text(desc).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
