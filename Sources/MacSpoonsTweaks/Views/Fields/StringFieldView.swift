import SwiftUI
import MacSpoonsTweaksKit

struct StringFieldView: View {
    let field: StringField
    @Binding var value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(field.label ?? field.key)
                Spacer()
                TextField(
                    field.itemPlaceholder ?? "",
                    text: $value
                )
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 240)
            }
            if let desc = field.description {
                Text(desc).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
