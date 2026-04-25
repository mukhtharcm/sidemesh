# Image Viewer + Zoom Implementation Study

## Scope

Study how to replace the current fullscreen image viewer with something that:

- supports a better zoom interaction,
- feels visually consistent with the rest of the Sidemesh app,
- works for both message attachments and generated local images,
- fits the app's existing mobile vs wide-screen presentation patterns.

## Current Implementation

### Where image viewing lives today

- Message attachments are laid out in `_MessageAttachmentsSection` in `apps/mobile/lib/src/screens/session_screen.dart:5262`.
- Remote/data-url images are rendered by `_MessageImageAttachmentTile` in `apps/mobile/lib/src/screens/session_screen.dart:5325`.
- Authenticated workspace images are rendered by `_LocalImageAttachmentTile` in `apps/mobile/lib/src/screens/session_screen.dart:5420`.
- Both tiles push `_FullscreenImageViewer` from the same file in `apps/mobile/lib/src/screens/session_screen.dart:5543`.
- Generated images reuse `_LocalImageAttachmentTile`, so image-generation cards already depend on the same viewer path.

### What the current viewer does well

- It is simple and low-risk.
- It already supports pinch zoom through `InteractiveViewer`.
- It reuses the existing hero tag from the thumbnail into the fullscreen image.
- It works for both `MemoryImage` and authenticated `NetworkImage`.

### Current gaps

1. The fullscreen viewer is visually detached from the app.
   It uses a black `Scaffold` and black `AppBar`, while most of the app uses themed surfaces, bordered headers, pills, and restrained chrome.

2. The viewer is not reusable.
   It is a private widget embedded inside `session_screen.dart`, even though the same behavior is needed from multiple entry points.

3. Zoom UX is only the Flutter default.
   There is no double-tap zoom, no reset affordance, no explicit zoom controls, and no notion of "fit to screen" after interaction.

4. Presentation is not responsive in the same way as the rest of the app.
   The app already uses full-screen screens on mobile and bordered dialogs on wider layouts for file/workspace viewers, but image viewing always pushes a route.

5. Metadata and context are missing.
   The viewer loses the attachment source context. For local images, we already have a path. For generated images, we can label them more clearly than a blank app bar.

6. Image handling is duplicated.
   Remote/data-url and local image tiles build nearly identical cards and only diverge at provider creation time.

### Adjacent app patterns worth matching

- `FileViewerScreen` uses a themed `AppBar`, file metadata, and action icons: `apps/mobile/lib/src/screens/file_viewer_screen.dart:14`.
- `showWorkspaceBrowserDialog` uses a bordered desktop dialog with a compact custom header: `apps/mobile/lib/src/screens/workspace_browser_dialog.dart:15`.
- `FileViewerPane` treats non-text files as a specific content type boundary today, which leaves room for future image-viewer integration instead of a binary placeholder: `apps/mobile/lib/src/screens/file_viewer_pane.dart:255`.

## Recommended Direction

Build a reusable image viewer feature around a small source model plus a presentation helper:

- `ImageViewerSource`
  Carries `imageProvider`, `heroTag`, `title`, `subtitle`, and optional `path`.
- `showImageViewer(...)`
  Chooses presentation:
  - narrow/mobile: push a themed `ImageViewerScreen`,
  - wide/desktop: open a themed dialog aligned with the workspace/file viewer patterns.
- `ImageViewerScaffold` or `ImageViewerPanel`
  Shared content shell used by both the route and dialog variants.

This keeps the zoom logic in one place and lets every image entry point use the same behavior.

## UX Recommendation

### Thumbnail behavior

Keep the existing card styling direction, but consolidate it into one thumbnail widget so both local and remote images use the same shell:

- bordered muted surface,
- clipped image preview,
- hero transition,
- same tap target behavior,
- fallback state for load failure.

The current fixed `1.35` aspect ratio is acceptable for a first pass, but it is not ideal for portrait images. I would keep it for the initial viewer refactor and revisit thumbnail aspect-ratio preservation later.

### Full viewer behavior

Use app-themed chrome rather than a pure black fullscreen sheet:

- `Scaffold` background from `context.colors.canvas`,
- header surface from `context.colors.surface`,
- bottom border matching file viewers,
- title row with filename or source label,
- subtitle row with path / host / "message attachment",
- small action row for zoom reset and close.

The image itself can still sit on a darker recessed stage inside the body so it feels focused, but that stage should be part of the app theme rather than a separate visual system.

### Recommended zoom interactions

1. Pinch to zoom and pan via `InteractiveViewer`.
2. Double tap to zoom in to a preset scale, then double tap again to reset.
3. Explicit reset control in the header or floating action row.
4. Optional `+` / `-` controls only if the built-in gesture model feels too hidden in testing.

I would not start with swipe-to-dismiss. It tends to conflict with zoom/pan gestures and adds more gesture arbitration than the current app needs.

## Technical Approach

### 1. Extract a reusable viewer module

Create a new file, likely:

- `apps/mobile/lib/src/screens/image_viewer_screen.dart`

This file should own:

- `ImageViewerSource`
- `showImageViewer`
- `ImageViewerScreen`
- desktop dialog wrapper
- shared zoomable body widget

This is the main cleanup step. The current image viewer should not stay inside `session_screen.dart`.

### 2. Unify image source creation at the call site

Refactor the attachment tiles so they create an `ImageViewerSource` and call `showImageViewer(...)`.

For remote/data-url images:

- title: `"Image attachment"`
- subtitle: `"Session message"` or empty if that feels noisy
- provider: `MemoryImage` for decoded data URLs, otherwise `NetworkImage`

For local workspace images:

- title: `baseName(path)`
- subtitle: full path
- provider: authenticated `NetworkImage`

For generated images:

- same local-image source object,
- optionally add a label like `"Generated image"` in the subtitle or a pill in the header.

### 3. Add controlled zoom state

Use:

- `TransformationController`
- `InteractiveViewer`
- `GestureDetector` for double tap
- optional `AnimationController` or `Matrix4Tween` for animated reset

Implementation notes:

- Keep scale state inside the viewer widget, not in each attachment tile.
- Use a `TransformationController` so reset and double-tap zoom do not fight the gesture system.
- Prefer a small number of predictable zoom levels, for example `1.0 -> 2.5 -> 1.0`.

### 4. Match existing responsive presentation rules

The rest of the app already distinguishes mobile and wide-window experiences:

- file viewers use full-screen routes on mobile,
- workspace browsing uses bordered dialogs on wide screens.

The image viewer should follow the same split:

- mobile: push route,
- wide screen: `showDialog` with a constrained, bordered panel and a custom header.

This will feel much more native to the current desktop shell than a route that abruptly takes over the whole screen.

### 5. Keep hero transitions, but narrow their responsibility

The hero should animate the displayed image, but the transform state should belong only to the destination viewer.

That means:

- hero wraps the image content,
- zoom controller lives outside the source thumbnail,
- the destination resets to `fit` on open.

This keeps the transition clean and avoids carrying stale transform state between opens.

## Built-in Widgets vs Third-Party Package

### Recommended first pass: stay with Flutter built-ins

Use `InteractiveViewer` plus `TransformationController`.

Why:

- no new dependency,
- lower integration risk,
- enough for pinch, pan, double tap, and reset,
- aligns with the app's current preference for direct Flutter implementations.

### When to revisit a package

Only introduce a dedicated image-viewing package if we later need:

- gallery-style paging,
- more advanced inertial zoom behavior,
- richer hero transition control across image collections,
- platform-specific gesture polish that becomes hard to maintain manually.

For the feature described here, built-ins are sufficient.

## Optional Follow-on Integration

These are not required for the first implementation, but they are natural extensions:

1. Composer attachment previews
   `_ComposerAttachmentChip` already renders image thumbnails. Tapping them could open the same viewer before send.

2. Workspace file viewer
   `FileViewerPane` currently treats all binary files as a generic binary placeholder. Image MIME types could eventually route into the same image viewer shell instead.

3. Image metadata
   If the server later exposes dimensions or MIME data for attachments, the image viewer header can surface them without another UI redesign.

## Risks and Constraints

1. Thumbnail aspect ratio is still synthetic.
   Keeping the current `1.35` aspect ratio avoids extra async image probing, but portrait images will still crop aggressively in the list view.

2. Data-url images are already decoded eagerly.
   The current remote-image tile decodes inline data URLs into memory before viewing. The new viewer should reuse that behavior instead of decoding again.

3. Desktop presentation needs careful navigator usage.
   Dialog presentation should use the same overlay level as the rest of the shell so the viewer appears above the session pane cleanly.

4. Gesture conflicts are easy to add accidentally.
   Swipe-to-dismiss, background taps, and pan gestures should not all be added at once.

## Suggested Implementation Plan

1. Extract a dedicated image viewer file and source model.
2. Replace `_FullscreenImageViewer` calls with `showImageViewer(...)`.
3. Add `TransformationController`-backed double-tap zoom and reset.
4. Implement desktop dialog presentation for wide layouts.
5. Polish header metadata and load/error states.
6. Optionally reuse the same viewer from composer previews.

## Testing Plan

Current automated coverage in `apps/mobile/test` does not touch the session image viewer path, so this feature will need new widget tests if we want confidence beyond manual QA.

Recommended tests:

- viewer opens from a message attachment tap,
- local image source uses the filename/path header,
- double tap toggles between fitted and zoomed states,
- reset action returns the transform to identity,
- wide-layout presentation chooses dialog mode,
- error state renders the broken-image fallback cleanly.

Manual QA should cover:

- phone-sized layout,
- wide desktop shell layout,
- inline data-url image,
- authenticated local image,
- image-generation output card,
- portrait and landscape images,
- dark and light themes.

## Conclusion

The cleanest implementation is not a bigger `_FullscreenImageViewer`; it is a small reusable image-viewer feature that follows the same structural rules as the app's existing file viewers.

That gives us:

- a consistent visual language,
- one place to improve zoom behavior,
- responsive mobile/desktop presentation,
- a path to reuse the same viewer in composer previews and workspace image files later.
