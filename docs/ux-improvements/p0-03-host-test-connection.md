# P0-03 — No "Test connection" in host editor

## Problem

The host editor sheet (`HostEditorSheet` in `home_screen.dart`) lets
users type a base URL and token, then tap "Save host".  There is no
way to verify the credentials are correct before saving.

The next feedback loop is:
1. Save → home screen
2. Host status heartbeat fires (up to 45 s later)
3. Host appears offline → user confused

For manual entry (not QR), typos in the URL or a wrong token are
extremely common and completely silent.

## Affected files

- `apps/mobile/lib/src/screens/home_screen.dart` — `HostEditorSheet`,
  `_HostEditorSheetState`
- `apps/mobile/lib/src/api_client.dart` — `fetchNode()` is the probe

## Implementation plan

### Step 1 — Add a "Test connection" button to the editor

Below the token field, add:

```dart
FilledButton.tonalIcon(
  onPressed: _testing ? null : _testConnection,
  icon: _testing
      ? const SizedBox(width: 14, height: 14,
            child: CircularProgressIndicator(strokeWidth: 1.5))
      : const Icon(Icons.wifi_tethering_rounded),
  label: const Text('Test connection'),
),
```

State: `bool _testing = false;`, `String? _testResult;`,
`bool _testSuccess = false;`

### Step 2 — `_testConnection` method

```dart
Future<void> _testConnection() async {
  final label = _labelController.text.trim().isEmpty
      ? 'test'
      : _labelController.text.trim();
  final baseUrl = normalizeBaseUrl(_baseUrlController.text);
  final token  = _tokenController.text.trim();
  if (baseUrl.isEmpty || token.isEmpty) {
    setState(() => _testResult = 'Enter a URL and token first.');
    return;
  }
  setState(() { _testing = true; _testResult = null; });
  try {
    final probe = HostProfile(
      id: 'probe', label: label, baseUrl: baseUrl, token: token);
    final node = await ApiClient().fetchNode(probe);
    if (!mounted) return;
    setState(() {
      _testing = false;
      _testSuccess = true;
      _testResult = 'Connected — ${node.hostname} · ${node.platform}';
    });
  } catch (e) {
    if (!mounted) return;
    setState(() {
      _testing = false;
      _testSuccess = false;
      _testResult = 'Could not reach host: ${friendlyError(e)}';
    });
  }
}
```

### Step 3 — Show result inline

Display `_testResult` below the button using `MeshPill` tone:
- `MeshPillTone.success` when `_testSuccess == true`
- `MeshPillTone.danger` when `_testSuccess == false`

### Step 4 — Auto-fill label from node hostname

When the test succeeds and the label field is empty or still the
default, auto-populate it with `node.hostname` as a convenience.

### Step 5 — Same treatment in onboarding `_ManualHostSheet`

The onboarding screen has an identical manual entry sheet
(`_ManualHostSheet`).  Apply the same "Test connection" pattern.

## Acceptance criteria

- Typing a valid URL + token and tapping "Test connection" shows
  "Connected — hostname · platform" in green.
- An invalid URL or wrong token shows the error in red immediately.
- Saving is not blocked by the test (user can still save without
  testing).
- The onboarding manual entry sheet has the same button.
