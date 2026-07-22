# Sidemesh Design System

## Product scene

A developer checks agent work from a phone between other tasks, often with one
hand and limited attention. The interface should make state and the next action
obvious without turning technical metadata into visual noise.

## Direction

Sidemesh is a calm workbench for agent sessions: compact, direct, status-aware,
and trustworthy. It should feel native to the device, not like a desktop admin
panel squeezed into a phone.

## Visual grammar

- Canvas is the default grouping surface. Do not put every row in a card.
- Use a surface when content needs an edge, such as an input, sheet, dialog, or
  independently actionable warning.
- Group related list rows with spacing and dividers. Avoid nested surfaces.
- Accent color is reserved for primary actions, selection, focus, and unread
  state. Success, warning, and danger colors only communicate real state.
- Metadata is quiet text with icons. Badges are reserved for states that change
  what the user should do.

## Type

- Use the platform interface font for all product UI.
- Use 700 for titles and primary actions, 600 for emphasis, and 500 for body.
- Keep letter spacing at zero. Hierarchy comes from size, weight, and color.
- Use monospace only for code, paths, commands, identifiers, and aligned data.

## Shape and spacing

- 8 px: badges and compact selections.
- 10 px: controls and icon buttons.
- 14 px: independent surfaces.
- 18 px: sheets and dialogs.
- Use the 4, 8, 12, 16, 24, 32 spacing scale. Favor 12 to 16 px screen edges
  and 10 to 12 px vertical padding for operational rows.

## Motion

- Use 160 ms for local state changes and 220 ms for reveals or navigation.
- Use ease-out cubic for enter and state-change motion.
- Do not animate decoration. Motion should explain selection, progress, or
  spatial continuity.

## Core patterns

- Home: compact toolbar, search and filters, grouped session rows, stable bottom
  navigation.
- New session: conversation canvas first, inherited context in one quiet row,
  settings on a separate screen, composer fixed above the keyboard.
- Session: transcript owns the page. Status and runtime metadata live in the
  header or context shelf, never as a wall of chips around the composer.
- Approvals: explain the requested action and consequence, then present the
  safest common response as the primary action.

## Accessibility

- Interactive targets are at least 44 by 44 logical pixels.
- Do not encode state with color alone.
- Preserve platform text scaling and keyboard-safe layouts.
- Keep secondary text readable against every supported palette.
