# P3-16 — No success state after QR pairing

## Problem

After scanning a pairing QR code (in onboarding or in the host editor),
the app silently transitions to the home screen or closes the sheet.
The user sees no:
- Confirmation of which host was added
- Success animation or haptic
- Host name / URL of what was just connected

This is the highest-emotion moment in the onboarding flow — the user
just connected their phone to their dev machine.  Leaving it silent
wastes a "moment of delight."

## Affected files

- `apps/mobile/lib/src/screens/onboarding_screen.dart` —
  `_onPairingResult()`
- `apps/mobile/lib/src/screens/home_screen.dart` — `_HostEditorSheetState`,
  `_scanPairingQr()`

## Implementation plan

### Step 1 — Show a brief success sheet after QR scan in onboarding

After `_onPairingResult` saves the host but before calling `_complete()`,
show a success overlay on the current page:

```dart
Future<void> _onPairingResult(PairingPayload payload) async {
  // Save host...
  HapticFeedback.heavyImpact();
  if (!mounted) return;
  await _showPairingSuccess(payload);   // ← new
  await _complete();
}

Future<void> _showPairingSuccess(PairingPayload payload) async {
  // Animate the connect page: replace the content with a success state
  // for ~1.5 seconds before auto-advancing.
  setState(() => _pairingSuccess = payload);
  await Future.delayed(const Duration(milliseconds: 1500));
}
```

The success state shows:
```
[✓ large green icon]
Connected!
[payload.label]
[payload.baseUrl]
```

### Step 2 — Success state widget

```dart
if (_pairingSuccess != null)
  _PairingSuccessView(payload: _pairingSuccess!)
else
  _ConnectPage(...)
```

```dart
class _PairingSuccessView extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Container(
          width: 80, height: 80,
          decoration: BoxDecoration(
            color: colors.successMuted,
            shape: BoxShape.circle,
          ),
          child: Icon(Icons.check_rounded, size: 40, color: colors.success),
        ),
        const SizedBox(height: 24),
        Text('Connected!', style: headlineSmall + w800),
        const SizedBox(height: 8),
        Text(payload.label, style: titleMedium),
        Text(payload.baseUrl, style: monoStyle + textSecondary),
      ],
    );
  }
}
```

### Step 3 — Success snackbar in the host editor (non-onboarding)

In `_HostEditorSheetState._scanPairingQr`, after filling in the fields:

```dart
setState(() {
  _labelController.text = payload.label;
  _baseUrlController.text = payload.baseUrl;
  _tokenController.text = payload.token;
});
HapticFeedback.mediumImpact();
showAppSnackBar(context, 'QR scanned — ${payload.label}');
```

The fields visually show the scanned values, so the user can see exactly
what was imported before they tap "Save."

## Acceptance criteria

- QR scan during onboarding: shows a 1.5 s success screen with the host
  name and URL before advancing.
- QR scan in host editor: haptic + snackbar + fields filled.
- Both paths include `HapticFeedback.heavyImpact()` (onboarding) or
  `mediumImpact()` (host editor).
- Auto-advance after the success state — user doesn't need to tap again.
