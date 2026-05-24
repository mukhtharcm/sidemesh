import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher_string.dart';

import 'terminal_snapshot.dart';

/// Copies terminal text using a host callback when provided.
Future<void> ghosttyTerminalCopyText(
  String text, {
  Future<void> Function(String text)? onCopySelection,
}) async {
  final callback = onCopySelection;
  if (callback != null) {
    await callback(text);
    return;
  }
  await Clipboard.setData(ClipboardData(text: text));
}

/// Reads paste text using a host callback when provided.
Future<String?> ghosttyTerminalReadPasteText({
  Future<String?> Function()? onPasteRequest,
}) async {
  final callback = onPasteRequest;
  if (callback != null) {
    return callback();
  }
  return (await Clipboard.getData(Clipboard.kTextPlain))?.text;
}

/// Normalizes terminal hyperlink text to null when it is absent or empty.
String? ghosttyTerminalNormalizedHyperlink(String? uri) {
  if (uri == null || uri.isEmpty) {
    return null;
  }
  return uri;
}

/// Resolves terminal hyperlink text for an optional position.
String? ghosttyTerminalResolveHyperlinkAt<PositionT>(
  PositionT? position, {
  required String? Function(PositionT position) resolveUri,
}) {
  if (position == null) {
    return null;
  }
  return ghosttyTerminalNormalizedHyperlink(resolveUri(position));
}

/// Opens a terminal hyperlink using a host callback when provided.
Future<void> ghosttyTerminalOpenHyperlink(
  String uri, {
  Future<void> Function(String uri)? onOpenHyperlink,
}) async {
  final callback = onOpenHyperlink;
  if (callback != null) {
    await callback(uri);
    return;
  }
  await launchUrlString(uri);
}

/// Builds shared selection callback payloads from terminal text extraction.
GhosttyTerminalSelectionContent<SelectionT>?
ghosttyTerminalSelectionContentFor<SelectionT>(
  SelectionT? selection, {
  required String Function(SelectionT selection) resolveText,
}) {
  if (selection == null) {
    return null;
  }
  return GhosttyTerminalSelectionContent<SelectionT>(
    selection: selection,
    text: resolveText(selection),
  );
}

/// Emits shared terminal selection-content callbacks using a text resolver.
void ghosttyTerminalNotifySelectionContent<SelectionT>({
  required SelectionT? selection,
  required String Function(SelectionT selection) resolveText,
  required void Function(GhosttyTerminalSelectionContent<SelectionT>? content)?
  onSelectionContentChanged,
}) {
  onSelectionContentChanged?.call(
    ghosttyTerminalSelectionContentFor<SelectionT>(
      selection,
      resolveText: resolveText,
    ),
  );
}

/// Emits shared terminal selection callbacks and derived content payloads.
void ghosttyTerminalNotifySelectionChange<SelectionT>({
  required SelectionT? previousSelection,
  required SelectionT? nextSelection,
  required String Function(SelectionT selection) resolveText,
  required void Function(SelectionT? selection)? onSelectionChanged,
  required void Function(GhosttyTerminalSelectionContent<SelectionT>? content)?
  onSelectionContentChanged,
}) {
  if (previousSelection == nextSelection) {
    return;
  }
  onSelectionChanged?.call(nextSelection);
  ghosttyTerminalNotifySelectionContent<SelectionT>(
    selection: nextSelection,
    resolveText: resolveText,
    onSelectionContentChanged: onSelectionContentChanged,
  );
}
