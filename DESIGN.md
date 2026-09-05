# Sidemesh interface direction

Sidemesh is a control surface for coding agents used on both phones and
desktops. The interface should feel calm, direct, and native enough to
disappear while someone is monitoring or steering real work.

## Interface rules

1. **Canvas, not cards.** Prose sits on the background. Borders are for inputs,
   code blocks, and terminal output.
2. **Rows are one line.** Glyph, title, status. Move information constant across
   a group into its header; search results may add a matching snippet.
3. **Group by workspace.** The folder is the unit. Show the machine only when
   more than one is in play. Preserve repository grouping across worktrees.
4. **Status is a word.** Avoid repeating one state as a dot, badge, and border.
5. **Chrome on demand.** Show timestamps, copy, and pin on hover, keyboard focus,
   or long-press. Suppress repeated timestamps within the same minute.
6. **Serif for reading.** Source Serif 4 is the agent document face. Mono stays
   for commands, branches, and diffs. Interface controls retain the user's font
   choice; system sans remains the default and Brand Sans remains opt-in.

## Colour budget

Keep the Nord palette and existing theme choices. Use accent for things wanting
human attention: needs-review groups, attention indicators, and send. Green/red
identify diff numerals; green also identifies live machines and running sessions.
Use neutral text for ordinary metadata. Do not use inventory counts as attention
badges. Retain the desktop rail and show pending actions in the Sessions pane.

## Hierarchy

- The canvas establishes the page. Do not place a card around the page itself.
- Use plain headings and rows for structure. A filled surface groups related
  information; a border identifies an input, code block, terminal output, or error.
- Never place a bordered card inside another bordered card.
- Keep one obvious primary action per region. Put uncommon recovery and
  destructive actions in an overflow menu.
- Status should have one primary visual signal. Do not repeat the same state as
  a dot, badge, colored sentence, and border.

## Navigation and adaptive behavior

- On phones, substantial setup flows are full pages. Contextual single-choice
  selectors may use an edge-to-edge sheet, including searchable model lists,
  when preserving the current task matters more than exposing new navigation.
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
  establish grouping. Reserve `bordered: true` for inputs and errors.
- Adjacent composer controls share one stable visual shell. Inherited and
  overridden values must not look like different kinds of control.
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
