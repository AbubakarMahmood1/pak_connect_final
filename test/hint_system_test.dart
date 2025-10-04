// File: test/hint_system_test.dart

import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:pak_connect/domain/entities/ephemeral_discovery_hint.dart';
import 'package:pak_connect/domain/entities/sensitive_contact_hint.dart';
import 'package:pak_connect/core/services/hint_advertisement_service.dart';
import 'package:pak_connect/core/utils/app_logger.dart';

void main() {
  final logger = AppLogger.getLogger('HintSystemTest');

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

  group('SensitiveContactHint Tests', () {
    test('Compute hint creates valid 4-byte hint', () {
      final publicKey = 'AAAA' * 32; // 128 char public key
      final sharedSeed = SensitiveContactHint.generateSharedSeed();

      final hint = SensitiveContactHint.compute(
        contactPublicKey: publicKey,
        sharedSeed: sharedSeed,
        displayName: 'Alice',
      );

      expect(hint.hintBytes.length, equals(4));
      expect(hint.contactPublicKey, equals(publicKey));
      expect(hint.displayName, equals('Alice'));
    });

    test('Hint hex string is 8 characters (4 bytes)', () {
      final publicKey = 'BBBB' * 32;
      final sharedSeed = SensitiveContactHint.generateSharedSeed();

      final hint = SensitiveContactHint.compute(
        contactPublicKey: publicKey,
        sharedSeed: sharedSeed,
      );

      expect(hint.hintHex.length, equals(8));
      expect(RegExp(r'^[0-9A-F]+$').hasMatch(hint.hintHex), isTrue);
    });

    test('Same inputs produce same hint (deterministic)', () {
      final publicKey = 'CCCC' * 32;
      final sharedSeed = SensitiveContactHint.generateSharedSeed();

      final hint1 = SensitiveContactHint.compute(
        contactPublicKey: publicKey,
        sharedSeed: sharedSeed,
      );

      final hint2 = SensitiveContactHint.compute(
        contactPublicKey: publicKey,
        sharedSeed: sharedSeed,
      );

      expect(hint1.hintHex, equals(hint2.hintHex));

      // Verify byte-by-byte equality
      for (int i = 0; i < 4; i++) {
        expect(hint1.hintBytes[i], equals(hint2.hintBytes[i]));
      }
    });

    test('Different public keys produce different hints', () {
      final sharedSeed = SensitiveContactHint.generateSharedSeed();

      final hint1 = SensitiveContactHint.compute(
        contactPublicKey: 'AAAA' * 32,
        sharedSeed: sharedSeed,
      );

      final hint2 = SensitiveContactHint.compute(
        contactPublicKey: 'BBBB' * 32,
        sharedSeed: sharedSeed,
      );

      expect(hint1.hintHex, isNot(equals(hint2.hintHex)));
    });

    test('Different seeds produce different hints', () {
      final publicKey = 'DDDD' * 32;

      final hint1 = SensitiveContactHint.compute(
        contactPublicKey: publicKey,
        sharedSeed: SensitiveContactHint.generateSharedSeed(),
      );

      final hint2 = SensitiveContactHint.compute(
        contactPublicKey: publicKey,
        sharedSeed: SensitiveContactHint.generateSharedSeed(),
      );

      expect(hint1.hintHex, isNot(equals(hint2.hintHex)));
    });

    test('Hint matching works correctly', () {
      final publicKey = 'EEEE' * 32;
      final sharedSeed = SensitiveContactHint.generateSharedSeed();

      final hint = SensitiveContactHint.compute(
        contactPublicKey: publicKey,
        sharedSeed: sharedSeed,
      );

      // Should match itself
      expect(hint.matches(hint.hintBytes), isTrue);

      // Should not match different hint
      final differentHint = Uint8List.fromList([1, 2, 3, 4]);
      expect(hint.matches(differentHint), isFalse);

      // Should not match wrong length
      final wrongLength = Uint8List.fromList([1, 2, 3]);
      expect(hint.matches(wrongLength), isFalse);
    });

    test('Generate 1000 shared seeds - all unique', () {
      final seeds = <String>{};

      for (int i = 0; i < 1000; i++) {
        final seed = SensitiveContactHint.generateSharedSeed();
        final seedHex = seed.map((b) => b.toRadixString(16)).join();
        seeds.add(seedHex);
      }

      // All seeds should be unique
      expect(seeds.length, equals(1000));
    });
  });

  group('HintAdvertisementService Tests', () {
    test('Pack advertisement with both hints (ultra-compressed 6-byte format)', () {
      final introHint = EphemeralDiscoveryHint.generate(displayName: 'Alice');
      final sharedSeed = SensitiveContactHint.generateSharedSeed();
      final ephemeralHint = SensitiveContactHint.compute(
        contactPublicKey: 'AAAA' * 32,
        sharedSeed: sharedSeed,
      );

      final packed = HintAdvertisementService.packAdvertisement(
        introHint: introHint,
        ephemeralHint: ephemeralHint,
      );

      expect(packed.length, equals(6)); // Ultra-compressed from 10 to 6 bytes
      expect(packed[0], equals(0x01)); // Version
    });

    test('Pack advertisement with only intro hint (3-byte truncated)', () {
      final introHint = EphemeralDiscoveryHint.generate(displayName: 'Bob');

      final packed = HintAdvertisementService.packAdvertisement(
        introHint: introHint,
      );

      expect(packed.length, equals(6));
      expect(packed[0], equals(0x01));

      // Intro should be present (bytes 1-3, truncated from original 8)
      expect(packed.sublist(1, 4), isNot(equals(Uint8List(3))));

      // Ephemeral should be zeros (bytes 4-5, truncated from original 4)
      expect(packed.sublist(4, 6), equals(Uint8List(2)));
    });

    test('Pack advertisement with only ephemeral hint (2-byte truncated)', () {
      final sharedSeed = SensitiveContactHint.generateSharedSeed();
      final ephemeralHint = SensitiveContactHint.compute(
        contactPublicKey: 'BBBB' * 32,
        sharedSeed: sharedSeed,
      );

      final packed = HintAdvertisementService.packAdvertisement(
        ephemeralHint: ephemeralHint,
      );

      expect(packed.length, equals(6));
      expect(packed[0], equals(0x01));

      // Intro should be zeros (bytes 1-3)
      expect(packed.sublist(1, 4), equals(Uint8List(3)));

      // Ephemeral should be present (bytes 4-5, truncated from original 4)
      expect(packed.sublist(4, 6), isNot(equals(Uint8List(2))));
    });

    test('Pack advertisement with no hints (idle mode)', () {
      final packed = HintAdvertisementService.packAdvertisement();

      expect(packed.length, equals(6));
      expect(packed[0], equals(0x01));

      // Both should be zeros
      expect(packed.sublist(1, 4), equals(Uint8List(3)));
      expect(packed.sublist(4, 6), equals(Uint8List(2)));
    });

    test('Parse packed advertisement correctly (ultra-compressed format)', () {
      final introHint = EphemeralDiscoveryHint.generate();
      final sharedSeed = SensitiveContactHint.generateSharedSeed();
      final ephemeralHint = SensitiveContactHint.compute(
        contactPublicKey: 'CCCC' * 32,
        sharedSeed: sharedSeed,
      );

      final packed = HintAdvertisementService.packAdvertisement(
        introHint: introHint,
        ephemeralHint: ephemeralHint,
      );

      final parsed = HintAdvertisementService.parseAdvertisement(packed);

      expect(parsed, isNotNull);
      expect(parsed!.hasIntroHint, isTrue);
      expect(parsed.hasEphemeralHint, isTrue);
      expect(parsed.hasAnyHint, isTrue);

      // Verify extracted bytes match truncated versions (3 bytes intro, 2 bytes ephemeral)
      expect(parsed.introHintBytes!.length, equals(3));
      expect(parsed.ephemeralHintBytes!.length, equals(2));

      // Verify truncated bytes match the first N bytes of originals
      expect(parsed.introHintBytes, equals(introHint.hintBytes.sublist(0, 3)));
      expect(parsed.ephemeralHintBytes, equals(ephemeralHint.hintBytes.sublist(0, 2)));
    });

    test('Parse rejects invalid length', () {
      final invalidData = Uint8List(10); // Wrong length (old 10-byte format)

      final parsed = HintAdvertisementService.parseAdvertisement(invalidData);

      expect(parsed, isNull);
    });

    test('Parse rejects invalid version', () {
      final data = Uint8List(6);
      data[0] = 0xFF; // Wrong version

      final parsed = HintAdvertisementService.parseAdvertisement(data);

      expect(parsed, isNull);
    });

    // Checksum test removed - new format doesn't use checksums (relies on BLE CRC)

    test('Round-trip packing and parsing preserves truncated data', () {
      final introHint = EphemeralDiscoveryHint.generate(displayName: 'Charlie');
      final sharedSeed = SensitiveContactHint.generateSharedSeed();
      final ephemeralHint = SensitiveContactHint.compute(
        contactPublicKey: 'DDDD' * 32,
        sharedSeed: sharedSeed,
        displayName: 'Diana',
      );

      // Pack
      final packed = HintAdvertisementService.packAdvertisement(
        introHint: introHint,
        ephemeralHint: ephemeralHint,
      );

      // Parse
      final parsed = HintAdvertisementService.parseAdvertisement(packed);

      // Verify - parsed data should match truncated versions
      expect(parsed, isNotNull);
      expect(parsed!.introHintBytes, equals(introHint.hintBytes.sublist(0, 3)));
      expect(parsed.ephemeralHintBytes, equals(ephemeralHint.hintBytes.sublist(0, 2)));
    });

    test('Format is ultra-compressed at 6 bytes (EXACTLY fits 31-byte BLE limit)', () {
      final introHint = EphemeralDiscoveryHint.generate();
      final sharedSeed = SensitiveContactHint.generateSharedSeed();
      final ephemeralHint = SensitiveContactHint.compute(
        contactPublicKey: 'EEEE' * 32,
        sharedSeed: sharedSeed,
      );

      final packed = HintAdvertisementService.packAdvertisement(
        introHint: introHint,
        ephemeralHint: ephemeralHint,
      );

      // Total size should be 6 bytes (version + 3-byte intro + 2-byte ephemeral)
      expect(packed.length, equals(6));

      // BLE Advertisement structure (accounting for ALL overhead):
      // - Flags: 3 bytes (length + type + value)
      // - Service UUID (128-bit): 18 bytes (length + type + 16-byte UUID)
      // - Manufacturer Data: 10 bytes (length + type + 2-byte manufacturer ID + 6-byte data)
      const flagsSize = 3;  // 1 (length) + 1 (type) + 1 (flags value)
      const serviceUuidSize = 18;  // 1 (length) + 1 (type) + 16 (UUID)
      const manufacturerOverhead = 4;  // 1 (length) + 1 (type) + 2 (manufacturer ID)
      final totalBleSize = flagsSize + serviceUuidSize + manufacturerOverhead + packed.length;

      expect(totalBleSize, equals(31));  // EXACTLY 31 bytes!
      logger.info('Total BLE advertisement size: $totalBleSize bytes (limit: 31 bytes) - PERFECT FIT!');
    });
  });

  group('Performance Tests', () {
    test('Generate 10,000 intro hints in reasonable time', () {
      final stopwatch = Stopwatch()..start();

      for (int i = 0; i < 10000; i++) {
        EphemeralDiscoveryHint.generate();
      }

      stopwatch.stop();

      logger.info('Generated 10,000 intro hints in ${stopwatch.elapsedMilliseconds}ms');
      expect(stopwatch.elapsedMilliseconds, lessThan(5000)); // Should be < 5 seconds
    });

    test('Compute 10,000 sensitive hints in reasonable time', () {
      final publicKey = 'EEEE' * 32;
      final sharedSeed = SensitiveContactHint.generateSharedSeed();

      final stopwatch = Stopwatch()..start();

      for (int i = 0; i < 10000; i++) {
        SensitiveContactHint.compute(
          contactPublicKey: publicKey,
          sharedSeed: sharedSeed,
        );
      }

      stopwatch.stop();

      logger.info('Computed 10,000 sensitive hints in ${stopwatch.elapsedMilliseconds}ms');
      expect(stopwatch.elapsedMilliseconds, lessThan(2000)); // Should be < 2 seconds
    });

    test('Pack/parse 10,000 advertisements in reasonable time', () {
      final introHint = EphemeralDiscoveryHint.generate();
      final sharedSeed = SensitiveContactHint.generateSharedSeed();
      final ephemeralHint = SensitiveContactHint.compute(
        contactPublicKey: 'FFFF' * 32,
        sharedSeed: sharedSeed,
      );

      final stopwatch = Stopwatch()..start();

      for (int i = 0; i < 10000; i++) {
        final packed = HintAdvertisementService.packAdvertisement(
          introHint: introHint,
          ephemeralHint: ephemeralHint,
        );

        HintAdvertisementService.parseAdvertisement(packed);
      }

      stopwatch.stop();

      logger.info('Pack/parsed 10,000 advertisements in ${stopwatch.elapsedMilliseconds}ms');
      expect(stopwatch.elapsedMilliseconds, lessThan(1000)); // Should be < 1 second
    });
  });

  group('Edge Cases', () {
    test('Expired intro hint is not included in advertisement', () {
      final expiredHint = EphemeralDiscoveryHint(
        hintBytes: Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8]),
        createdAt: DateTime.now().subtract(Duration(days: 15)),
        expiresAt: DateTime.now().subtract(Duration(days: 1)),
        isActive: true,
      );

      final packed = HintAdvertisementService.packAdvertisement(
        introHint: expiredHint,
      );

      final parsed = HintAdvertisementService.parseAdvertisement(packed);

      // Expired hint should not be advertised (all zeros)
      expect(parsed!.hasIntroHint, isFalse);
    });

    test('Handle all-zero hint bytes (6-byte format)', () {
      final zeros = Uint8List(6);
      zeros[0] = 0x01; // Valid version
      // Bytes 1-5 are all zeros (no hints)

      final parsed = HintAdvertisementService.parseAdvertisement(zeros);

      expect(parsed, isNotNull);
      expect(parsed!.hasIntroHint, isFalse);
      expect(parsed.hasEphemeralHint, isFalse);
      expect(parsed.hasAnyHint, isFalse);
    });

    test('QR data with missing fields returns null', () {
      final incompleteData = base64Encode(utf8.encode(jsonEncode({
        'type': 'pak_connect_intro',
        'version': 1,
        // Missing 'hint' and 'expires' fields
      })));

      final result = EphemeralDiscoveryHint.fromQRString(incompleteData);

      expect(result, isNull);
    });
  });
}
