import SwiftUI
import MacSpoonsTweaksKit

/// Segmented control when there are 3 or fewer options (all visible
/// at once); menu otherwise. Matches the plan's "≤3 → segmented" rule.
struct EnumPickerView: View {
    let field: EnumField
    @Binding var value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(field.label ?? field.key)
                Spacer()
                if field.enum.count <= 3 {
                    Picker("", selection: $value) {
                        ForEach(field.enum, id: \.value) { opt in
                            Text(opt.label).tag(opt.value)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 280)
                } else {
                    Picker("", selection: $value) {
                        ForEach(field.enum, id: \.value) { opt in
                            Text(opt.label).tag(opt.value)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(maxWidth: 200)
                }
            }
            if let desc = field.description {
                Text(desc).scaledFont(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
