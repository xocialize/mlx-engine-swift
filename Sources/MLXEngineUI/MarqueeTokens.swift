//
//  MarqueeTokens.swift
//  MLXEngineUI
//
//  Design tokens translated from the MarqueeStudio Figma library
//  (file UFh5Y592c8aaa9Bk3R2SJb). These are the shared color, typography,
//  and metric primitives that every MLXEngine UI surface is built from, so
//  consuming apps render a consistent look without re-deriving values.
//

import SwiftUI

// MARK: - Color tokens

/// The Marquee color palette. Values mirror the Figma "Marquee Colors" collection.
public enum MarqueeColor {
    // Backgrounds
    public static let bgPrimary = Color(hex: 0x1E1E1E)
    public static let bgSecondary = Color(hex: 0x252526)
    public static let bgHeader = Color(hex: 0x323233)
    public static let bgElevated = Color(hex: 0x3C3C3C)
    public static let bgInput = Color(hex: 0x2D2D2D)

    // Text
    public static let textPrimary = Color(hex: 0xCCCCCC)
    public static let textSecondary = Color(hex: 0x8C8C8C)
    public static let textMuted = Color(hex: 0x5C5C5C)

    // Accents
    public static let accentBlue = Color(hex: 0x0A84FF)
    public static let accentGold = Color(hex: 0xD7BA7D)
    public static let selectionBackground = Color(hex: 0x094771)

    // Semantic
    public static let success = Color(hex: 0x32D74B)
    public static let warning = Color(hex: 0xFF9F0A)
    public static let error = Color(hex: 0xFF453A)
}

// MARK: - Typography tokens

/// The Marquee type ramp. SF Pro is the system font on Apple platforms, so each
/// token maps to `Font.system` at the size/weight documented in the Figma board.
public enum MarqueeFont {
    /// SF Pro 18 Semibold — page / panel titles.
    public static let pageTitle = Font.system(size: 18, weight: .semibold)
    /// SF Pro 11 Semibold — uppercase section headers (pair with `.tracking(0.5)`).
    public static let sectionHeader = Font.system(size: 11, weight: .semibold)
    /// SF Pro 13 Medium — emphasized row labels.
    public static let bodyMedium = Font.system(size: 13, weight: .medium)
    /// SF Pro 13 Regular — standard body text.
    public static let body = Font.system(size: 13, weight: .regular)
    /// SF Pro 12 Regular — captions and helper text.
    public static let caption = Font.system(size: 12, weight: .regular)
}

// MARK: - Metric tokens

/// Spacing, corner-radius, and sizing constants used across Marquee panels.
public enum MarqueeMetric {
    public static let panelPadding: CGFloat = 24
    public static let groupCornerRadius: CGFloat = 8
    public static let controlCornerRadius: CGFloat = 6
    public static let controlHeight: CGFloat = 28
    public static let rowHeight: CGFloat = 52

    // MARK: Settings-window geometry

    /// Width of the settings sidebar (section list).
    public static let sidebarWidth: CGFloat = 200
    /// The 1pt rule between sidebar and detail.
    public static let hairline: CGFloat = 1
    /// Width of a settings detail panel, **inclusive of `panelPadding`** — the panels apply
    /// `.padding(panelPadding)` *inside* a `.frame(width:)`, so this is the total, not the content box.
    public static let panelWidth: CGFloat = 520

    /// The narrowest width `EngineSettingsView` can render without clipping — **derived**, never
    /// typed in by hand.
    ///
    /// It shipped as a hardcoded `720` while the columns summed to `sidebarWidth + hairline +
    /// panelWidth` = **721**, so the declared minimum was 1pt under the content it was supposed to
    /// admit and the detail column clipped for any host that trusted it. A hardcoded minimum is a
    /// second source of truth for a number the layout already knows; deriving it means changing a
    /// column can't silently invalidate the window.
    public static var settingsMinWidth: CGFloat { sidebarWidth + hairline + panelWidth }

    /// A reasonable opening height for the settings window. **Not** a content guarantee: the detail
    /// column scrolls, because the model-storage panel grows a row per installed model and no fixed
    /// height can bound it.
    public static let settingsMinHeight: CGFloat = 620
}

// MARK: - Hex helper

extension Color {
    /// Creates a color from a 24-bit RGB hex value (e.g. `0x1E1E1E`).
    init(hex: UInt32) {
        let r = Double((hex >> 16) & 0xFF) / 255.0
        let g = Double((hex >> 8) & 0xFF) / 255.0
        let b = Double(hex & 0xFF) / 255.0
        self.init(.sRGB, red: r, green: g, blue: b, opacity: 1.0)
    }
}
