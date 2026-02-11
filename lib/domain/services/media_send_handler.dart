import 'dart:io';
import 'dart:typed_data';
import 'package:logging/logging.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';

import '../interfaces/i_mesh_networking_service.dart';
import '../constants/binary_payload_types.dart';

/// Exception thrown when media send operations fail
class MediaSendException implements Exception {
  const MediaSendException(this.message, [this.code, this.cause]);

  final String message;
  final String? code;
  final Object? cause;

  factory MediaSendException.tooLarge([int? maxSize]) => MediaSendException(
    'File too large (max ${maxSize != null ? "${maxSize ~/ (1024 * 1024)}MB" : "2MB"})',
    'FILE_TOO_LARGE',
  );

  factory MediaSendException.invalidFile() => const MediaSendException(
    'File does not exist or is not accessible',
    'INVALID_FILE',
  );

  factory MediaSendException.unsupportedType(String? mimeType) =>
      MediaSendException(
        'Unsupported file type${mimeType != null ? ": $mimeType" : ""}',
        'UNSUPPORTED_TYPE',
      );

  factory MediaSendException.encryptionNotReady() => const MediaSendException(
    'Cannot send media: encryption session not established',
    'ENCRYPTION_NOT_READY',
  );

  @override
  String toString() => 'MediaSendException: $message';
}

/// Handles media file sending operations with safety checks and compression
///
/// Extracted from UI to enable testing and maintain separation of concerns.
/// Designed to be wrapped in a Riverpod notifier later if needed.
class MediaSendHandler {
  MediaSendHandler({
    required IMeshNetworkingService meshService,
    bool Function(String recipientId)? hasEstablishedNoiseSession,
    Logger? logger,
    int? maxFileSizeBytes,
    int? compressionThresholdBytes,
  }) : _meshService = meshService,
       _hasEstablishedNoiseSession = hasEstablishedNoiseSession,
       _logger = logger ?? Logger('MediaSendHandler'),
       _maxFileSizeBytes = maxFileSizeBytes ?? _defaultMaxFileSizeBytes,
       _compressionThresholdBytes =
           compressionThresholdBytes ?? _defaultCompressionThreshold;

  final IMeshNetworkingService _meshService;
  final bool Function(String recipientId)? _hasEstablishedNoiseSession;
  final Logger _logger;
  final int _maxFileSizeBytes;
  final int _compressionThresholdBytes;

  static const int _defaultMaxFileSizeBytes =
      2 * 1024 * 1024; // 2MB (BLE mesh optimized)
  static const int _defaultCompressionThreshold = 1 * 1024 * 1024; // 1MB

  /// Supported image MIME types
  static const List<String> supportedImageTypes = [
    'image/jpeg',
    'image/png',
    'image/gif',
    'image/webp',
    'image/heic',
    'image/heif',
  ];

  /// Send an image file to a recipient via mesh network
  ///
  /// Validates file size, reads bytes (with optional compression for large files),
  /// and queues for transmission via mesh service.
  ///
  /// Throws [MediaSendException] if validation fails.
  ///
  /// [knownMimeType] should be provided from XFile.mimeType when available
  /// for more reliable type detection than extension-based detection.
  Future<String> sendImage({
    required File file,
    required String recipientId,
    Map<String, dynamic>? metadata,
    String? knownMimeType,
  }) async {
    try {
      _logger.fine('📸 Starting image send: ${file.path}');

      // CRITICAL: Validate file exists BEFORE size check
      if (!await file.exists()) {
        _logger.warning('❌ File does not exist: ${file.path}');
        throw MediaSendException.invalidFile();
      }

      // CRITICAL: Check size BEFORE reading to avoid OOM
      final size = await file.length();
      _logger.fine('📊 File size: ${size ~/ 1024}KB');

      if (size == 0) {
        _logger.warning('❌ File is empty (zero bytes)');
        throw MediaSendException.invalidFile();
      }

      if (size > _maxFileSizeBytes) {
        _logger.warning(
          '❌ File too large: ${size ~/ 1024}KB (max: ${_maxFileSizeBytes ~/ 1024}KB)',
        );
        throw MediaSendException.tooLarge(_maxFileSizeBytes);
      }

      // Detect MIME type (prefer known MIME type from picker) and normalize
      final rawMimeType = knownMimeType ?? _detectMimeType(file.path);
      final mimeType = _normalizeMimeType(rawMimeType);
      _logger.fine(
        '🏷️  MIME type: $mimeType${knownMimeType != null ? ' (from picker)' : ' (from extension)'}',
      );

      if (!supportedImageTypes.contains(mimeType)) {
        _logger.warning('❌ Unsupported MIME type: $mimeType');
        throw MediaSendException.unsupportedType(mimeType);
      }

      // Compress if needed (above threshold)
      Uint8List bytes;
      int finalSize = size;
      if (size > _compressionThresholdBytes && _shouldCompress(mimeType)) {
        _logger.info(
          '🗜️  Compressing image (${size ~/ 1024}KB > ${_compressionThresholdBytes ~/ 1024}KB)',
        );
        bytes = await _compressImage(file, mimeType);
        finalSize = bytes.length;
        _logger.info(
          '✅ Compressed: ${size ~/ 1024}KB → ${finalSize ~/ 1024}KB (${(100 - (finalSize / size * 100)).toStringAsFixed(1)}% reduction)',
        );
      } else {
        // Read bytes directly (removed Isolate.run to avoid memory doubling)
        bytes = await file.readAsBytes();
        _logger.fine('✅ Read ${bytes.length} bytes (no compression needed)');
      }

      // Build metadata
      final enrichedMetadata = <String, dynamic>{
        'filename': _extractFilename(file.path),
        'mimeType': mimeType,
        'originalSize': size,
        if (metadata != null) ...metadata,
      };

      // CRITICAL: Verify Noise session is established before sending
      // This prevents plaintext fallback and enforces encryption-ready state
      if (_hasEstablishedNoiseSession != null &&
          !_hasEstablishedNoiseSession(recipientId)) {
        _logger.warning('❌ Noise session not established for $recipientId');
        throw MediaSendException.encryptionNotReady();
      }

      // Send via mesh service
      _logger.info(
        '📡 Sending image to $recipientId (${bytes.length ~/ 1024}KB)',
      );
      final transferId = await _meshService.sendBinaryMedia(
        data: bytes,
        recipientId: recipientId,
        originalType: BinaryPayloadType.media,
        metadata: enrichedMetadata,
      );

      _logger.info('✅ Image queued for sending: $transferId');
      return transferId;
    } catch (e, stackTrace) {
      if (e is MediaSendException) rethrow;
      _logger.severe('💥 Failed to send image: $e', e, stackTrace);
      throw MediaSendException('Failed to send image: $e', null, e);
    }
  }

  /// Send a generic file to a recipient via mesh network
  ///
  /// Similar to [sendImage] but with broader file type support.
  ///
  /// [knownMimeType] should be provided from XFile.mimeType when available
  /// for more reliable type detection than extension-based detection.
  Future<String> sendFile({
    required File file,
    required String recipientId,
    Map<String, dynamic>? metadata,
    String? knownMimeType,
  }) async {
    try {
      _logger.fine('📎 Starting file send: ${file.path}');

      // CRITICAL: Validate file exists BEFORE size check
      if (!await file.exists()) {
        _logger.warning('❌ File does not exist: ${file.path}');
        throw MediaSendException.invalidFile();
      }

      // CRITICAL: Check size BEFORE reading to avoid OOM
      final size = await file.length();
      _logger.fine('📊 File size: ${size ~/ 1024}KB');

      if (size == 0) {
        _logger.warning('❌ File is empty (zero bytes)');
        throw MediaSendException.invalidFile();
      }

      if (size > _maxFileSizeBytes) {
        _logger.warning(
          '❌ File too large: ${size ~/ 1024}KB (max: ${_maxFileSizeBytes ~/ 1024}KB)',
        );
        throw MediaSendException.tooLarge(_maxFileSizeBytes);
      }

      // Detect MIME type (prefer known MIME type from picker) and normalize
      final rawMimeType = knownMimeType ?? _detectMimeType(file.path);
      final mimeType = _normalizeMimeType(rawMimeType);
      _logger.fine(
        '🏷️  MIME type: $mimeType${knownMimeType != null ? ' (from picker)' : ' (from extension)'}',
      );

      // Read bytes directly (removed Isolate.run to avoid memory doubling)
      final bytes = await file.readAsBytes();
      _logger.fine('✅ Read ${bytes.length} bytes');

      // Build metadata
      final enrichedMetadata = <String, dynamic>{
        'filename': _extractFilename(file.path),
        'mimeType': mimeType,
        'originalSize': size,
        if (metadata != null) ...metadata,
      };

      // CRITICAL: Verify Noise session is established before sending
      // This prevents plaintext fallback and enforces encryption-ready state
      if (_hasEstablishedNoiseSession != null &&
          !_hasEstablishedNoiseSession(recipientId)) {
        _logger.warning('❌ Noise session not established for $recipientId');
        throw MediaSendException.encryptionNotReady();
      }

      // Send via mesh service
      _logger.info(
        '📡 Sending file to $recipientId (${bytes.length ~/ 1024}KB)',
      );
      final transferId = await _meshService.sendBinaryMedia(
        data: bytes,
        recipientId: recipientId,
        originalType: BinaryPayloadType.media,
        metadata: enrichedMetadata,
      );

      _logger.info('✅ File queued for sending: $transferId');
      return transferId;
    } catch (e, stackTrace) {
      if (e is MediaSendException) rethrow;
      _logger.severe('💥 Failed to send file: $e', e, stackTrace);
      throw MediaSendException('Failed to send file: $e', null, e);
    }
  }

  /// Detect MIME type from file extension
  String _detectMimeType(String path) {
    final extension = path.toLowerCase().split('.').last;

    switch (extension) {
      // Images
      case 'jpg':
      case 'jpeg':
        return 'image/jpeg';
      case 'png':
        return 'image/png';
      case 'gif':
        return 'image/gif';
      case 'webp':
        return 'image/webp';
      case 'heic':
        return 'image/heic';
      case 'heif':
        return 'image/heif';

      // Documents
      case 'pdf':
        return 'application/pdf';
      case 'doc':
        return 'application/msword';
      case 'docx':
        return 'application/vnd.openxmlformats-officedocument.wordprocessingml.document';
      case 'txt':
        return 'text/plain';

      // Audio
      case 'mp3':
        return 'audio/mpeg';
      case 'wav':
        return 'audio/wav';
      case 'm4a':
        return 'audio/mp4';
      case 'ogg':
        return 'audio/ogg';

      // Video
      case 'mp4':
        return 'video/mp4';
      case 'mov':
        return 'video/quicktime';
      case 'avi':
        return 'video/x-msvideo';

      // Default
      default:
        return 'application/octet-stream';
    }
  }

  /// Extract filename from path
  String _extractFilename(String path) {
    return path.split('/').last;
  }

  /// Normalize MIME type to lowercase and strip parameters
  ///
  /// Handles cases like:
  /// - "IMAGE/JPEG" → "image/jpeg"
  /// - "image/jpeg; charset=binary" → "image/jpeg"
  /// - "image/png " → "image/png"
  String _normalizeMimeType(String mimeType) {
    return mimeType.toLowerCase().split(';').first.trim();
  }

  /// Check if MIME type supports compression
  bool _shouldCompress(String mimeType) {
    // Only compress JPEG and PNG (avoid re-compressing WebP/HEIC/GIF)
    return mimeType == 'image/jpeg' || mimeType == 'image/png';
  }

  /// Compress image using flutter_image_compress
  ///
  /// NOTE: This version of flutter_image_compress (2.4.0) only supports minWidth/minHeight
  /// which can upscale images. Since we're already limiting file size to 2MB and using
  /// quality compression (80), we skip resize to avoid upscaling small images.
  Future<Uint8List> _compressImage(File file, String mimeType) async {
    try {
      // Use quality compression only (no resize) to avoid upscaling
      // minWidth/minHeight would upscale 800×600 to 1920×1080
      final result = await FlutterImageCompress.compressWithFile(
        file.absolute.path,
        minWidth: 0, // 0 = don't resize
        minHeight: 0, // 0 = don't resize
        quality: 80,
        format: mimeType == 'image/png'
            ? CompressFormat.png
            : CompressFormat.jpeg,
      );

      if (result == null) {
        _logger.warning(
          '⚠️ Compression returned null, falling back to original',
        );
        return await file.readAsBytes();
      }

      return result;
    } catch (e) {
      _logger.warning('⚠️ Compression failed: $e, falling back to original');
      return await file.readAsBytes();
    }
  }
}
