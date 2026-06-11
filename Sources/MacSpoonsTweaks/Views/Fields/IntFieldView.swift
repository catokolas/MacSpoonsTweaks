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
                if let range = boundedRange {
                    // Stepper internally computes
                    // `lowerBound.distance(to: upperBound)` on Int,
                    // which overflows and traps for Int.min ... Int.max.
                    // Only render it when both bounds are sane.
                    Stepper(
                        "",
                        value: $value,
                        in: range,
                        step: field.step ?? 1)
                    .labelsHidden()
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
                Text(desc).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// Only emit a range when both bounds exist AND don't risk
    /// overflow in `Strideable.distance(to:)`. Inferred upstream fields
    /// (BonjourLauncher etc.) often leave min/max unset.
    private var boundedRange: ClosedRange<Int>? {
        guard let lo = field.min, let hi = field.max, lo <= hi
        else { return nil }
        return lo...hi
    }
}
