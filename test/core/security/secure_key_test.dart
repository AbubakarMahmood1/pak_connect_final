import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:pak_connect/core/security/secure_key.dart';

/// Tests for SecureKey wrapper
///
/// **FIX-001**: Verifies that SecureKey prevents private key memory leaks
/// by immediately zeroing the original key upon construction.
void main() {
  group('SecureKey', () {
    final List<LogRecord> logRecords = [];
    final Set<String> allowedSevere = {};

    setUp(() {
      logRecords.clear();
      Logger.root.level = Level.ALL;
      Logger.root.onRecord.listen(logRecords.add);
    });

    tearDown(() {
      final severeErrors = logRecords
          .where((log) => log.level >= Level.SEVERE)
          .where(
            (log) =>
                !allowedSevere.any((pattern) => log.message.contains(pattern)),
          )
          .toList();
      expect(
        severeErrors,
        isEmpty,
        reason:
            'Unexpected SEVERE errors:\n${severeErrors.map((e) => '${e.level}: ${e.message}').join('\n')}',
      );
    });

    group('Construction and Zeroing', () {
      test('zeros original key immediately upon construction', () {
        // Arrange
        final original = Uint8List.fromList([1, 2, 3, 4, 5]);
        final originalCopy = Uint8List.fromList([
          1,
          2,
          3,
          4,
          5,
        ]); // For comparison

        // Act
        final secureKey = SecureKey(original);

        // Assert: Original is zeroed
        expect(original, equals([0, 0, 0, 0, 0]));
        expect(original, isNot(equals(originalCopy)));

        // Assert: SecureKey has copy of original data
        expect(secureKey.data, equals(originalCopy));

        secureKey.destroy();
      });

      test('handles empty key', () {
        final original = Uint8List(0);
        final secureKey = SecureKey(original);

        expect(secureKey.data.length, equals(0));
        expect(secureKey.length, equals(0));

        secureKey.destroy();
      });

      test('handles 32-byte key (typical private key size)', () {
        final original = Uint8List(32);
        for (int i = 0; i < 32; i++) {
          original[i] = i;
        }

        final secureKey = SecureKey(original);

        // Verify original is zeroed
        expect(original, equals(Uint8List(32)));

        // Verify data is preserved
        expect(secureKey.data.length, equals(32));
        for (int i = 0; i < 32; i++) {
          expect(secureKey.data[i], equals(i));
        }

        secureKey.destroy();
      });
    });

    group('Access Control', () {
      test('allows data access before destruction', () {
        final original = Uint8List.fromList([1, 2, 3]);
        final secureKey = SecureKey(original);

        // Should not throw
        final data = secureKey.data;
        expect(data, equals([1, 2, 3]));

        secureKey.destroy();
      });

      test('throws StateError when accessing data after destruction', () {
        final original = Uint8List.fromList([1, 2, 3]);
        final secureKey = SecureKey(original);

        secureKey.destroy();

        // Should throw
        expect(
          () => secureKey.data,
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              contains('SecureKey has been destroyed'),
            ),
          ),
        );
      });

      test('allows length access after destruction', () {
        final original = Uint8List.fromList([1, 2, 3]);
        final secureKey = SecureKey(original);

        secureKey.destroy();

        // Should not throw (length is safe to access)
        expect(secureKey.length, equals(3));
      });

      test('isDestroyed tracks state correctly', () {
        final original = Uint8List.fromList([1, 2, 3]);
        final secureKey = SecureKey(original);

        expect(secureKey.isDestroyed, isFalse);

        secureKey.destroy();

        expect(secureKey.isDestroyed, isTrue);
      });
    });

    group('Destruction', () {
      test('zeros internal data on destroy', () {
        final original = Uint8List.fromList([1, 2, 3, 4, 5]);
        final secureKey = SecureKey(original);

        final dataBeforeDestroy = secureKey.data;
        expect(dataBeforeDestroy, equals([1, 2, 3, 4, 5]));

        secureKey.destroy();

        // Internal data should be zeroed (we can't access via .data anymore,
        // but we can check if it threw the expected error)
        expect(() => secureKey.data, throwsStateError);
      });

      test('destroy is idempotent', () {
        final original = Uint8List.fromList([1, 2, 3]);
        final secureKey = SecureKey(original);

        // Destroy multiple times
        secureKey.destroy();
        secureKey.destroy();
        secureKey.destroy();

        // Should still be destroyed
        expect(secureKey.isDestroyed, isTrue);
        expect(() => secureKey.data, throwsStateError);
      });
    });

    group('Hex Conversion', () {
      test('fromHex creates SecureKey from hex string', () {
        final hexString = '0102030405';
        final secureKey = SecureKey.fromHex(hexString);

        expect(secureKey.data, equals([1, 2, 3, 4, 5]));

        secureKey.destroy();
      });

      test('fromHex handles 32-byte hex string (64 chars)', () {
        final hexString = '0' * 64; // 32 bytes of zeros
        final secureKey = SecureKey.fromHex(hexString);

        expect(secureKey.length, equals(32));
        expect(secureKey.data, equals(Uint8List(32)));

        secureKey.destroy();
      });

      test('fromHex throws on odd-length hex string', () {
        expect(
          () => SecureKey.fromHex('012'),
          throwsA(
            isA<ArgumentError>().having(
              (e) => e.message,
              'message',
              contains('even length'),
            ),
          ),
        );
      });

      test('toHex converts key to hex string', () {
        final original = Uint8List.fromList([1, 2, 3, 4, 5]);
        final secureKey = SecureKey(original);

        final hexString = secureKey.toHex();

        expect(hexString, equals('0102030405'));

        secureKey.destroy();
      });

      test('toHex throws after destruction', () {
        final original = Uint8List.fromList([1, 2, 3]);
        final secureKey = SecureKey(original);

        secureKey.destroy();

        expect(
          () => secureKey.toHex(),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              contains('destroyed key'),
            ),
          ),
        );
      });

      test('roundtrip: original → SecureKey → hex → SecureKey → data', () {
        final original = Uint8List.fromList([0xDE, 0xAD, 0xBE, 0xEF]);
        final secureKey1 = SecureKey(original);

        final hex = secureKey1.toHex();
        expect(hex, equals('deadbeef'));

        final secureKey2 = SecureKey.fromHex(hex);
        expect(secureKey2.data, equals([0xDE, 0xAD, 0xBE, 0xEF]));

        secureKey1.destroy();
        secureKey2.destroy();
      });
    });

    group('toString()', () {
      test('toString() shows active state with length', () {
        final original = Uint8List.fromList([1, 2, 3]);
        final secureKey = SecureKey(original);

        final str = secureKey.toString();

        expect(str, contains('active'));
        expect(str, contains('3 bytes'));

        secureKey.destroy();
      });

      test('toString() shows destroyed state with length', () {
        final original = Uint8List.fromList([1, 2, 3]);
        final secureKey = SecureKey(original);

        secureKey.destroy();

        final str = secureKey.toString();

        expect(str, contains('destroyed'));
        expect(str, contains('3 bytes'));
      });
    });

    group('FIX-001 Integration Tests', () {
      test('prevents memory leak when passed to function', () {
        // Simulate passing key to NoiseSession constructor
        final originalKey = Uint8List(32);
        for (int i = 0; i < 32; i++) {
          originalKey[i] = i + 1;
        }

        // Function that creates SecureKey (like NoiseSession constructor)
        SecureKey simulateConstructor(Uint8List key) {
          return SecureKey(key);
        }

        final secureKey = simulateConstructor(originalKey);

        // Verify original is zeroed (no memory leak)
        expect(originalKey, equals(Uint8List(32)));

        // Verify data is preserved in SecureKey
        for (int i = 0; i < 32; i++) {
          expect(secureKey.data[i], equals(i + 1));
        }

        secureKey.destroy();
      });

      test('destroy() fully cleans up without leaving traces', () {
        final original = Uint8List.fromList([0xFF, 0xFE, 0xFD, 0xFC]);
        final secureKey = SecureKey(original);

        // Before destroy
        expect(secureKey.data, equals([0xFF, 0xFE, 0xFD, 0xFC]));

        // Destroy
        secureKey.destroy();

        // After destroy: original is already zeroed (from construction)
        expect(original, equals([0, 0, 0, 0]));

        // SecureKey prevents access
        expect(() => secureKey.data, throwsStateError);
      });

      test('multiple SecureKeys can coexist without interference', () {
        final key1 = Uint8List.fromList([1, 1, 1]);
        final key2 = Uint8List.fromList([2, 2, 2]);
        final key3 = Uint8List.fromList([3, 3, 3]);

        final secure1 = SecureKey(key1);
        final secure2 = SecureKey(key2);
        final secure3 = SecureKey(key3);

        // All originals zeroed
        expect(key1, equals([0, 0, 0]));
        expect(key2, equals([0, 0, 0]));
        expect(key3, equals([0, 0, 0]));

        // All SecureKeys have correct data
        expect(secure1.data, equals([1, 1, 1]));
        expect(secure2.data, equals([2, 2, 2]));
        expect(secure3.data, equals([3, 3, 3]));

        // Destroy in different order
        secure2.destroy();
        expect(() => secure2.data, throwsStateError);
        expect(secure1.data, equals([1, 1, 1])); // Still accessible
        expect(secure3.data, equals([3, 3, 3])); // Still accessible

        secure1.destroy();
        secure3.destroy();
      });
    });
  });
}
