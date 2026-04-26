import 'package:flutter/widgets.dart';

class ComposerPasteTextAction extends Action<PasteTextIntent> {
  ComposerPasteTextAction({required this.onPasteImage});

  final Future<bool> Function() onPasteImage;

  @override
  bool get isActionEnabled => callingAction?.isActionEnabled ?? true;

  @override
  bool consumesKey(PasteTextIntent intent) =>
      callingAction?.consumesKey(intent) ?? true;

  @override
  Future<Object?> invoke(PasteTextIntent intent) async {
    final fallbackAction = callingAction;
    final pastedImage = await onPasteImage();
    if (pastedImage) {
      return null;
    }
    final fallback = fallbackAction?.invoke(intent);
    if (fallback is Future<Object?>) {
      return await fallback;
    }
    return fallback;
  }
}
