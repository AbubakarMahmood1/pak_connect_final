import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';

/// Persists outgoing media payloads on the origin device so retries can
/// re-fragment using the latest MTU without keeping intermediates on disk.
class MediaTransferStore {
  MediaTransferStore({
    this.subDirectory = 'outgoing_media',
    this.baseDirectoryOverride,
  });

  final String subDirectory;
  final Directory? baseDirectoryOverride;
  Directory? _baseDir;

  Future<Directory> _ensureBaseDir() async {
    if (_baseDir != null) return _baseDir!;
    if (baseDirectoryOverride != null) {
      final overrideDir = Directory(
        '${baseDirectoryOverride!.path}/$subDirectory',
      );
      if (!await overrideDir.exists()) {
        await overrideDir.create(recursive: true);
      }
      _baseDir = overrideDir;
      return overrideDir;
    }

    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory('${docs.path}/$subDirectory');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    _baseDir = dir;
    return dir;
  }

  /// Persist [data] with optional [metadata] and return the computed transferId.
  Future<MediaTransferRecord> persist({
    required Uint8List data,
    Map<String, dynamic>? metadata,
  }) async {
    final normalizedMetadata = _normalizeMetadata(metadata ?? const {});
    final transferId = _computeTransferId(data, normalizedMetadata);
    final base = await _ensureBaseDir();
    final binPath = '${base.path}/$transferId.bin';
    final metaPath = '${base.path}/$transferId.json';

    await File(binPath).writeAsBytes(data, flush: true);
    await File(
      metaPath,
    ).writeAsString(jsonEncode(normalizedMetadata), flush: true);

    return MediaTransferRecord(
      transferId: transferId,
      filePath: binPath,
      metadata: normalizedMetadata,
      bytes: data,
    );
  }

  /// Load a previously persisted transfer; returns null if missing.
  Future<MediaTransferRecord?> load(String transferId) async {
    final base = await _ensureBaseDir();
    final binPath = '${base.path}/$transferId.bin';
    final metaPath = '${base.path}/$transferId.json';

    final binFile = File(binPath);
    if (!await binFile.exists()) return null;
    final metaFile = File(metaPath);
    Map<String, dynamic> metadata = const {};
    if (await metaFile.exists()) {
      metadata =
          jsonDecode(await metaFile.readAsString()) as Map<String, dynamic>;
    }

    return MediaTransferRecord(
      transferId: transferId,
      filePath: binPath,
      metadata: metadata,
      bytes: await binFile.readAsBytes(),
    );
  }

  Future<void> remove(String transferId) async {
    final base = await _ensureBaseDir();
    final binFile = File('${base.path}/$transferId.bin');
    final metaFile = File('${base.path}/$transferId.json');
    if (await binFile.exists()) await binFile.delete();
    if (await metaFile.exists()) await metaFile.delete();
  }

  /// Remove transfers older than [maxAge]. Returns the number of transfers
  /// deleted. Intended to prevent disk growth from failed or abandoned sends.
  Future<int> cleanupStaleTransfers({
    Duration maxAge = const Duration(hours: 24),
  }) async {
    final base = await _ensureBaseDir();
    final cutoff = DateTime.now().subtract(maxAge);
    var removed = 0;

    await for (final entity in base.list()) {
      if (entity is! File || !entity.path.endsWith('.bin')) continue;
      try {
        final stat = await entity.stat();
        if (stat.modified.isBefore(cutoff)) {
          final fileName = entity.uri.pathSegments.last;
          final transferId = fileName.replaceFirst('.bin', '');
          await remove(transferId);
          removed++;
        }
      } catch (_) {
        // Best-effort cleanup; ignore individual file errors.
        continue;
      }
    }

    return removed;
  }

  Map<String, dynamic> _normalizeMetadata(Map<String, dynamic> metadata) {
    final entries = metadata.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    return Map.fromEntries(entries);
  }

  String _computeTransferId(Uint8List data, Map<String, dynamic> metadata) {
    final digest = sha256.convert([
      ...data,
      ...utf8.encode(jsonEncode(metadata)),
    ]);
    return digest.toString();
  }
}

class MediaTransferRecord {
  MediaTransferRecord({
    required this.transferId,
    required this.filePath,
    required this.metadata,
    this.bytes,
  });

  final String transferId;
  final String filePath;
  final Map<String, dynamic> metadata;
  final Uint8List? bytes;
}
