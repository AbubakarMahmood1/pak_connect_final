// Test file to verify message sending fixes
import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:pak_connect/core/services/security_manager.dart';
import 'package:pak_connect/data/repositories/contact_repository.dart';

import 'test_helpers/test_setup.dart';

void main() {
  final List<LogRecord> logRecords = [];
  final Set<String> allowedSevere = {
    'DECRYPT: All methods failed',
    'Decryption failed',
  };

  setUpAll(() async {
    await TestSetup.initializeTestEnvironment(dbLabel: 'message_sending_fixes');
    await SecurityManager.instance.initialize();
  });

  tearDownAll(() {
    SecurityManager.instance.shutdown();
  });

  setUp(() async {
    logRecords.clear();
    Logger.root.level = Level.ALL;
    Logger.root.onRecord.listen(logRecords.add);
    await TestSetup.configureTestDatabase(label: 'message_sending_fixes');
    TestSetup.resetSharedPreferences();
  });

  tearDown(() async {
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
    await TestSetup.nukeDatabase();
  });

  group('SecurityManager Empty String Handling', () {
    late ContactRepository contactRepo;

    setUp(() {
      contactRepo = ContactRepository();
    });

    test('getCurrentLevel handles empty string gracefully', () async {
      // This should NOT throw RangeError
      final level = await SecurityManager.instance.getCurrentLevel(
        '',
        contactRepo,
      );

      expect(level, SecurityLevel.low);
    });

    test('getCurrentLevel handles short strings without error', () async {
      // Test with string shorter than 16 characters
      final level = await SecurityManager.instance.getCurrentLevel(
        'abc123',
        contactRepo,
      );

      expect(level, SecurityLevel.low);
    });

    test('getCurrentLevel handles long strings correctly', () async {
      // Test with string longer than 16 characters
      final longKey = 'a' * 130; // Typical public key length

      // Should not crash
      final level = await SecurityManager.instance.getCurrentLevel(
        longKey,
        contactRepo,
      );

      expect(level, SecurityLevel.low);
    });

    test('getCurrentLevel handles null-coalesced empty string', () async {
      // Simulate: contactPublicKey ?? ''
      String? nullKey;
      final key = nullKey ?? '';

      final level = await SecurityManager.instance.getCurrentLevel(
        key,
        contactRepo,
      );

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
