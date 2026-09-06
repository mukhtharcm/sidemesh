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

- On phones, substantial setup flows are full pages. Contextual single-choice
  selectors may use an edge-to-edge sheet, including searchable model lists,
  when preserving the current task matters more than exposing new navigation.
- On desktop, use one session sidebar, a detail pane, and an
  optional inspector. Put machine access and Settings at the sidebar foot. Show
  the attention list only when it has items. Keep Settings in one window with a category sidebar.
  Change the content in that window instead of opening another settings dialog.
- Keep model and effort controls at the composer on desktop and mobile.
  On mobile, effort is part of the model picker. Desktop session settings
  use a compact dialog for mode, speed, and access. Reserve the inspector for
  content such as files, resources, search, and agent runs.
- Responsive behavior uses the width of each pane, not only the app window.
  A narrow browser pane uses compact controls and fits the remote viewport by
  default. An explicit viewport preset remains fixed until Fit pane is selected.
  Dense desktop rows stay flat; wide data surfaces may use columns.
- Search and filters should be available on demand rather than permanently
  consuming mobile vertical space.

## Components

- Mobile pages use a 16 px horizontal gutter. Desktop management pages use a
  24 px gutter and an 840 px maximum content width.
- Desktop controls and menu rows use a 32 px minimum. Touch controls use 48 px
  and touch menu rows use 44 px. Management rows have a 56 px minimum
  content height. Leading UI icons are 20 px and share the row label grid.
- The primary spacing scale is 4, 8, 12, 16, 24, and 32 px. Dense
  tools also use named 2, 6, and 10 px steps; 1 px is reserved for fine alignment. Screen code should use the
  named tokens rather than near-duplicate values.
- `AppSectionHeader`, `AppSettingsRow`, `AppChoiceRow`, `AppListSection`,
  `AppContentColumn`, and `AppIconWell` are the canonical management and
  selection primitives. Their alignment and sizing should not be recreated in
  individual screens.
- Mobile bottom sheets are for short choices or transient actions. Long setup
  and browsing flows remain full pages.
- Model and effort choices share a compact inset sheet with rounded corners.
  Search opens from its header. Effort stays above the model list. Clip the
  scrolling list inside its rounded surface, and use a neutral description
  with an accent checkmark for selection.
- `MeshSurface` and `MeshCard` may be borderless when fill and spacing already
  establish grouping. Reserve `bordered: true` for inputs, selection, errors,
  warnings, and independently actionable objects.
- Adjacent composer controls share one stable visual shell. Inherited and
  overridden values must not look like different kinds of control.
- Pills are metadata or status, not general-purpose buttons.
- Use platform controls such as `Switch`, text fields, and standard buttons
  unless the product requires behavior they cannot express.
- First loads use `MeshLoader`: a short label and one immediate indicator.
  Do not draw fake cards, messages, charts, or controls while data loads.
  Keep cached content visible during refresh and use
  `MeshDelayedActivityIndicator` for background work.
- Empty states explain the next useful action.
- Use the session list as the reference for management pages: quiet canvas,
  plain elevated cards, clear titles, and secondary metadata. `MeshCard`
  keeps borders for explicit state or when the caller requests them.

## Color, type, and motion

- Use the restrained palette from `AppColors`: tinted neutrals and one accent,
  with semantic colors reserved for actual state.
- Use the app typography scale and keep explanatory copy short. A heading does
  not need a paragraph that restates it.
- Body copy uses regular weight, ordinary emphasis uses medium, component
  titles use semibold, and bold is reserved for page titles or rare values.
- Use 150–250 ms motion only to communicate selection, reveal, navigation, or
  state changes. Avoid decorative animation.

## Conversation and actions

- Assistant messages sit directly on the canvas, within a 680 px reading column.
  Use a 14 px desktop and 16 px mobile base reading size and retain the saved text-size preference.
- User messages have one quiet filled surface. Keep code formatting intact.
- Use separate compact desktop menus for workspace tools and session actions. Use short lists
  for mobile actions. A menu does not need a description under every command.
- An initial transcript error stays visible with a Retry action. Keep saved
  transcripts readable when a refresh fails.
- Machine details show recent sessions before maintenance tools. Expand connection
  and provider information when needed. Keep all sessions available on demand.
- Keep existing light and dark modes, palette choices, and access protections.

## Shared theme contract

- `app_tokens.dart` owns component sizes and shapes. Desktop dialogs use 12 px
  corners, menus 10 px, inputs 12 px, and hover surfaces 6 px. Mobile sheets use
  24 px top corners. A desktop sheet has no mobile drag handle.
- `app_theme.dart` applies those tokens to Material menus, dialogs, switches,
  segmented controls, and buttons in both light and dark modes.
- Use `AppMenuButton`, `AppMenuItem`, and `AppSelect` for menus and value choices.
  Do not add a local dropdown style. Preserve disabled and selected states.
- Desktop model and thinking choices open beside the composer. They must not
  open an inspector or stack a second modal. Mobile choices use one sheet.
- Copy and Pin are direct message actions. Show them on hover or keyboard focus
  on desktop, and keep them visible on touch devices.
- Use neutral hover and selection fills. Keep semantic colors for status,
  warnings, and destructive actions. Keep visible keyboard focus.

- Use `AppInputDecorations.borderless` inside an existing input surface. It
  suppresses every inherited border state; the outer surface owns focus.
- Keep button visual density standard when the theme already supplies a
  platform-specific height. Do not apply a second size reduction.
- Simple desktop forms fit their content. Align labels and value controls in
  one bounded column. Keep actions near the form. On mobile, use scrollable
  pages with reachable actions and keyboard-safe layout.
- Choose the machine inside the new-session draft. Keep task text when changing
  machines, but reload machine-specific folders, defaults, and capabilities.

- Standard cards use the elevated fill without an automatic border. Inputs
  share 12 px corners across normal, focused, disabled, and error states.
  Focus outlines remain visible, and disabled switches and buttons lose their
  active colors. Fixed black media surfaces retain light controls in both modes.
- `app_control_styles.dart` owns search, sheet controls, action menus, and
  semantic action variants. `app_status_styles.dart` owns status and surface
  palettes. `app_code_theme.dart` owns syntax and terminal colors.
- `scripts/check_flutter_theme.py` rejects hardcoded visual styles outside the
  theme directory. The CI job runs it before Flutter tests. Layout constraints,
  data values, and protocol timers remain with their behavior.


## Task flow rules

- Desktop session search opens on demand from the header or Command-F. Keep
  the conversation in place. Support arrow selection, Enter, and Escape.
- Use one conversation header. Keep machine and folder context quiet, and put
  secondary data in details. Keep required approvals and active controls clear.
- Put new-session context choices beside the composer. Folder selection opens
  directly and preserves draft text. Validate the folder before sending.
- Use an overlay for an inspector when another column would make the
  conversation too narrow. Keep Close, Escape, and outside dismissal available.
