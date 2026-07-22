# Sidemesh interface direction

Sidemesh is a control surface for coding agents used on both phones and
desktops. The interface should feel calm, direct, and native enough to
disappear while someone is monitoring or steering real work.

## Hierarchy

- The canvas establishes the page. Do not place a card around the page itself.
- Use plain headings and rows for structure. A filled surface groups related
  information; a border identifies a control, selection, warning, or explicit
  boundary.
- Never place a bordered card inside another bordered card.
- Keep one obvious primary action per region. Put uncommon recovery and
  destructive actions in an overflow menu.
- Status should have one primary visual signal. Do not repeat the same state as
  a dot, badge, colored sentence, and border.

## Navigation and adaptive behavior

- On phones, substantial setup and selection flows are full pages. Bottom
  sheets are for short choices and confirmations.
- On desktop, use the rail, list pane, detail pane, and inspector as the main
  hierarchy. Dialogs are appropriate for compact global preferences.
- Responsive behavior changes structure, not merely padding. Dense desktop
  rows should stay flat; wide data surfaces may use columns.
- Search and filters should be available on demand rather than permanently
  consuming mobile vertical space.

## Components

- Mobile pages use a 16 px horizontal gutter. Desktop management pages use a
  24 px gutter and an 840 px maximum content width.
- Interactive controls are 48 px high. Management rows have a 56 px minimum
  content height. Leading UI icons are 20 px and share the row label grid.
- The spacing scale is 4, 8, 12, 16, 24, and 32 px. Screen code should use the
  named tokens rather than near-duplicate values.
- `AppSectionHeader`, `AppSettingsRow`, `AppChoiceRow`, `AppListSection`,
  `AppContentColumn`, and `AppIconWell` are the canonical management and
  selection primitives. Their alignment and sizing should not be recreated in
  individual screens.
- Mobile bottom sheets sit edge-to-edge against the viewport and are reserved
  for short choices or transient actions. Do not place another floating card
  around the sheet. Long setup and browsing flows remain full pages.
- `MeshSurface` and `MeshCard` may be borderless when fill and spacing already
  establish grouping. Reserve `bordered: true` for inputs, selection, errors,
  warnings, and independently actionable objects.
- Pills are metadata or status, not general-purpose buttons.
- Use platform controls such as `Switch`, text fields, and standard buttons
  unless the product requires behavior they cannot express.
- Empty and loading states should resemble the surface they replace and teach
  the next useful action.

## Color, type, and motion

- Use the restrained palette from `AppColors`: tinted neutrals and one accent,
  with semantic colors reserved for actual state.
- Use the app typography scale and keep explanatory copy short. A heading does
  not need a paragraph that restates it.
- Body copy uses regular weight, ordinary emphasis uses medium, component
  titles use semibold, and bold is reserved for page titles or rare values.
- Use 150–250 ms motion only to communicate selection, reveal, navigation, or
  state changes. Avoid decorative animation.
