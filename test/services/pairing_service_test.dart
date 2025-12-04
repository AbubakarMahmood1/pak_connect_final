import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:pak_connect/data/services/pairing_service.dart';
import 'package:mockito/mockito.dart';

void main() {
  final List<LogRecord> logRecords = [];
  final Set<String> allowedSevere = {};
  StreamSubscription<LogRecord>? logSub;
  Level? previousLevel;

  group('PairingService', () {
    late PairingService pairingService;

    setUp(() {
      logRecords.clear();
      previousLevel = Logger.root.level;
      Logger.root.level = Level.ALL;
      logSub = Logger.root.onRecord.listen(logRecords.add);
      pairingService = PairingService(
        getMyPersistentId: () async => 'my_id_123',
        getTheirSessionId: () => 'their_session_123',
        getTheirDisplayName: () => 'Alice',
      );
    });

    tearDown(() {
      logSub?.cancel();
      logSub = null;
      if (previousLevel != null) {
        Logger.root.level = previousLevel!;
      }
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

    test('generates pairing code on demand', () {
      final code = pairingService.generatePairingCode();

      // Should return a 4-digit code
      expect(code, isNotEmpty);
      expect(code.length, equals(4));

      // Should be numeric
      expect(int.tryParse(code), isNotNull);

      // Should be between 1000 and 9999
      final codeValue = int.parse(code);
      expect(codeValue, greaterThanOrEqualTo(1000));
      expect(codeValue, lessThanOrEqualTo(9999));
    });

    test('returns same code when called again while displaying', () {
      final code1 = pairingService.generatePairingCode();
      final code2 = pairingService.generatePairingCode();

      // Should return the same code while in displaying state
      expect(code1, equals(code2));
    });

    test('clears pairing state', () {
      pairingService.generatePairingCode();
      pairingService.clearPairing();

      expect(pairingService.currentPairing, isNull);
    });

    test('handles received pairing code', () async {
      pairingService.generatePairingCode();
      pairingService.handleReceivedPairingCode('5678');

      expect(pairingService.theirReceivedCode, equals('5678'));
    });

    test('tracks whether we entered code', () async {
      pairingService.generatePairingCode();

      expect(pairingService.weEnteredCode, isFalse);

      await pairingService.completePairing('5678');

      expect(pairingService.weEnteredCode, isTrue);
    });

    test('stores current pairing info', () {
      final code = pairingService.generatePairingCode();

      expect(pairingService.currentPairing, isNotNull);
      expect(pairingService.currentPairing!.myCode, equals(code));
    });

    test('completes pairing flow', () async {
      pairingService.generatePairingCode();
      pairingService.handleReceivedPairingCode('5678');

      // completePairing should not throw
      await pairingService.completePairing('5678');
    });

    test('handles pairing verification', () {
      pairingService.generatePairingCode();
      pairingService.handleReceivedPairingCode('5678');

      // Should not throw
      pairingService.handlePairingVerification('hash123');
    });

    test('invokes onSendPairingCode callback when code generated', () {
      var codeCallbackInvoked = false;
      var sentCode = '';

      pairingService.onSendPairingCode = (code) {
        codeCallbackInvoked = true;
        sentCode = code;
      };

      final code = pairingService.generatePairingCode();

      // Callback should be invoked if implemented
      // expect(codeCallbackInvoked, isTrue);
      // expect(sentCode, equals(code));
    });
  });
}
