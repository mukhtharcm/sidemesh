import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../pairing.dart';
import '../theme/app_colors.dart';
import '../widgets/app_sheets.dart';

bool get canScanPairingQr {
  if (kIsWeb) return false;
  return defaultTargetPlatform == TargetPlatform.iOS ||
      defaultTargetPlatform == TargetPlatform.android;
}

Future<PairingPayload?> showPairScannerSheet(BuildContext context) {
  return showModalBottomSheet<PairingPayload>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => const PairScannerSheet(),
  );
}

class PairScannerSheet extends StatefulWidget {
  const PairScannerSheet({super.key});

  @override
  State<PairScannerSheet> createState() => _PairScannerSheetState();
}

class _PairScannerSheetState extends State<PairScannerSheet> {
  late final MobileScannerController _controller;
  bool _handled = false;
  String? _message;

  @override
  void initState() {
    super.initState();
    _controller = MobileScannerController(
      detectionSpeed: DetectionSpeed.noDuplicates,
      formats: const [BarcodeFormat.qrCode],
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _handleDetect(BarcodeCapture capture) {
    if (_handled) return;
    for (final barcode in capture.barcodes) {
      final raw = barcode.rawValue;
      if (raw == null || raw.trim().isEmpty) continue;
      final payload = PairingPayload.tryParse(raw);
      if (payload != null) {
        _handled = true;
        Navigator.of(context).pop(payload);
        return;
      }
    }
    if (mounted) {
      setState(() {
        _message = 'This code does not work for Sidemesh pairing.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return MeshBottomSheetScaffold(
      icon: Icons.qr_code_scanner_rounded,
      title: 'Scan a pairing code',
      description:
          'On the machine you want to connect, run sidemesh pair, then scan the code here.',
      maxWidth: 640,
      maxHeightFactor: 0.88,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(18),
                  child: AspectRatio(
                    aspectRatio: 1,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        MobileScanner(
                          controller: _controller,
                          fit: BoxFit.cover,
                          onDetect: _handleDetect,
                          errorBuilder: (context, error) =>
                              _ScannerError(error: error),
                        ),
                        IgnorePointer(
                          child: CustomPaint(
                            painter: _ScanFramePainter(colors),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
          if (_message != null) ...[
            const SizedBox(height: 12),
            Text(
              _message!,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: colors.warning,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _ScannerError extends StatelessWidget {
  const _ScannerError({required this.error});

  final MobileScannerException error;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Container(
      color: colors.surfaceElevated,
      padding: const EdgeInsets.all(18),
      alignment: Alignment.center,
      child: Text(
        _cameraErrorMessage(error),
        textAlign: TextAlign.center,
        style: TextStyle(
          color: colors.textSecondary,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

String _cameraErrorMessage(MobileScannerException error) {
  final code = error.errorCode.name.toLowerCase();
  if (code.contains('permission')) {
    return 'Camera access is turned off. Check permissions and try again.';
  }
  return 'Camera is unavailable right now. Check camera access and try again.';
}

class _ScanFramePainter extends CustomPainter {
  const _ScanFramePainter(this.colors);

  final AppColors colors;

  @override
  void paint(Canvas canvas, Size size) {
    final dim = Paint()..color = Colors.black.withValues(alpha: 0.24);
    final windowSize = size.shortestSide * 0.66;
    final rect = Rect.fromCenter(
      center: Offset(size.width / 2, size.height / 2),
      width: windowSize,
      height: windowSize,
    );
    final clear = Paint()
      ..blendMode = BlendMode.clear
      ..style = PaintingStyle.fill;
    canvas.saveLayer(Offset.zero & size, Paint());
    canvas.drawRect(Offset.zero & size, dim);
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, const Radius.circular(22)),
      clear,
    );
    canvas.restore();

    final stroke = Paint()
      ..color = colors.accent
      ..strokeWidth = 4
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    const corner = 30.0;
    final path = Path()
      ..moveTo(rect.left, rect.top + corner)
      ..lineTo(rect.left, rect.top)
      ..lineTo(rect.left + corner, rect.top)
      ..moveTo(rect.right - corner, rect.top)
      ..lineTo(rect.right, rect.top)
      ..lineTo(rect.right, rect.top + corner)
      ..moveTo(rect.right, rect.bottom - corner)
      ..lineTo(rect.right, rect.bottom)
      ..lineTo(rect.right - corner, rect.bottom)
      ..moveTo(rect.left + corner, rect.bottom)
      ..lineTo(rect.left, rect.bottom)
      ..lineTo(rect.left, rect.bottom - corner);
    canvas.drawPath(path, stroke);
  }

  @override
  bool shouldRepaint(covariant _ScanFramePainter oldDelegate) =>
      oldDelegate.colors != colors;
}
