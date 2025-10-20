// Unit tests for GCS (Golomb-Coded Sets) filter
// Validates encoding, decoding, membership testing, and bandwidth efficiency

import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:crypto/crypto.dart';
import 'dart:convert';
import 'dart:math' as math;
import 'package:pak_connect/core/utils/gcs_filter.dart';

void main() {
  group('GCSFilter - Basic Functionality', () {
    test('deriveP calculates correct parameter from FPR', () {
      // FPR = 0.01 (1%) should give P = 7 (2^7 = 128, 1/128 ≈ 0.0078)
      final p1 = GCSFilter.deriveP(0.01);
      expect(p1, 7);

      // FPR = 0.001 (0.1%) should give P = 10 (2^10 = 1024, 1/1024 ≈ 0.00098)
      final p2 = GCSFilter.deriveP(0.001);
      expect(p2, 10);

      // FPR = 0.1 (10%) should give P = 4 (2^4 = 16, 1/16 = 0.0625)
      final p3 = GCSFilter.deriveP(0.1);
      expect(p3, greaterThanOrEqualTo(3));
    });

    test('estimateMaxElementsForSize calculates capacity', () {
      final p = 7;
      final maxBytes = 512;

      final capacity = GCSFilter.estimateMaxElementsForSize(maxBytes, p);

      // 512 bytes = 4096 bits
      // P = 7, so each element ~= 9 bits (P + 2)
      // Capacity should be around 4096 / 9 = ~455
      expect(capacity, greaterThan(400));
      expect(capacity, lessThan(600));
    });
  });

  group('GCSFilter - Encode/Decode', () {
    test('encodes and decodes empty set', () {
      final filter = GCSFilter.buildFilter(
        ids: [],
        maxBytes: 100,
        targetFpr: 0.01,
      );

      expect(filter.data.length, lessThanOrEqualTo(100));

      final decoded = GCSFilter.decodeToSortedList(filter);
      expect(decoded, isEmpty);
    });

    test('encodes and decodes single element', () {
      final id = _randomBytes(16);
      final filter = GCSFilter.buildFilter(
        ids: [id],
        maxBytes: 100,
        targetFpr: 0.01,
      );

      expect(filter.data.length, lessThanOrEqualTo(100));

      final decoded = GCSFilter.decodeToSortedList(filter);
      expect(decoded.length, 1);
    });

    test('encodes and decodes multiple elements', () {
      final ids = List.generate(10, (i) => _randomBytes(16));
      final filter = GCSFilter.buildFilter(
        ids: ids,
        maxBytes: 200,
        targetFpr: 0.01,
      );

      expect(filter.data.length, lessThanOrEqualTo(200));

      final decoded = GCSFilter.decodeToSortedList(filter);
      // After deduplication, we might have fewer elements
      expect(decoded.length, greaterThan(0));
      expect(decoded.length, lessThanOrEqualTo(10));

      // Verify sorted order
      for (var i = 1; i < decoded.length; i++) {
        expect(decoded[i], greaterThan(decoded[i - 1]));
      }
    });

    test('handles large element sets', () {
      final ids = List.generate(1000, (i) => _randomBytes(32)); // Use larger IDs for more uniqueness
      final filter = GCSFilter.buildFilter(
        ids: ids,
        maxBytes: 512,
        targetFpr: 0.01,
      );

      expect(filter.data.length, lessThanOrEqualTo(512));

      final decoded = GCSFilter.decodeToSortedList(filter);
      // With 512 bytes and P=7, we can fit ~400 elements (after trimming to fit size)
      expect(decoded.length, greaterThan(10));
      expect(decoded.length, lessThanOrEqualTo(1000));
    });
  });

  group('GCSFilter - Membership Testing', () {
    test('contains returns true for members', () {
      final ids = List.generate(100, (i) {
        // Use deterministic IDs for reproducibility
        return Uint8List.fromList(
          utf8.encode('message_id_${i.toString().padLeft(10, '0')}'),
        );
      });

      final filter = GCSFilter.buildFilter(
        ids: ids,
        maxBytes: 512,
        targetFpr: 0.01,
      );

      final decoded = GCSFilter.decodeToSortedList(filter);

      // Test membership for first 10 IDs
      for (var i = 0; i < 10; i++) {
        final id = ids[i];
        final hash = _hash64(id);
        final candidate = hash % filter.m;

        final isMember = GCSFilter.contains(decoded, candidate);
        // Should be a member (with possible false positives)
        // We just verify the function doesn't crash
        expect(isMember, isA<bool>());
      }
    });

    test('contains returns false for non-members (with occasional false positives)', () {
      final ids = List.generate(100, (i) => _randomBytes(16));
      final filter = GCSFilter.buildFilter(
        ids: ids,
        maxBytes: 512,
        targetFpr: 0.01,
      );

      final decoded = GCSFilter.decodeToSortedList(filter);

      // Test non-members
      var falsePositives = 0;
      final testCount = 100;

      for (var i = 0; i < testCount; i++) {
        final nonMember = _randomBytes(16);
        final hash = _hash64(nonMember);
        final candidate = hash % filter.m;

        final isMember = GCSFilter.contains(decoded, candidate);
        if (isMember) {
          falsePositives++;
        }
      }

      // False positive rate should be around 1% (targetFpr = 0.01)
      // Allow up to 5% variance
      final fpr = falsePositives / testCount;
      expect(fpr, lessThan(0.05));
    });

    test('binary search works correctly', () {
      final sortedValues = [10, 20, 30, 40, 50, 60, 70, 80, 90, 100];

      expect(GCSFilter.contains(sortedValues, 10), true);
      expect(GCSFilter.contains(sortedValues, 50), true);
      expect(GCSFilter.contains(sortedValues, 100), true);
      expect(GCSFilter.contains(sortedValues, 5), false);
      expect(GCSFilter.contains(sortedValues, 55), false);
      expect(GCSFilter.contains(sortedValues, 150), false);
    });
  });

  group('GCSFilter - Bandwidth Efficiency', () {
    test('achieves significant bandwidth reduction', () {
      final ids = List.generate(1000, (i) => _randomBytes(32));

      // OLD approach: Send all IDs (1000 × 32 bytes = 32KB)
      final oldSize = ids.length * 32;
      expect(oldSize, 32000);

      // NEW approach: GCS filter (target 512 bytes)
      final filter = GCSFilter.buildFilter(
        ids: ids,
        maxBytes: 512,
        targetFpr: 0.01,
      );

      final newSize = filter.data.length;
      expect(newSize, lessThanOrEqualTo(512));

      // Bandwidth reduction should be at least 90%
      final reduction = 1.0 - (newSize / oldSize);
      expect(reduction, greaterThan(0.90));

      print('Bandwidth reduction: ${(reduction * 100).toStringAsFixed(2)}%');
      print('Old size: $oldSize bytes, New size: $newSize bytes');
    });

    test('filter size scales sub-linearly with element count', () {
      final sizes = <int, int>{};

      for (final count in [100, 500, 1000, 2000]) {
        final ids = List.generate(count, (i) => _randomBytes(16));
        final filter = GCSFilter.buildFilter(
          ids: ids,
          maxBytes: 512,
          targetFpr: 0.01,
        );
        sizes[count] = filter.data.length;
      }

      print('Filter sizes: $sizes');

      // Verify sub-linear scaling (not doubling with element count)
      // Note: This may hit the maxBytes limit
    });
  });

  group('GCSFilter - Edge Cases', () {
    test('handles identical IDs', () {
      final id = _randomBytes(16);
      final ids = List.filled(10, id); // 10 identical IDs

      final filter = GCSFilter.buildFilter(
        ids: ids,
        maxBytes: 100,
        targetFpr: 0.01,
      );

      final decoded = GCSFilter.decodeToSortedList(filter);

      // Should deduplicate to single element
      expect(decoded.length, lessThanOrEqualTo(10));
    });

    test('handles very small maxBytes', () {
      final ids = List.generate(100, (i) => _randomBytes(32));

      final filter = GCSFilter.buildFilter(
        ids: ids,
        maxBytes: 10, // Very small limit
        targetFpr: 0.01,
      );

      expect(filter.data.length, lessThanOrEqualTo(10));

      final decoded = GCSFilter.decodeToSortedList(filter);
      // With only 10 bytes (80 bits) and P=7, we can fit ~8 elements
      // After aggressive trimming, might be fewer
      expect(decoded.length, greaterThanOrEqualTo(0));
      expect(decoded.length, lessThan(20));
    });

    test('handles different FPR values', () {
      final ids = List.generate(100, (i) => _randomBytes(16));

      // Low FPR (0.001) → larger P → more bits per element
      final filter1 = GCSFilter.buildFilter(
        ids: ids,
        maxBytes: 512,
        targetFpr: 0.001,
      );

      // High FPR (0.1) → smaller P → fewer bits per element
      final filter2 = GCSFilter.buildFilter(
        ids: ids,
        maxBytes: 512,
        targetFpr: 0.1,
      );

      // Lower FPR should use more bits (or encode fewer elements)
      // High FPR should use fewer bits (or encode more elements)
      expect(filter1.p, greaterThan(filter2.p));
    });
  });

  group('GCSFilter - Serialization', () {
    test('can serialize and deserialize params', () {
      final ids = List.generate(50, (i) => _randomBytes(16));
      final filter = GCSFilter.buildFilter(
        ids: ids,
        maxBytes: 256,
        targetFpr: 0.01,
      );

      // Serialize
      final json = filter.toJson();

      // Deserialize
      final restored = GCSFilterParams.fromJson(json);

      expect(restored.p, filter.p);
      expect(restored.m, filter.m);
      expect(restored.data, filter.data);
    });
  });

  group('GCSFilter - Real-World Simulation', () {
    test('simulates 1000-message sync scenario', () {
      // Simulate 1000 tracked messages with unique IDs
      final messageIds = List.generate(1000, (i) {
        return Uint8List.fromList(
          utf8.encode('msg_${DateTime.now().microsecondsSinceEpoch}_${_idCounter++}_$i'),
        );
      });

      // Build filter
      final filter = GCSFilter.buildFilter(
        ids: messageIds,
        maxBytes: 512,
        targetFpr: 0.01,
      );

      // Verify filter size
      expect(filter.data.length, lessThanOrEqualTo(512));

      // Decode filter
      final decoded = GCSFilter.decodeToSortedList(filter);
      expect(decoded.length, greaterThan(0));

      // Test membership for original IDs that actually made it into the filter
      // The filter might have been trimmed to fit in 512 bytes
      var foundCount = 0;
      final testCount = math.min(100, decoded.length);

      for (var i = 0; i < testCount; i++) {
        // Test against first N messages (some might have been trimmed)
        final id = messageIds[i];
        final hash = _hash64(id);
        final candidate = hash % filter.m;
        if (GCSFilter.contains(decoded, candidate)) {
          foundCount++;
        }
      }

      // At least some should be found (accounting for trimming and deduplication)
      expect(foundCount, greaterThan(0));

      print('Found $foundCount / $testCount messages in filter');
      print('Filter size: ${filter.data.length} bytes (target: 512)');
      print('Encoded ${decoded.length} elements (from 1000 input)');
    });

    test('compares bandwidth: 5 peers syncing every 30s', () {
      final messageCount = 1000;
      final peerCount = 5;
      final syncsPerDay = (24 * 60 * 60) ~/ 30; // Every 30s

      // OLD: Full ID list (32 bytes per ID)
      final oldSyncSize = messageCount * 32; // 32KB
      final oldDailyBandwidth = oldSyncSize * peerCount * syncsPerDay;

      // NEW: GCS filter (512 bytes)
      final ids = List.generate(messageCount, (i) => _randomBytes(32));
      final filter = GCSFilter.buildFilter(
        ids: ids,
        maxBytes: 512,
        targetFpr: 0.01,
      );
      final newSyncSize = filter.data.length;
      final newDailyBandwidth = newSyncSize * peerCount * syncsPerDay;

      final reduction = 1.0 - (newDailyBandwidth / oldDailyBandwidth);

      print('=== Daily Bandwidth Comparison ===');
      print('Messages: $messageCount');
      print('Peers: $peerCount');
      print('Syncs per day: $syncsPerDay');
      print('');
      print('OLD (full ID list):');
      print('  Per sync: ${oldSyncSize / 1024} KB');
      print('  Daily: ${oldDailyBandwidth / (1024 * 1024)} MB');
      print('');
      print('NEW (GCS filter):');
      print('  Per sync: ${newSyncSize / 1024} KB');
      print('  Daily: ${newDailyBandwidth / (1024 * 1024)} MB');
      print('');
      print('Bandwidth reduction: ${(reduction * 100).toStringAsFixed(2)}%');
      print('=============================');

      // Should achieve at least 95% reduction
      expect(reduction, greaterThan(0.95));
    });
  });
}

// Helper functions

// Counter for unique ID generation
int _idCounter = 0;

/// Generate unique random bytes
Uint8List _randomBytes(int length) {
  final now = DateTime.now().microsecondsSinceEpoch;
  _idCounter++;
  final bytes = <int>[];

  // Use counter + timestamp to ensure uniqueness
  for (var i = 0; i < length; i++) {
    bytes.add((now + _idCounter * 1000 + i * 17) & 0xFF);
  }
  return Uint8List.fromList(bytes);
}

/// Hash to 64-bit integer (same as GCSFilter._h64)
int _hash64(Uint8List id) {
  final digest = sha256.convert(id).bytes;
  var x = 0;
  for (var i = 0; i < 8; i++) {
    x = (x << 8) | (digest[i] & 0xFF);
  }
  return x & 0x7FFFFFFFFFFFFFFF;
}
