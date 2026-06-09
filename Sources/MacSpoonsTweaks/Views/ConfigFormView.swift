import SwiftUI
import MacSpoonsTweaksKit

/// Renders a Spoon's config schema as a typed SwiftUI form bound to a
/// `[String: ConfigValue]` slot. Used recursively by `ObjectGroupView`
/// for nested fields.
struct ConfigFormView: View {
    let fields: [ConfigField]
    @Binding var values: [String: ConfigValue]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(fields) { field in
                fieldView(for: field)
            }
        }
    }

    @ViewBuilder
    private func fieldView(for field: ConfigField) -> some View {
        switch field {
        case .bool(let f):
            BoolFieldView(
                field: f,
                value: $values.bool(forKey: f.key, default: f.default))
        case .int(let f):
            IntFieldView(
                field: f,
                value: $values.int(forKey: f.key, default: f.default))
        case .number(let f):
            NumberFieldView(
                field: f,
                value: $values.double(forKey: f.key, default: f.default))
        case .string(let f):
            StringFieldView(
                field: f,
                value: $values.string(
                    forKey: f.key, default: f.default ?? ""))
        case .enumChoice(let f):
            EnumPickerView(
                field: f,
                value: $values.string(forKey: f.key, default: f.default))
        case .stringList(let f):
            StringListEditor(
                field: f,
                value: $values.stringList(
                    forKey: f.key, default: f.default))
        case .object(let f):
            ObjectGroupView(
                field: f,
                nested: $values.nestedDict(forKey: f.key))
        case .luaLiteral(let f):
            LuaLiteralEditor(
                field: f,
                value: $values.luaLiteral(
                    forKey: f.key, default: f.default))
        }
    }
}
