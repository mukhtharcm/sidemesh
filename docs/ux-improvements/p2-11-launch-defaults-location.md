# P2-11 — Launch defaults are in the wrong place

## Problem

"New session defaults" (default model, approval policy, sandbox, etc.)
lives in Settings.  When a user is frustrated that every session opens
with the wrong model, their impulse is to look at the create-session
form — not the Settings app.

The create-session form shows current defaults but offers no "Make this
my default" shortcut.  The path from intent to action is:

  ⚙️ → Settings → scroll past Appearance → scroll past Notifications → 
  Launch defaults → edit

That's 3 navigation steps and significant scroll distance.

## Affected files

- `apps/mobile/lib/src/screens/create_session_sheet.dart` — footer,
  advanced panel
- `apps/mobile/lib/src/screens/settings_screen.dart` — launch defaults
  section
- `apps/mobile/lib/src/create_session_defaults_store.dart`

## Implementation plan

### Step 1 — Add "Save as defaults" button in the create-session advanced panel

In `_buildAdvancedPanel`, below the options form, add a small
`TextButton`:

```dart
Align(
  alignment: Alignment.centerRight,
  child: TextButton.icon(
    onPressed: _saveAsDefaults,
    icon: const Icon(Icons.bookmark_add_rounded, size: 16),
    label: const Text('Save as my defaults'),
  ),
),
```

### Step 2 — `_saveAsDefaults` method

```dart
Future<void> _saveAsDefaults() async {
  await CreateSessionDefaultsStore.instance.save(
    CreateSessionDefaults(
      model: _selectedModel?.model,
      mode: _modeToSubmit,
      reasoningEffort: _reasoningToSubmit,
      approval: _approvalPolicyToSubmit,
      sandbox: _sandboxModeToSubmit,
      webSearch: _webSearchToSubmit,
    ),
  );
  if (!mounted) return;
  showAppSnackBar(context, 'Saved as your defaults for new sessions.');
}
```

### Step 3 — Show a "defaults changed" indicator

When the current form values differ from the saved defaults, show a
small pill in the footer: "Custom settings · Save as defaults ↑".  This
alerts the user that they're not using their usual configuration and
gives them a one-tap path to persist it.

### Step 4 — Keep launch defaults in Settings

Settings is the right place for initial setup and for users who want to
change defaults without starting a new session.  Keep it — just add the
in-form shortcut as well.

### Step 5 — Deep-link from Settings to the create-session form

In the Settings launch-defaults section, add a note:
"You can also tap 'Save as defaults' inside any new session form."

## Acceptance criteria

- The advanced panel in create-session has a "Save as defaults" button.
- Tapping it persists the current form options as defaults.
- A snackbar confirms.
- If the form already matches defaults, the button is greyed out
  ("Already your defaults").
- Settings launch defaults section is unchanged.
