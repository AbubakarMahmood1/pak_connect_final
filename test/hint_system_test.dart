// File: test/hint_system_test.dart

import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:pak_connect/domain/entities/ephemeral_discovery_hint.dart';
import 'package:pak_connect/core/services/hint_advertisement_service.dart';
import 'package:pak_connect/core/utils/app_logger.dart';

void main() {
  late List<LogRecord> logRecords;
  late Set<Pattern> allowedSevere;

  final logger = AppLogger.getLogger('HintSystemTest');

  setUp(() {
    logRecords = [];
    allowedSevere = {};
    Logger.root.level = Level.ALL;
    Logger.root.onRecord.listen(logRecords.add);
  });

  tearDown(() {
    final severe = logRecords.where((l) => l.level >= Level.SEVERE);
    final unexpected = severe.where(
      (l) => !allowedSevere.any(
        (p) => p is String
            ? l.message.contains(p)
            : (p as RegExp).hasMatch(l.message),
      ),
    );
    expect(
      unexpected,
      isEmpty,
      reason: 'Unexpected SEVERE errors:\n${unexpected.join("\n")}',
    );
    for (final pattern in allowedSevere) {
      final found = severe.any(
        (l) => pattern is String
            ? l.message.contains(pattern)
            : (pattern as RegExp).hasMatch(l.message),
      );
      expect(
        found,
        isTrue,
        reason: 'Missing expected SEVERE matching "$pattern"',
      );
    }
  });

  group('EphemeralDiscoveryHint Tests', () {
    test('Generate hint creates valid 8-byte hint', () {
      final hint = EphemeralDiscoveryHint.generate(displayName: 'Alice');

      expect(hint.hintBytes.length, equals(8));
      expect(hint.displayName, equals('Alice'));
      expect(hint.isActive, isTrue);
      expect(hint.isExpired, isFalse);
      expect(hint.isUsable, isTrue);
    });

    test('Hint hex string is 16 characters (8 bytes)', () {
      final hint = EphemeralDiscoveryHint.generate();

      expect(hint.hintHex.length, equals(16));
      expect(RegExp(r'^[0-9A-F]+$').hasMatch(hint.hintHex), isTrue);
    });

    test('QR encoding and decoding works correctly', () {
      final original = EphemeralDiscoveryHint.generate(displayName: 'Bob');
      final qrString = original.toQRString();

      final decoded = EphemeralDiscoveryHint.fromQRString(qrString);

      expect(decoded, isNotNull);
      expect(decoded!.hintHex, equals(original.hintHex));
      expect(decoded.displayName, equals('Bob'));
    });

    test('Invalid QR data returns null', () {
      final result1 = EphemeralDiscoveryHint.fromQRString('invalid data');
      final result2 = EphemeralDiscoveryHint.fromQRString('');

      expect(result1, isNull);
      expect(result2, isNull);
    });

    test('Expired hint is not usable', () {
      final hint = EphemeralDiscoveryHint(
        hintBytes: Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8]),
        createdAt: DateTime.now().subtract(Duration(days: 15)),
        expiresAt: DateTime.now().subtract(Duration(days: 1)),
        isActive: true,
      );

      expect(hint.isExpired, isTrue);
      expect(hint.isUsable, isFalse);
    });

    test('Inactive hint is not usable even if not expired', () {
      final hint = EphemeralDiscoveryHint(
        hintBytes: Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8]),
        createdAt: DateTime.now(),
        expiresAt: DateTime.now().add(Duration(days: 14)),
        isActive: false,
      );

      expect(hint.isExpired, isFalse);
      expect(hint.isUsable, isFalse);
    });

    test('Generate 1000 hints - all unique', () {
      final hints = <String>{};

      for (int i = 0; i < 1000; i++) {
        final hint = EphemeralDiscoveryHint.generate();
        hints.add(hint.hintHex);
      }

      // All hints should be unique
      expect(hints.length, equals(1000));
    });
  });

  group('HintAdvertisementService Tests', () {
    test('deriveNonce uses first bytes of session key', () {
      final nonce = HintAdvertisementService.deriveNonce('A1B2C3D4');
      expect(nonce.length, 2);
      expect(nonce[0], equals(0xA1));
      expect(nonce[1], equals(0xB2));
    });

    test('Pack and parse persistent hint round-trip', () {
      final sessionKey = 'DEADBEEFCAFEBABE' * 4;
      final nonce = HintAdvertisementService.deriveNonce(sessionKey);
      final identifier = 'pubkey_123';
      final hintBytes = HintAdvertisementService.computeHintBytes(
        identifier: identifier,
        nonce: nonce,
      );

      final packed = HintAdvertisementService.packAdvertisement(
        nonce: nonce,
        hintBytes: hintBytes,
      );

      expect(packed.length, equals(6));
      expect(packed[0] & HintAdvertisementService.introFlag, equals(0));

      final parsed = HintAdvertisementService.parseAdvertisement(packed);
      expect(parsed, isNotNull);
      expect(parsed!.isIntro, isFalse);
      expect(parsed.hintBytes, equals(hintBytes));
      expect(parsed.nonce, equals(nonce));
    });

    test('Pack marks intro flag and parses correctly', () {
      final nonce = Uint8List.fromList([0x12, 0x34]);
      final identifier = EphemeralDiscoveryHint.generate().hintHex;
      final hintBytes = HintAdvertisementService.computeHintBytes(
        identifier: identifier,
        nonce: nonce,
      );

      final packed = HintAdvertisementService.packAdvertisement(
        nonce: nonce,
        hintBytes: hintBytes,
        isIntro: true,
      );

      expect(packed[0] & HintAdvertisementService.introFlag, isNot(0));

      final parsed = HintAdvertisementService.parseAdvertisement(packed);
      expect(parsed, isNotNull);
      expect(parsed!.isIntro, isTrue);
      expect(parsed.hintBytes, equals(hintBytes));
    });

    test('parseAdvertisement rejects invalid payloads', () {
      expect(HintAdvertisementService.parseAdvertisement(Uint8List(4)), isNull);

      final data = Uint8List(6);
      data[0] = 0xFF;
      expect(HintAdvertisementService.parseAdvertisement(data), isNull);
    });
  });

  group('Performance Tests', () {
    test('Generate 10,000 intro hints in reasonable time', () {
      final stopwatch = Stopwatch()..start();

      for (int i = 0; i < 10000; i++) {
        EphemeralDiscoveryHint.generate();
      }

      stopwatch.stop();

      logger.info(
        'Generated 10,000 intro hints in ${stopwatch.elapsedMilliseconds}ms',
      );
      expect(
        stopwatch.elapsedMilliseconds,
        lessThan(5000),
      ); // Should be < 5 seconds
    });

    test('Compute 10,000 blinded hints in reasonable time', () {
      final nonce = Uint8List.fromList([0xAA, 0x55]);

      final stopwatch = Stopwatch()..start();

      for (int i = 0; i < 10000; i++) {
        HintAdvertisementService.computeHintBytes(
          identifier: 'pubkey_$i',
          nonce: nonce,
        );
      }

      stopwatch.stop();

      logger.info(
        'Computed 10,000 blinded hints in ${stopwatch.elapsedMilliseconds}ms',
      );
      expect(
        stopwatch.elapsedMilliseconds,
        lessThan(2000),
      ); // Should be < 2 seconds
    });

    test('Pack/parse 10,000 advertisements in reasonable time', () {
      final identifier = 'FFFF' * 8;
      final nonce = Uint8List.fromList([0x10, 0x20]);

      final stopwatch = Stopwatch()..start();

      for (int i = 0; i < 10000; i++) {
        final hintBytes = HintAdvertisementService.computeHintBytes(
          identifier: '$identifier$i',
          nonce: nonce,
        );

        final packed = HintAdvertisementService.packAdvertisement(
          nonce: nonce,
          hintBytes: hintBytes,
          isIntro: i.isEven,
        );

        HintAdvertisementService.parseAdvertisement(packed);
      }

      stopwatch.stop();

      logger.info(
        'Pack/parsed 10,000 advertisements in ${stopwatch.elapsedMilliseconds}ms',
      );
      expect(
        stopwatch.elapsedMilliseconds,
        lessThan(1200),
      ); // Should be ~1 second
    });
  });

  group('Edge Cases', () {
    test('packAdvertisement validates nonce and hint sizes', () {
      final nonce = Uint8List.fromList([0x01]);
      final hintBytes = Uint8List.fromList([0x01, 0x02, 0x03]);

      expect(
        () => HintAdvertisementService.packAdvertisement(
          nonce: nonce,
          hintBytes: hintBytes,
        ),
        throwsArgumentError,
      );

      expect(
        () => HintAdvertisementService.packAdvertisement(
          nonce: Uint8List.fromList([0x01, 0x02]),
          hintBytes: Uint8List.fromList([0x01, 0x02]),
        ),
        throwsArgumentError,
      );
    });

    test('deriveNonce pads short session keys', () {
      final nonce = HintAdvertisementService.deriveNonce('1A');
      expect(nonce[0], equals(0x1A));
      expect(nonce[1], equals(0x00));
    });

    test('parseAdvertisement rejects invalid versions', () {
      final data = Uint8List(6);
      data[0] = 0x03; // Unknown version

      expect(HintAdvertisementService.parseAdvertisement(data), isNull);
    });

    test('all-zero hint bytes parse successfully', () {
      final nonce = Uint8List(2);
      final hintBytes = Uint8List(3);

      final packed = HintAdvertisementService.packAdvertisement(
        nonce: nonce,
        hintBytes: hintBytes,
      );

      final parsed = HintAdvertisementService.parseAdvertisement(packed);
      expect(parsed, isNotNull);
      expect(parsed!.hintBytes.every((value) => value == 0), isTrue);
      expect(parsed.isIntro, isFalse);
    });

    test('QR data with missing fields returns null', () {
      final incompleteData = base64Encode(
        utf8.encode(
          jsonEncode({
            'type': 'pak_connect_intro',
            'version': 1,
            // Missing 'hint' and 'expires' fields
          }),
        ),
      );

      final result = EphemeralDiscoveryHint.fromQRString(incompleteData);

      expect(result, isNull);
    });
  });
}

