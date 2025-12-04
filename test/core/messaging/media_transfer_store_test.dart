import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pak_connect/core/messaging/media_transfer_store.dart';

void main() {
  group('MediaTransferStore', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('media_store_test');
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('persists, reloads, and reuses deterministic transferId', () async {
      final store = MediaTransferStore(baseDirectoryOverride: tempDir);
      final data = Uint8List.fromList([1, 2, 3, 4, 5]);
      final record = await store.persist(data: data, metadata: {'foo': 'bar'});

      final reloaded = await store.load(record.transferId);
      expect(reloaded, isNotNull);
      expect(reloaded!.bytes, data);
      expect(reloaded.metadata['foo'], 'bar');

      final second = await store.persist(data: data, metadata: {'foo': 'bar'});
      expect(second.transferId, record.transferId);

      await store.remove(record.transferId);
      final missing = await store.load(record.transferId);
      expect(missing, isNull);
    });

    test('cleanupStaleTransfers removes old payloads', () async {
      final store = MediaTransferStore(baseDirectoryOverride: tempDir);
      final data = Uint8List.fromList([9, 8, 7]);
      final record = await store.persist(data: data, metadata: {'foo': 'old'});

      final basePath = '${tempDir.path}/${store.subDirectory}';
      final binFile = File('$basePath/${record.transferId}.bin');
      final metaFile = File('$basePath/${record.transferId}.json');
      final oldTime = DateTime.now().subtract(Duration(days: 2));
      await binFile.setLastModified(oldTime);
      await metaFile.setLastModified(oldTime);

      final removed = await store.cleanupStaleTransfers(
        maxAge: Duration(hours: 24),
      );

      expect(removed, 1);
      expect(await binFile.exists(), isFalse);
      expect(await metaFile.exists(), isFalse);
      expect(await store.load(record.transferId), isNull);
    });
  });
}
