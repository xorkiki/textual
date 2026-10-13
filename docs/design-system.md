# Textual design system

Repeated UI belongs in `textual/DesignSystem`. Features select shared roles and components; they do not define their own font families, page-title sizes, back arrows, or dropdown styling.

- **Typography:** `Font+DesignSystem.swift` owns families, sizes, Dynamic Type roles, and the UIKit bridge. Use `.textStyle(.bodyMedium)` or `.font(.designSystem(.bodyMedium))`. Page titles use `.heading3`; repeated section headings use `.sectionHeading`. Natural font line heights replace negative line spacing.
- **Palette:** `Color+Theme.swift` owns brand colors and semantic surfaces. Control, selection, cover-placeholder, and reader-card surfaces are opaque colors flattened over inkwell from the base palette; scrolling content must not show through them. UIKit appearance and chart colors use these same colors.
- **Headers:** `TextualNavigationChrome.swift` owns `TextualHeader`, `TextualHeading`, back buttons, safe-area placement, and background fades. Use `.textualPageHeader { TextualHeader(title: ...) { actions } }`, `.textualBackHeader`, or `.textualSheetHeader`. Headers use the same page inset and control height, with actions moving below long titles or large accessibility text. Do not add feature-specific header padding or native toolbar titles.
- **Buttons:** `TextualButtonStyle` supplies primary, secondary, and tonal capsule variants. `IconButtonStyle` and `TextualHeaderActionStyle` own navigation action sizing and enabled/pressed feedback. Account wrappers only retain labels, busy state, and accessibility identifiers.
- **Search and filters:** `TextualSearchField` supplies the same field across catalog, archive, and shelf selection. `TextualDropdown` and its host own the menu interaction and appearance; labels and measured menu widths use the shared typography.
- **Layout and icons:** `TextualLayout` owns recurring page/control geometry; `TextualNavigationLayout` owns the footer dimensions. `TextualIconStyle` separates symbol sizes from text styles.

The library card intentionally retains its printed proportions, scaled typography, and green surface. `ReaderCardTypography` references the shared font families and keeps the card-specific type scale together. Welcome typography has named brand roles. Feature-specific chart geometry and book-cover aspect ratios remain with their components.

Long-press book menus use `textualContextMenu`: app-owned charcoal content in an opaque popover, with native presentation and dismissal animations. Use this shared modifier instead of native glass context menus. System alerts, confirmation dialogs, photo/file pickers, and keyboard UI retain platform behavior. Their system-owned appearance is not duplicated in feature code.

Run `python3 scripts/check-design-system.py` to catch typography, palette, and native-title definitions reintroduced outside the design system. `DesignSystemTests` checks typography scaling, UIKit theme linkage, narrow/large-text header rendering, and a visual component gallery. `AppFontTests` verifies the bundled fonts. Auth UI tests cover the existing account navigation and validation paths.

## La Luxes Serif

The supplied `LaLuxes.otf` is bundled at `textual/Resources/Fonts/LaLuxes.otf` and registered in `Info.plist`. Its internal PostScript name is `LaLuxesSerifW05-Regular`; select it through `TextualFontFamily.laLuxesSerif` rather than repeating the font name in features.

For future brand and display text, use `.textStyle(.brandDisplay)` or `.font(.designSystem(.brandDisplay))`. This optional role uses La Luxes Serif Regular at 64 pt and scales with the large-title Dynamic Type setting. Existing typography roles keep their current families.

The file was supplied by the user on October 12, 2026. No license document accompanied it; adding the asset does not establish usage or redistribution rights.

## Icon registry

`Icon+DesignSystem.swift` maps the supplied SVGs to typed `DesignSystemIcon` values. `Assets.xcassets` is the bundled vector source of truth; template rendering makes icons inherit the shared palette. Features use `DesignSystemIconView` or `Label(..., textualIcon: ...)`.

The tab mapping is Profile → profile, My Archive → bookmark-book, The Archive → community, Stats → pie-chart, Menu → menu. Search and empty-book states use search/open-book; dropdowns use chevron-up/chevron-down; back/forward navigation uses the supplied arrows. Ratings use the supplied star and a filled variant derived from its exact outline, including fractional ratings.

Utility symbols missing from the supplied set are registered centrally so they can be replaced once for every caller. All supplied assets remain available for features that need them. The asset-loading test verifies every registered icon, and the source-boundary check rejects screen-owned system-symbol names.

### Line Rounded additions

All ten SVGs from the supplied Line Rounded folder are registered as tintable vector assets. Plus, trash, eye, check circle, checkmark, and close circle now supply the existing add/remove, preview/password-visibility, selection, dropdown-check, and clear-search actions. The Stats tab uses pie-chart. `edit`, `heart`, and `settings` are available for future features; the previous `report` asset remains available too.

Only `conceal` (crossed-out eye), `unselected` (empty circle), and `warning` (circled exclamation) still use system fallbacks because those variants were not included. Their mappings remain in the shared registry.

All four supplied chevrons are registered as `chevronDown`, `chevronUp`, `chevronLeft`, and `chevronRight`. Shared dropdowns use down while closed and up while open. Left/right chevrons are available for future controls. Navigation back/forward arrows remain separate roles.

Dismiss buttons in sheets and popups use `TextualCloseButton` with the plain `close` X asset. The circled `clear` icon is reserved for clearing search fields.
