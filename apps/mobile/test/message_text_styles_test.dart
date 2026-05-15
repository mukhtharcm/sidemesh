import 'package:flutter_test/flutter_test.dart';
import 'package:sidemesh_mobile/src/message_text_styles.dart';
import 'package:sidemesh_mobile/src/theme/app_palettes.dart';

void main() {
  test('message bubble text and links meet AA contrast', () {
    for (final variant in ThemeVariant.values) {
      for (final colors in [variant.dark, variant.light]) {
        expect(
          contrastRatio(messageBodyColor(colors, userBubble: true), colors.userBubble),
          greaterThanOrEqualTo(minimumReadableTextContrast),
          reason: '${variant.id} user bubble body contrast is too low',
        );
        expect(
          contrastRatio(
            messageBodyColor(colors, userBubble: false),
            colors.assistantBubble,
          ),
          greaterThanOrEqualTo(minimumReadableTextContrast),
          reason: '${variant.id} assistant bubble body contrast is too low',
        );

        expect(
          contrastRatio(
            messageLinkColor(colors, userBubble: true),
            colors.userBubble,
          ),
          greaterThanOrEqualTo(minimumReadableTextContrast),
          reason: '${variant.id} user bubble link contrast is too low',
        );
        expect(
          contrastRatio(
            messageMetaColor(colors, userBubble: true),
            colors.userBubble,
          ),
          greaterThanOrEqualTo(minimumReadableTextContrast),
          reason: '${variant.id} user metadata contrast is too low',
        );
        expect(
          contrastRatio(
            messageLinkColor(colors, userBubble: false),
            colors.assistantBubble,
          ),
          greaterThanOrEqualTo(minimumReadableTextContrast),
          reason: '${variant.id} assistant bubble link contrast is too low',
        );
        expect(
          contrastRatio(
            messageMetaColor(colors, userBubble: false),
            colors.assistantBubble,
          ),
          greaterThanOrEqualTo(minimumReadableTextContrast),
          reason: '${variant.id} assistant metadata contrast is too low',
        );
      }
    }
  });
}
