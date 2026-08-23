//
//  MarqueeTokens.swift
//  MLXEngineUI
//
//  DEPRECATED FORWARDERS onto DesignScaffold's `Tokens` — the fleet's single design
//  authority (AB-D-0042; convergence asked in AB-A-0019 and landed here).
//
//  These enums were born as hardcoded hex/values translated from the MarqueeStudio Figma
//  library. Authored dark, they rendered as a dark island inside light windows and could
//  not follow the user's appearance, accent colour, or Increase Contrast (evidence:
//  DesignScaffold AB-R-0128 — the light-mode divergence render). Every symbol now forwards
//  to the semantic token it was approximating, so:
//    - existing call sites keep compiling (source-compatible by construction),
//    - resolved VALUES adapt with the system (light mode changes visibly — that is the fix),
//    - the deprecation warnings are the migration worklist for external consumers.
//  The in-tree views have already migrated to `Tokens` directly; these forwarders exist for
//  API stability toward consuming apps and can be removed at the next major.
//
//  Symbols deliberately NOT forwarded (documented panel-local or pending):
//    - `panelWidth` / `settingsMinWidth` / `settingsMinHeight` — settings-window geometry,
//      a property of these panels rather than the fleet vocabulary.
//    - `accentGold` — Marquee brand accent, unused in-tree; kept only for API stability.
//    - `pageTitle` — awaiting `Tokens.Font.panelTitle` (18 semibold; requested with usage
//      evidence in AB-A-0019: three settings-panel headers at 520pt width, where the 22pt
//      `screenTitle` would be oversized).
//    - `bgElevated`'s FILL role — awaiting `Tokens.Color.fillElevated`. Its DIVIDER role
//      (4 of 6 sites) was split off to `Tokens.Color.separator` in-tree per the AB-A-0019
//      review; the two fill sites (capsule badge, secondary-button fill) keep this value
//      until the token ships.
//

import SwiftUI
import DesignScaffold

// MARK: - Color forwarders

public enum MarqueeColor {
    @available(*, deprecated, message: "Use Tokens.Color.surfaceElevated (AB-D-0042)")
    public static let bgPrimary = Tokens.Color.surfaceElevated
    @available(*, deprecated, message: "Use Tokens.Color.surface (AB-D-0042)")
    public static let bgSecondary = Tokens.Color.surface
    @available(*, deprecated, message: "Use Tokens.Color.surface (AB-D-0042); no header-specific token exists and nothing in-tree uses this")
    public static let bgHeader = Tokens.Color.surface
    /// ⚠️ Split symbol: divider uses moved to `Tokens.Color.separator` in-tree. This literal
    /// remains ONLY for the two fill sites (badge capsule, secondary-button fill) until
    /// DesignScaffold ships `Tokens.Color.fillElevated` (AB-A-0019 Q1 answer: split).
    public static let bgElevated = Color(.sRGB, red: 0x3C / 255.0, green: 0x3C / 255.0,
                                         blue: 0x3C / 255.0, opacity: 1.0)
    @available(*, deprecated, message: "Use Tokens.Color.fieldFill (AB-D-0042; note it sits darker in dark mode than the old #2D2D2D — that is adaptation, not regression)")
    public static let bgInput = Tokens.Color.fieldFill

    @available(*, deprecated, message: "Use Tokens.Color.label (AB-D-0042)")
    public static let textPrimary = Tokens.Color.label
    @available(*, deprecated, message: "Use Tokens.Color.secondaryLabel (AB-D-0042)")
    public static let textSecondary = Tokens.Color.secondaryLabel
    @available(*, deprecated, message: "Use Tokens.Color.tertiaryLabel (AB-D-0042)")
    public static let textMuted = Tokens.Color.tertiaryLabel

    @available(*, deprecated, message: "Use Tokens.Color.accent — follows the user's accent instead of pinning macOS dark system blue (AB-D-0042)")
    public static let accentBlue = Tokens.Color.accent
    /// Marquee brand accent — deliberately panel-local (AB-A-0019 mapping table), unused in-tree.
    public static let accentGold = Color(.sRGB, red: 0xD7 / 255.0, green: 0xBA / 255.0,
                                         blue: 0x7D / 255.0, opacity: 1.0)
    @available(*, deprecated, message: "Use Tokens.Color.selectionWash (AB-D-0042)")
    public static let selectionBackground = Tokens.Color.selectionWash

    @available(*, deprecated, message: "Use Tokens.Color.ready (AB-D-0042)")
    public static let success = Tokens.Color.ready
    @available(*, deprecated, message: "Use Tokens.Color.working (AB-D-0042)")
    public static let warning = Tokens.Color.working
    @available(*, deprecated, message: "Use Tokens.Color.failure (AB-D-0042)")
    public static let error = Tokens.Color.failure
}

// MARK: - Typography forwarders

public enum MarqueeFont {
    /// Awaiting `Tokens.Font.panelTitle` (AB-A-0019) — the one type-ramp addition requested.
    public static let pageTitle = Font.system(size: 18, weight: .semibold)
    @available(*, deprecated, message: "Use Tokens.Font.caption.weight(.semibold) (AB-D-0042)")
    public static let sectionHeader = Tokens.Font.caption.weight(.semibold)
    @available(*, deprecated, message: "Use Tokens.Font.body.weight(.medium) (AB-D-0042)")
    public static let bodyMedium = Tokens.Font.body.weight(.medium)
    @available(*, deprecated, message: "Use Tokens.Font.body (AB-D-0042)")
    public static let body = Tokens.Font.body
    @available(*, deprecated, message: "Use Tokens.Font.caption (AB-D-0042; 12 → 11, an accepted visual change)")
    public static let caption = Tokens.Font.caption
}

// MARK: - Metric forwarders

public enum MarqueeMetric {
    @available(*, deprecated, message: "Use Tokens.Space.xl (AB-D-0042)")
    public static let panelPadding = Tokens.Space.xl
    @available(*, deprecated, message: "Use Tokens.Radius.container (AB-D-0042; 8 → 12, kit-measured)")
    public static let groupCornerRadius = Tokens.Radius.container
    @available(*, deprecated, message: "Use Tokens.Radius.control (AB-D-0042)")
    public static let controlCornerRadius = Tokens.Radius.control
    @available(*, deprecated, message: "Use Tokens.Layout.controlHeight (AB-D-0042; 28 → 24)")
    public static let controlHeight = Tokens.Layout.controlHeight
    @available(*, deprecated, message: "Use Tokens.Layout.rowHeight (AB-D-0042; 52 → 42)")
    public static let rowHeight = Tokens.Layout.rowHeight
    @available(*, deprecated, message: "Use Tokens.Layout.sidebarWidth (AB-D-0042; 200 → 260)")
    public static let sidebarWidth = Tokens.Layout.sidebarWidth
    @available(*, deprecated, message: "Use Tokens.Layout.hairline (AB-D-0042)")
    public static let hairline = Tokens.Layout.hairline

    // MARK: Settings-window geometry — panel-local BY DESIGN (not fleet vocabulary)

    /// Width of a settings detail panel, **inclusive of `panelPadding`** — the panels apply
    /// `.padding(panelPadding)` *inside* a `.frame(width:)`, so this is the total, not the
    /// content box.
    public static let panelWidth: CGFloat = 520

    /// The narrowest width `EngineSettingsView` can render without clipping — **derived**, never
    /// typed in by hand.
    ///
    /// It shipped as a hardcoded `720` while the columns summed to `sidebarWidth + hairline +
    /// panelWidth` = **721**, so the declared minimum was 1pt under the content it was supposed
    /// to admit and the detail column clipped for any host that trusted it. A hardcoded minimum
    /// is a second source of truth for a number the layout already knows; deriving it means
    /// changing a column can't silently invalidate the window. (Now derives from the TOKEN
    /// sidebar width, so the 200 → 260 change flows through automatically.)
    public static var settingsMinWidth: CGFloat {
        Tokens.Layout.sidebarWidth + Tokens.Layout.hairline + panelWidth
    }

    /// A reasonable opening height for the settings window. **Not** a content guarantee: the
    /// detail column scrolls, because the model-storage panel grows a row per installed model
    /// and no fixed height can bound it.
    public static let settingsMinHeight: CGFloat = 620
}
