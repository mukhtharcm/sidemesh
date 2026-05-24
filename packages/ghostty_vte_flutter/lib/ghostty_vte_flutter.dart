import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:ghostty_vte/ghostty_vte.dart';

/// Flutter widgets and controllers for Ghostty VTE terminal emulation.
///
/// Use [GhosttyTerminalController] to manage a terminal subprocess and
/// [GhosttyTerminalView] to render its output:
///
/// ```dart
/// import 'package:ghostty_vte_flutter/ghostty_vte_flutter.dart';
///
/// final controller = GhosttyTerminalController();
/// await controller.start();
///
/// // In a widget:
/// GhosttyTerminalView(controller: controller);
/// ```

/// [GhosttyTerminalController] for managing VT state and input handling.
export 'src/terminal_controller.dart';

/// Styled terminal snapshot and palette types used by the controller and view.
export 'src/terminal_snapshot.dart';
export 'src/terminal_render_model.dart';

/// Shared mutable selection state for terminal widgets.
export 'src/terminal_selection_session.dart';

/// Shared auto-scroll session state for terminal widgets.
export 'src/terminal_auto_scroll_session.dart';

/// Shared gesture-side selection coordinator for terminal widgets.
export 'src/terminal_gesture_coordinator.dart';

/// Shared controller/buffer contracts for terminal surface integrations.
export 'src/terminal_surface_contract.dart';

/// Shared keyboard/input normalization helpers for terminal widgets.
export 'src/keyboard_input.dart';
export 'src/soft_input_bridge.dart';

/// Shared clipboard/paste/selection interaction helpers for terminal widgets.
export 'src/terminal_interactions.dart';

/// Shared tap and hover resolution helpers for terminal widgets.
export 'src/terminal_pointer_flow.dart';

/// Shared native PTY session types and implementation.
export 'src/pty_session.dart';

/// Shared shell-environment helpers for native terminal launches.
export 'src/shell_environment.dart';

/// Shared shell launch presets for terminal demos and apps.
export 'src/shell_launch.dart';

/// [GhosttyTerminalView] widget for rendering terminal output in Flutter.
export 'src/terminal_view.dart';

/// Platform-resolved ghostty_vte API (`GhosttyVt`, `GhosttyVtWasm`, etc.).
///
/// Re-exported so consumers do not need a separate direct dependency on
/// `ghostty_vte`.
export 'package:ghostty_vte/ghostty_vte.dart';

/// Package-level setup and lightweight terminal widgets for Flutter.
///
/// The wasm runtime can be initialized via [initializeGhosttyVteWeb] on web
/// before constructing web terminal views.

/// Initializes the Ghostty wasm module on web from bundled Flutter assets.
///
/// Call this early in your `main()` before constructing any terminal views
/// on web targets. This is a no-op on native platforms.
///
/// ```dart
/// void main() async {
///   WidgetsFlutterBinding.ensureInitialized();
///   await initializeGhosttyVteWeb();
///   runApp(const MyApp());
/// }
/// ```
Future<void> initializeGhosttyVteWeb({
  String assetPath = 'packages/ghostty_vte_flutter/assets/ghostty-vt.wasm',
}) async {
  if (!kIsWeb || GhosttyVtWasm.isInitialized) {
    return;
  }
  final data = await rootBundle.load(assetPath);
  await GhosttyVtWasm.initializeFromBytes(
    data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
  );
}

/// Backwards-compatible starter widget.
///
/// Prefer [GhosttyTerminalView] + [GhosttyTerminalController] for a full
/// terminal implementation. This widget provides a simple static preview.
///
/// ```dart
/// GhosttyTerminalWidget(sampleInput: 'echo hello')
/// ```
class GhosttyTerminalWidget extends StatelessWidget {
  const GhosttyTerminalWidget({
    required this.sampleInput,
    this.isPasteSafe,
    super.key,
  });

  final String sampleInput;
  final bool Function(String text)? isPasteSafe;

  @override
  Widget build(BuildContext context) {
    final safe = (isPasteSafe ?? GhosttyVt.isPasteSafe)(sampleInput);
    return DecoratedBox(
      decoration: const BoxDecoration(color: Color(0xFF111111)),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Text(
          'ghostty_vte_flutter\n'
          'sample: $sampleInput\n'
          'paste safe: $safe',
          style: const TextStyle(
            color: Color(0xFFE6E6E6),
            fontFamily: 'monospace',
            fontSize: 14,
          ),
        ),
      ),
    );
  }
}
