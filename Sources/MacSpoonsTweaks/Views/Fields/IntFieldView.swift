import SwiftUI
import MacSpoonsTweaksKit

struct IntFieldView: View {
    let field: IntField
    @Binding var value: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(field.label ?? field.key)
                Spacer()
                Stepper(
                    "",
                    value: $value,
                    in: (field.min ?? .min)...(field.max ?? .max),
                    step: field.step ?? 1
                )
                .labelsHidden()
                TextField("", value: $value, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 80)
                    .multilineTextAlignment(.trailing)
                if let unit = field.unit {
                    Text(unit).foregroundStyle(.secondary)
                }
            }
            if let desc = field.description {
                Text(desc).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
