import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:device_info_plus/device_info_plus.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:permission_handler/permission_handler.dart';
import 'package:super_clipboard/super_clipboard.dart';

@immutable
class ComposerImageAttachment {
  const ComposerImageAttachment({
    required this.id,
    required this.name,
    required this.mimeType,
    required this.bytes,
    required this.dataUrl,
  });

  final String id;
  final String name;
  final String mimeType;
  final Uint8List bytes;
  final String dataUrl;

  int get byteLength => bytes.length;
}

@immutable
class ComposerImageAttachmentUpdate {
  ComposerImageAttachmentUpdate({
    required List<ComposerImageAttachment> attachments,
    List<String> feedback = const <String>[],
    this.added = false,
  }) : attachments = List<ComposerImageAttachment>.unmodifiable(attachments),
       feedback = List<String>.unmodifiable(feedback);

  final List<ComposerImageAttachment> attachments;
  final List<String> feedback;
  final bool added;
}

abstract interface class ComposerImageAttachmentService {
  Future<ComposerImageAttachmentUpdate?> pickImages({
    required List<ComposerImageAttachment> current,
  });

  Future<ComposerImageAttachmentUpdate> pasteImage({
    required List<ComposerImageAttachment> current,
    bool reportEmpty = true,
  });
}

class SystemComposerImageAttachmentService
    implements ComposerImageAttachmentService {
  const SystemComposerImageAttachmentService();

  static const int maxImageCount = 4;
  static const int _maxImageBytes = 5 * 1024 * 1024;
  static const int _maxPayloadBytes = 9 * 1024 * 1024;
  static const int _maxDecodedImageBytes = 18 * 1024 * 1024;
  static const List<FileFormat> _clipboardImageFormats = <FileFormat>[
    Formats.png,
    Formats.jpeg,
    Formats.webp,
    Formats.gif,
    Formats.bmp,
    Formats.heic,
    Formats.heif,
  ];

  @override
  Future<ComposerImageAttachmentUpdate?> pickImages({
    required List<ComposerImageAttachment> current,
  }) async {
    if (current.length >= maxImageCount) {
      return ComposerImageAttachmentUpdate(
        attachments: current,
        feedback: const ['You can attach up to 4 images per message.'],
      );
    }

    final permissionError = await _requestPhotoLibraryAccess();
    if (permissionError != null) {
      return ComposerImageAttachmentUpdate(
        attachments: current,
        feedback: <String>[permissionError],
      );
    }

    final pickerConfig = _imagePickerConfig();
    final picked = await FilePicker.pickFiles(
      allowMultiple: true,
      withData: true,
      type: pickerConfig.type,
      allowedExtensions: pickerConfig.allowedExtensions,
    );
    if (picked == null || picked.files.isEmpty) {
      return null;
    }

    final attachments = List<ComposerImageAttachment>.from(current);
    final feedback = <String>[];
    var totalBytes = attachments.fold<int>(
      0,
      (sum, item) => sum + item.byteLength,
    );
    var added = false;

    for (final file in picked.files) {
      if (attachments.length >= maxImageCount) {
        feedback.add('You can attach up to 4 images per message.');
        break;
      }

      final bytes = file.bytes ?? await file.xFile.readAsBytes();
      final displayName = file.name.isEmpty ? 'image' : file.name;
      if (bytes.isEmpty) {
        feedback.add('Could not read $displayName.');
        continue;
      }
      if (bytes.length > _maxDecodedImageBytes) {
        feedback.add('$displayName is too large to process on-device.');
        continue;
      }

      final mimeType = _mimeTypeForImageName(file.name);
      if (mimeType == null) {
        feedback.add('$displayName is not a supported image.');
        continue;
      }

      final outcome = await _appendImage(
        attachments: attachments,
        totalBytes: totalBytes,
        name: displayName,
        mimeType: mimeType,
        bytes: bytes,
      );
      totalBytes = outcome.totalBytes;
      feedback.addAll(outcome.feedback);
      added = added || outcome.added;
      if (outcome.shouldStop) break;
    }

    return ComposerImageAttachmentUpdate(
      attachments: attachments,
      feedback: feedback,
      added: added,
    );
  }

  @override
  Future<ComposerImageAttachmentUpdate> pasteImage({
    required List<ComposerImageAttachment> current,
    bool reportEmpty = true,
  }) async {
    if (current.length >= maxImageCount) {
      return ComposerImageAttachmentUpdate(
        attachments: current,
        feedback: const ['You can attach up to 4 images per message.'],
      );
    }

    final clipboard = SystemClipboard.instance;
    if (clipboard == null) {
      return ComposerImageAttachmentUpdate(
        attachments: current,
        feedback: reportEmpty
            ? const ['Clipboard image paste is not supported here.']
            : const <String>[],
      );
    }

    final clipboardImage = await _readClipboardImage(clipboard);
    if (clipboardImage == null) {
      return ComposerImageAttachmentUpdate(
        attachments: current,
        feedback: reportEmpty
            ? const ['Clipboard does not contain an image.']
            : const <String>[],
      );
    }

    final attachments = List<ComposerImageAttachment>.from(current);
    final totalBytes = attachments.fold<int>(
      0,
      (sum, item) => sum + item.byteLength,
    );
    final outcome = await _appendImage(
      attachments: attachments,
      totalBytes: totalBytes,
      name: clipboardImage.name,
      mimeType: clipboardImage.mimeType,
      bytes: clipboardImage.bytes,
    );
    return ComposerImageAttachmentUpdate(
      attachments: attachments,
      feedback: outcome.feedback,
      added: outcome.added,
    );
  }

  _ImagePickerConfig _imagePickerConfig() {
    if (!kIsWeb && Platform.isIOS) {
      return const _ImagePickerConfig(
        type: FileType.image,
        requestPhotoLibraryAccess: true,
      );
    }
    return const _ImagePickerConfig(
      type: FileType.custom,
      allowedExtensions: <String>[
        'png',
        'jpg',
        'jpeg',
        'webp',
        'gif',
        'bmp',
        'heic',
        'heif',
      ],
    );
  }

  Future<String?> _requestPhotoLibraryAccess() async {
    final config = _imagePickerConfig();
    if (!config.requestPhotoLibraryAccess) return null;

    final status = await Permission.photos.request();
    if (status.isGranted || status.isLimited) return null;

    final systemVersion = (await DeviceInfoPlugin().iosInfo).systemVersion;
    final majorVersion = int.tryParse(systemVersion.split('.').first) ?? 0;
    if (majorVersion >= 14) return null;

    return status.isPermanentlyDenied || status.isRestricted
        ? 'Photo library access is disabled for Sidemesh in iOS Settings.'
        : 'Photo library access is required to attach images.';
  }

  Future<_ImageAppendOutcome> _appendImage({
    required List<ComposerImageAttachment> attachments,
    required int totalBytes,
    required String name,
    required String mimeType,
    required Uint8List bytes,
  }) async {
    if (bytes.isEmpty) {
      return _ImageAppendOutcome(
        totalBytes: totalBytes,
        feedback: <String>['Could not read $name.'],
      );
    }
    if (bytes.length > _maxDecodedImageBytes) {
      return _ImageAppendOutcome(
        totalBytes: totalBytes,
        feedback: <String>['$name is too large to process on-device.'],
      );
    }

    final payload = await compute(_compressComposerImage, <String, Object?>{
      'name': name,
      'mimeType': mimeType,
      'bytes': bytes,
    });
    final preparedName = payload['name']! as String;
    final preparedMimeType = payload['mimeType']! as String;
    final preparedBytes = payload['bytes']! as Uint8List;

    if (preparedBytes.length > _maxImageBytes) {
      return _ImageAppendOutcome(
        totalBytes: totalBytes,
        feedback: <String>[
          '$preparedName is still larger than 5 MB after compression.',
        ],
      );
    }
    if (totalBytes + preparedBytes.length > _maxPayloadBytes) {
      return _ImageAppendOutcome(
        totalBytes: totalBytes,
        shouldStop: true,
        feedback: const <String>[
          'Attached images are too large for one message. Remove one or pick a smaller file.',
        ],
      );
    }

    final dataUrl =
        'data:$preparedMimeType;base64,${base64Encode(preparedBytes)}';
    attachments.add(
      ComposerImageAttachment(
        id: 'draft-${DateTime.now().microsecondsSinceEpoch}-${attachments.length}',
        name: preparedName,
        mimeType: preparedMimeType,
        bytes: preparedBytes,
        dataUrl: dataUrl,
      ),
    );
    return _ImageAppendOutcome(
      totalBytes: totalBytes + preparedBytes.length,
      added: true,
    );
  }

  Future<_ClipboardImageData?> _readClipboardImage(
    SystemClipboard clipboard,
  ) async {
    final reader = await clipboard.read();
    for (final format in _clipboardImageFormats) {
      if (!reader.canProvide(format)) continue;
      final image = await _readClipboardImageForFormat(reader, format);
      if (image != null) return image;
    }
    return null;
  }

  Future<_ClipboardImageData?> _readClipboardImageForFormat(
    ClipboardReader reader,
    FileFormat format,
  ) {
    final completer = Completer<_ClipboardImageData?>();
    final progress = reader.getFile(
      format,
      (file) async {
        final bytes = await file.readAll();
        if (completer.isCompleted) return;
        final mimeType = _mimeTypeForClipboardFormat(format);
        completer.complete(
          _ClipboardImageData(
            name:
                file.fileName ??
                'pasted-image${imageExtensionForMimeType(mimeType)}',
            mimeType: mimeType,
            bytes: bytes,
          ),
        );
      },
      onError: (error) {
        if (!completer.isCompleted) completer.completeError(error);
      },
    );
    if (progress == null) {
      return Future<_ClipboardImageData?>.value(null);
    }
    return completer.future.timeout(
      const Duration(seconds: 10),
      onTimeout: () => null,
    );
  }
}

String? _mimeTypeForImageName(String name) {
  final lower = name.toLowerCase();
  if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) return 'image/jpeg';
  if (lower.endsWith('.png')) return 'image/png';
  if (lower.endsWith('.webp')) return 'image/webp';
  if (lower.endsWith('.gif')) return 'image/gif';
  if (lower.endsWith('.bmp')) return 'image/bmp';
  if (lower.endsWith('.heic')) return 'image/heic';
  if (lower.endsWith('.heif')) return 'image/heif';
  return null;
}

String _mimeTypeForClipboardFormat(FileFormat format) {
  if (identical(format, Formats.png)) return 'image/png';
  if (identical(format, Formats.jpeg)) return 'image/jpeg';
  if (identical(format, Formats.webp)) return 'image/webp';
  if (identical(format, Formats.gif)) return 'image/gif';
  if (identical(format, Formats.bmp)) return 'image/bmp';
  if (identical(format, Formats.heic)) return 'image/heic';
  if (identical(format, Formats.heif)) return 'image/heif';
  return 'image/png';
}

String imageExtensionForMimeType(String mimeType) {
  return switch (mimeType) {
    'image/jpeg' => '.jpg',
    'image/png' => '.png',
    'image/webp' => '.webp',
    'image/gif' => '.gif',
    'image/bmp' => '.bmp',
    'image/heic' => '.heic',
    'image/heif' => '.heif',
    _ => '.png',
  };
}

Map<String, Object?> _compressComposerImage(Map<String, Object?> payload) {
  final name = payload['name']! as String;
  final mimeType = payload['mimeType']! as String;
  final bytes = payload['bytes']! as Uint8List;

  if (mimeType == 'image/gif') {
    return <String, Object?>{
      'name': name,
      'mimeType': mimeType,
      'bytes': bytes,
    };
  }

  final decoded = img.decodeImage(bytes);
  if (decoded == null) {
    return <String, Object?>{
      'name': name,
      'mimeType': mimeType,
      'bytes': bytes,
    };
  }

  final baked = img.bakeOrientation(decoded);
  final longestEdge = math.max(baked.width, baked.height);
  final isPng = mimeType == 'image/png';
  final shouldKeepOriginal =
      longestEdge <= 1800 &&
      bytes.length <= 900 * 1024 &&
      !mimeType.contains('bmp');
  if (shouldKeepOriginal) {
    return <String, Object?>{
      'name': name,
      'mimeType': mimeType,
      'bytes': bytes,
    };
  }

  final resized = longestEdge > 1800
      ? img.copyResize(
          baked,
          width: baked.width >= baked.height ? 1800 : null,
          height: baked.height > baked.width ? 1800 : null,
          interpolation: img.Interpolation.cubic,
        )
      : baked;
  final outputMimeType = isPng ? 'image/png' : 'image/jpeg';
  final encoded = outputMimeType == 'image/png'
      ? Uint8List.fromList(img.encodePng(resized, level: 6))
      : Uint8List.fromList(img.encodeJpg(resized, quality: 84));
  final chosenBytes = encoded.length < bytes.length ? encoded : bytes;
  final chosenMimeType = identical(chosenBytes, encoded)
      ? outputMimeType
      : mimeType;

  return <String, Object?>{
    'name': name,
    'mimeType': chosenMimeType,
    'bytes': chosenBytes,
  };
}

class _ImagePickerConfig {
  const _ImagePickerConfig({
    required this.type,
    this.allowedExtensions,
    this.requestPhotoLibraryAccess = false,
  });

  final FileType type;
  final List<String>? allowedExtensions;
  final bool requestPhotoLibraryAccess;
}

class _ImageAppendOutcome {
  const _ImageAppendOutcome({
    required this.totalBytes,
    this.feedback = const <String>[],
    this.added = false,
    this.shouldStop = false,
  });

  final int totalBytes;
  final List<String> feedback;
  final bool added;
  final bool shouldStop;
}

class _ClipboardImageData {
  const _ClipboardImageData({
    required this.name,
    required this.mimeType,
    required this.bytes,
  });

  final String name;
  final String mimeType;
  final Uint8List bytes;
}
