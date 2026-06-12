import SwiftUI
import MacSpoonsTweaksKit

/// Number field. Slider + TextField when both min and max are present
/// (gives the user fine-grained dragging plus a way to type exact
/// values); plain TextField otherwise.
struct NumberFieldView: View {
    let field: NumberField
    @Binding var value: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(field.label ?? field.key)
                Spacer()
                if let min = field.min, let max = field.max {
                    Slider(
                        value: $value,
                        in: min...max,
                        step: field.step ?? 0.01
                    )
                    .frame(maxWidth: 200)
                }
                TextField("", value: $value, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 80)
                    .multilineTextAlignment(.trailing)
                if let unit = field.unit {
                    Text(unit).foregroundStyle(.secondary)
                }
            }
            if let desc = field.description {
                Text(desc).scaledFont(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
