# P0-04 — Working directory requires manual typing

## Problem

The create-session form requires users to type the full working
directory path by hand (e.g. `/Users/me/dev/myproject`).  This is
error-prone; a single typo silently creates a session in the wrong
directory.

The app already has:
- A full filesystem browse API (`/api/fs/ls`, `/api/fs/stat`)
- A `FileBrowserScreen` / `WorkspaceBrowserDialog`
- A `showFileBrowserScreen` navigator helper

None of these are surfaced in the create-session form.

## Affected files

- `apps/mobile/lib/src/screens/create_session_sheet.dart` —
  `_buildPrimaryPanel()`, `_LaunchFieldFrame`
- `apps/mobile/lib/src/screens/file_browser_screen.dart` —
  `showFileBrowserScreen()`
- `apps/mobile/lib/src/api_client.dart` — `_supportsFilesystem` check
  lives on `NodeInfo`

## Implementation plan

### Step 1 — Add browse icon button to the directory field

Inside `_LaunchFieldFrame` for the working-directory field, add a
trailing `IconButton` (folder icon):

```dart
_LaunchFieldFrame(
  icon: Icons.folder_open_rounded,
  label: 'Working directory',
  trailing: _supportsFilesystem
      ? IconButton(
          tooltip: 'Browse filesystem',
          icon: const Icon(Icons.folder_rounded, size: 18),
          onPressed: _browseDirectory,
        )
      : null,
  child: TextField(...),
),
```

`_LaunchFieldFrame` needs a `trailing` parameter added.

### Step 2 — `_browseDirectory` method

```dart
Future<void> _browseDirectory() async {
  final node = _nodeInfo;
  if (node == null) return;
  final root = _trimmedOrNull(_cwdController.text) ?? '/';
  final selected = await showFileBrowserScreen(
    context,
    host: widget.host,
    api: widget.api,
    initialPath: root,
    selectMode: FileBrowserSelectMode.directory,
  );
  if (selected != null && mounted) {
    _cwdController.text = selected;
    _handleCwdChanged();
  }
}
```

`showFileBrowserScreen` already exists.  It needs a `selectMode`
parameter added (or use the existing dialog variant for desktop).

### Step 3 — Add `selectMode` to `FileBrowserScreen`

`FileBrowserScreen` currently only supports opening files for viewing.
Add a `selectMode` enum:

```dart
enum FileBrowserSelectMode { view, directory, file }
```

When `selectMode == directory`, tapping a directory row shows a
"Select this folder" `FilledButton` in the header, which pops with the
path.

On mobile, show as a full-screen pushed route.
On desktop / dialog context, use the existing `WorkspaceBrowserDialog`.

### Step 4 — Cap filesystem browsing behind capability gate

Only show the browse button when `_supportsFilesystem` is true (already
derived from `NodeInfo.supportsHostCapability('workspace', 'filesystem')`).
When the node info hasn't loaded yet, show the button as disabled with
a loading indicator.

### Step 5 — Recent directories shortcut

Populate `_buildPrimaryPanel` with a horizontal scrolling row of the
user's recently-used directories (from `WorkspaceSummary` already
fetched for the host) as quick-tap chips above the text field.  Tapping
a chip fills in the directory field instantly.

## Acceptance criteria

- A folder icon button appears next to the working directory field when
  the host supports filesystem browsing.
- Tapping it opens the file browser in directory-select mode.
- Selecting a directory closes the browser and fills in the field.
- A row of recent-directory chips gives instant access to known paths.
- When filesystem isn't supported, no button is shown (graceful
  degradation).
