import SwiftUI
import MacSpoonsTweaksKit

/// SwiftUI bridge for `FontSizePreset`. The kit deliberately stores
/// the preset as a Foundation-only enum (Codable raw string) — this
/// extension translates each preset into the rendering bits the app
/// injects into the SwiftUI environment.
extension FontSizePreset {
    /// SwiftUI's built-in Dynamic Type knob. Honoured by `.body`,
    /// `.headline`, etc. when scaling works. Kept around as a hint
    /// for accessibility tooling even though we don't rely on it
    /// alone for visible scaling (macOS SwiftUI honours it inconsistently).
    var dynamicTypeSize: DynamicTypeSize {
        switch self {
        case .standard:       return .large
        case .xLarge:         return .xLarge
        case .xxLarge:        return .xxLarge
        case .xxxLarge:       return .xxxLarge
        case .accessibility1: return .accessibility1
        }
    }

    /// Direct point-size multiplier applied to every Text via the
    /// `\.font` environment override. Tuned so the steps are visibly
    /// distinct (the macOS default would yield ~1pt jumps).
    var sizeScale: CGFloat {
        switch self {
        case .standard:       return 1.0
        case .xLarge:         return 1.15
        case .xxLarge:        return 1.30
        case .xxxLarge:       return 1.50
        case .accessibility1: return 1.75
        }
    }
}
