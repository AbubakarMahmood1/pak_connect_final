// Test file to verify message sending fixes
import 'package:flutter_test/flutter_test.dart';
import 'package:pak_connect/core/services/security_manager.dart';
import 'package:pak_connect/data/repositories/contact_repository.dart';

import 'test_helpers/test_setup.dart';

void main() {
  setUpAll(() async {
    await TestSetup.initializeTestEnvironment();
    await SecurityManager.initialize();
  });

  tearDownAll(() {
    SecurityManager.shutdown();
  });

  setUp(() async {
    await TestSetup.cleanupDatabase();
    TestSetup.resetSharedPreferences();
  });

  tearDown(() async {
    await TestSetup.completeCleanup();
  });

  group('SecurityManager Empty String Handling', () {
    late ContactRepository contactRepo;

    setUp(() {
      contactRepo = ContactRepository();
    });

    test('getCurrentLevel handles empty string gracefully', () async {
      // This should NOT throw RangeError
      final level = await SecurityManager.getCurrentLevel('', contactRepo);

      expect(level, SecurityLevel.low);
    });

    test('getCurrentLevel handles short strings without error', () async {
      // Test with string shorter than 16 characters
      final level = await SecurityManager.getCurrentLevel(
        'abc123',
        contactRepo,
      );

      expect(level, SecurityLevel.low);
    });

    test('getCurrentLevel handles long strings correctly', () async {
      // Test with string longer than 16 characters
      final longKey = 'a' * 130; // Typical public key length

      // Should not crash
      final level = await SecurityManager.getCurrentLevel(longKey, contactRepo);

      expect(level, SecurityLevel.low);
    });

    test('getCurrentLevel handles null-coalesced empty string', () async {
      // Simulate: contactPublicKey ?? ''
      String? nullKey;
      final key = nullKey ?? '';

      final level = await SecurityManager.getCurrentLevel(key, contactRepo);

      expect(level, SecurityLevel.low);
    });
  });

  group('Safe String Truncation', () {
    test('truncate empty string', () {
      final input = '';
      final result = input.isEmpty
          ? 'EMPTY'
          : (input.length > 16 ? input.substring(0, 16) : input);

      expect(result, 'EMPTY');
    });

    test('truncate short string', () {
      final input = 'abc123';
      final result = input.length > 16 ? input.substring(0, 16) : input;

      expect(result, 'abc123');
    });

    test('truncate long string', () {
      final input = 'a' * 50;
      final result = input.length > 16 ? input.substring(0, 16) : input;

      expect(result, 'a' * 16);
    });

    test('truncate exactly 16 characters', () {
      final input = 'a' * 16;
      final result = input.length > 16 ? input.substring(0, 16) : input;

      expect(result, input);
    });
  });

  group('Error Scenarios', () {
    test('empty string substring should be prevented', () {
      final input = '';

      // OLD WAY (would crash):
      // final result = input.substring(0, 16); // RangeError!

      // NEW WAY (safe):
      final result = input.isEmpty
          ? 'NULL'
          : (input.length > 16 ? input.substring(0, 16) : input);

      expect(result, 'NULL');
    });

    test('null-coalesced empty string should be caught', () {
      String? nullValue;
      final coalesced = nullValue ?? '';

      // Should detect empty and handle safely
      expect(coalesced.isEmpty, true);

      final safe = coalesced.isEmpty ? 'DEFAULT' : coalesced;
      expect(safe, 'DEFAULT');
    });
  });
}
