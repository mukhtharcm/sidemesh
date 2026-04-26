# Desktop Image Viewer Keyboard Study

## Scope

Study how to make the image viewer feel desktop-aware, especially for:

- arrow-key navigation across image galleries,
- keyboard zoom/reset controls,
- closing from the keyboard,
- consistent behavior in both full-screen route and desktop dialog presentations.

This study assumes the current reusable image viewer introduced in `apps/mobile/lib/src/screens/image_viewer_screen.dart`.

## Current State

The image viewer is already structurally close to what desktop support needs:

- `showImageGalleryViewer(...)` chooses route vs dialog at `apps/mobile/lib/src/screens/image_viewer_screen.dart:67`.
- Full-screen route viewing uses `ImageViewerScreen` with a `PageView.builder` at `apps/mobile/lib/src/screens/image_viewer_screen.dart:172`.
- Desktop viewing uses `_ImageViewerDialog` with a second `PageView.builder` at `apps/mobile/lib/src/screens/image_viewer_screen.dart:747`.
- Zoom actions already exist as methods on `ImageViewerPaneState`: `zoomIn`, `zoomOut`, and `reset`.
- Inspector resources already open a multi-image gallery by passing all media resources into `showImageGalleryViewer(...)` at `apps/mobile/lib/src/screens/inspector/inspector_resources.dart:173`.
- Message attachments currently open a single-image viewer through `showImageViewer(...)` at `apps/mobile/lib/src/screens/session_screen_timeline.dart:614` and `apps/mobile/lib/src/screens/session_screen_timeline.dart:717`.

The main gap is that the viewer has pointer and touch affordances, but no viewer-owned keyboard handling. The desktop shell has app-level shortcuts, but they are outside the modal viewer and should not own image-specific behavior.

## Desired Desktop Behavior

Recommended first-pass shortcut map:

| Shortcut | Behavior |
| --- | --- |
| `ArrowRight` / `ArrowDown` | Next image when a gallery has more than one item |
| `ArrowLeft` / `ArrowUp` | Previous image when a gallery has more than one item |
| `+` / `=` | Zoom in current image |
| `-` | Zoom out current image |
| `0` | Reset zoom |
| `Escape` | Close viewer or dialog |
| `Space` | Toggle immersive chrome in the full-screen route only |

Desktop users will expect left/right arrows first. Up/down are useful because some image galleries and keyboards train users to move vertically through media as well, and they cost little if implemented through the same intents.

I would not add `Cmd+Left` / `Cmd+Right` initially. Those are common OS/browser navigation shortcuts and can feel too global for an image modal.

## Ownership Recommendation

Put keyboard support inside `image_viewer_screen.dart`, not in `desktop_shell.dart`.

Reasons:

- The same viewer can appear as a route on tablets or as a dialog on desktop.
- `showDialog` introduces its own focus scope, so shell-level shortcuts may be shadowed or may accidentally act behind the dialog.
- Viewer shortcuts need access to the active `PageController` and active `ImageViewerPaneState`.
- Tests can instantiate the viewer directly without constructing the desktop shell.

The cleanest shape is a small shared internal shell, for example `_ImageGalleryKeyboardScope`, used by both `ImageViewerScreen` and `_ImageViewerDialog`.

## Implementation Shape

### 1. Add shared paging helpers

Both `_ImageViewerScreenState` and `_ImageViewerDialogState` currently duplicate:

- `_pageController`,
- `_paneKeys`,
- `_observables`,
- `_index`,
- `PageView.builder`.

For a low-risk first pass, keep that duplication and add identical small helpers in both states:

- `_canGoPrevious`
- `_canGoNext`
- `_goPrevious()`
- `_goNext()`
- `_currentPaneState`

If the implementation starts growing, extract a shared stateful `ImageGalleryViewport` later. Do not start with a large refactor just for shortcuts.

### 2. Wrap each viewer shell with Shortcuts and Actions

Use Flutter's `Shortcuts` / `Actions` system rather than raw key events.

Recommended structure:

```dart
Shortcuts(
  shortcuts: const <ShortcutActivator, Intent>{
    SingleActivator(LogicalKeyboardKey.arrowLeft): _PreviousImageIntent(),
    SingleActivator(LogicalKeyboardKey.arrowUp): _PreviousImageIntent(),
    SingleActivator(LogicalKeyboardKey.arrowRight): _NextImageIntent(),
    SingleActivator(LogicalKeyboardKey.arrowDown): _NextImageIntent(),
    SingleActivator(LogicalKeyboardKey.equal): _ZoomInImageIntent(),
    SingleActivator(LogicalKeyboardKey.add): _ZoomInImageIntent(),
    SingleActivator(LogicalKeyboardKey.minus): _ZoomOutImageIntent(),
    SingleActivator(LogicalKeyboardKey.digit0): _ResetImageZoomIntent(),
    SingleActivator(LogicalKeyboardKey.escape): _CloseImageViewerIntent(),
  },
  child: Actions(
    actions: <Type, Action<Intent>>{
      _PreviousImageIntent: CallbackAction<_PreviousImageIntent>(
        onInvoke: (_) => _goPrevious(),
      ),
      _NextImageIntent: CallbackAction<_NextImageIntent>(
        onInvoke: (_) => _goNext(),
      ),
      _ZoomInImageIntent: CallbackAction<_ZoomInImageIntent>(
        onInvoke: (_) => _currentPaneState?.zoomIn(),
      ),
      _ZoomOutImageIntent: CallbackAction<_ZoomOutImageIntent>(
        onInvoke: (_) => _currentPaneState?.zoomOut(),
      ),
      _ResetImageZoomIntent: CallbackAction<_ResetImageZoomIntent>(
        onInvoke: (_) => _currentPaneState?.reset(),
      ),
      _CloseImageViewerIntent: CallbackAction<_CloseImageViewerIntent>(
        onInvoke: (_) => Navigator.of(context).maybePop(),
      ),
    },
    child: Focus(autofocus: true, child: viewerBody),
  ),
)
```

Use `LogicalKeyboardKey.equal` for the common unshifted `+` key location on many keyboards, and include `LogicalKeyboardKey.add` for numpad plus. If the Flutter SDK in this repo does not expose `add`, use only `equal` in the first patch.

### 3. Page with animation, not direct index mutation

Use the existing `PageController`:

```dart
void _goNext() {
  if (_index >= widget.sources.length - 1) return;
  _pageController.nextPage(
    duration: const Duration(milliseconds: 180),
    curve: Curves.easeOutCubic,
  );
}
```

`onPageChanged` should remain the single place that updates `_index`. That keeps keyboard paging, swipe paging, and any future thumbnail paging consistent.

### 4. Do not let disabled actions throw

Callback actions should return `null` after doing nothing when:

- there is only one image,
- the viewer is already at the first or last image,
- the current pane state is not attached yet,
- zoom controls are not currently available.

The UI already disables zoom buttons through `canZoomIn`, `canZoomOut`, and `canReset`; keyboard actions should mirror that behavior by checking the state before invoking.

### 5. Full-screen route can support chrome toggle

`ImageViewerScreen` has `_toggleChrome()` and immersive chrome state. `_ImageViewerDialog` does not need this because its header is persistent desktop chrome.

Add `Space` only in `ImageViewerScreen`, or make it optional in a shared keyboard scope:

- route: `Space` toggles chrome,
- dialog: no-op.

Avoid using `Enter` for chrome toggling because focused toolbar buttons may already use it.

## Focus Details

Use `Focus(autofocus: true)` or `FocusScope(autofocus: true)` inside both route and dialog bodies. This is important because:

- dialogs often start with focus on the first button,
- `PageView` and `InteractiveViewer` do not guarantee keyboard focus,
- tests can reliably send keyboard events after `pumpAndSettle`.

If toolbar buttons keep stealing focus after mouse clicks, the viewer shortcuts should still work because `Shortcuts` / `Actions` can wrap the entire dialog content. Avoid a raw `KeyboardListener` unless `Shortcuts` fails in practice, because raw events are easier to duplicate and harder to compose with text inputs.

## Gesture Conflict Risk

Keyboard arrows should page the gallery even if the current image is zoomed. This is simpler and predictable, but it means arrow keys do not pan zoomed images.

That is acceptable for a first pass because:

- panning is already available via mouse/trackpad drag,
- arrow-key panning would conflict with gallery navigation,
- the viewer has explicit zoom reset.

If later testing shows desktop users strongly expect arrow-key panning while zoomed, use this rule:

- when scale is `> 1.01`, arrows pan the current image,
- when scale is fit/identity, arrows navigate images.

Do not start there unless needed; it adds state and translation-boundary logic to `ImageViewerPaneState`.

## Visual Affordances

Do not add visible instructional text to the viewer. The desktop-aware behavior should be discoverable through tooltips and familiar shortcuts.

Small refinements that would help:

- Add previous/next icon buttons in the desktop dialog header only when `sources.length > 1`.
- Disable them at the first/last image.
- Keep the existing `1 / N` pill.
- Leave the full-screen route visually clean; arrows are enough there for now.

This gives mouse users the same capability as keyboard users without turning mobile chrome into a desktop toolbar.

## Testing Plan

Add widget tests in `apps/mobile/test/image_viewer_screen_test.dart`.

Recommended tests:

1. `ArrowRight` moves from image 1 to image 2 in `ImageViewerScreen`.
2. `ArrowLeft` moves back to image 1.
3. `ArrowRight` at the last image does not throw and leaves the count unchanged.
4. `Escape` closes the wide-layout dialog opened through `showImageViewer(...)` or `showImageGalleryViewer(...)`.
5. `=` zooms in and `0` resets the current image.
6. Route-only `Space` toggles chrome visibility if implemented.

Use multiple test sources with distinct `title` values and assert the visible header/caption text changes after keyboard navigation. For zoom, the existing `100%` / `200%` label assertions can be reused.

Manual QA:

- macOS desktop build: dialog opens from inspector media resources and responds to arrows.
- Flutter web/desktop shell if applicable: shortcuts do not trigger shell navigation behind the dialog.
- Single-image message attachment: arrows no-op, zoom shortcuts still work.
- Multi-image resource gallery: paging updates title/subtitle/count and preserves independent zoom state per image.
- After clicking a zoom button, arrows still navigate.

## Recommended Implementation Order

1. Add private `Intent` classes in `image_viewer_screen.dart`.
2. Add helper methods for previous/next/current pane state to both route and dialog states.
3. Wrap `ImageViewerScreen` body in `Shortcuts` / `Actions` / `Focus`.
4. Wrap `_ImageViewerDialog` content in the same keyboard scope.
5. Add desktop previous/next header buttons to the dialog if the first keyboard patch feels too invisible.
6. Add widget tests for route paging, dialog close, and zoom shortcuts.

## Conclusion

The viewer does not need a desktop-specific fork. It needs a viewer-owned keyboard intent layer around the existing route and dialog shells.

The first implementation should use Flutter `Shortcuts` / `Actions`, animate the existing `PageController`, call the existing zoom methods on the active pane, and keep `Escape` local to the viewer. That makes image galleries feel native on desktop while preserving the current mobile gesture behavior.
