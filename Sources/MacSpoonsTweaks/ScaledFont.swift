import SwiftUI

// MARK: - Environment key

private struct AppFontScaleKey: EnvironmentKey {
    static let defaultValue: CGFloat = 1.0
}

extension EnvironmentValues {
    /// Multiplier applied to every `.scaledFont(_:weight:)` call.
    /// Driven by the user's `FontSizePreset` from the toolbar
    /// controls. Defaults to 1.0 so tests + previews render at the
    /// system size.
    var appFontScale: CGFloat {
        get { self[AppFontScaleKey.self] }
        set { self[AppFontScaleKey.self] = newValue }
    }
}

// MARK: - Public modifier

/// Drop-in replacement for `.font(...)` that scales the text by the
/// `\.appFontScale` environment value. Use everywhere instead of
/// `.font(.body)` / `.font(.headline)` / etc. so the user's
/// font-size preset visibly resizes every text.
///
/// macOS SwiftUI honours `.dynamicTypeSize` inconsistently on macOS
/// 26+ — explicit point-size math via `.system(size:weight:)` lets
/// us bypass that and scale predictably.
extension View {
    func scaledFont(_ style: AppFontStyle,
                    weight: Font.Weight? = nil,
                    design: Font.Design = .default) -> some View {
        modifier(ScaledFontModifier(
            style: style, weight: weight, design: design))
    }
}

/// Closed set of text styles the app uses. Each maps to a baseline
/// point size; the modifier multiplies by the current scale.
public enum AppFontStyle {
    case caption2
    case caption
    case footnote
    case subheadline
    case callout
    case body
    case headline
    case title3
    case title2
    case title
    case largeTitle

    var baseSize: CGFloat {
        switch self {
        case .caption2:    return 10
        case .caption:     return 11
        case .footnote:    return 12
        case .subheadline: return 12
        case .callout:     return 13
        case .body:        return 13
        case .headline:    return 13   // bold via weight, not size
        case .title3:      return 15
        case .title2:      return 17
        case .title:       return 22
        case .largeTitle:  return 28
        }
    }

    /// Default weight for the style — `.headline` is bold by SwiftUI
    /// convention; the rest are regular unless the caller overrides.
    var defaultWeight: Font.Weight {
        switch self {
        case .headline: return .semibold
        default:        return .regular
        }
    }
}

private struct ScaledFontModifier: ViewModifier {
    @Environment(\.appFontScale) private var scale: CGFloat
    let style:  AppFontStyle
    let weight: Font.Weight?
    let design: Font.Design

    func body(content: Content) -> some View {
        content.font(.system(
            size:   style.baseSize * scale,
            weight: weight ?? style.defaultWeight,
            design: design))
    }
}
