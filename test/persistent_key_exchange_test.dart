import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:pak_connect/domain/models/protocol_message.dart';

/// STEP 4: Persistent Key Exchange Tests
///
/// Tests the protocol message structure for persistent key exchange.
/// This happens AFTER PIN verification succeeds during the pairing process.
///
/// Flow:
/// 1. Handshake completes (ephemeral IDs exchanged)
/// 2. User accepts pairing request
/// 3. PIN codes verified successfully
/// 4. Persistent keys automatically exchanged ← TESTING THIS
/// 5. Mapping stored: ephemeralId → persistentKey
/// 6. Contact updated with persistent key

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final List<LogRecord> logRecords = [];
  final Set<String> allowedSevere = {};

  group('STEP 4: Protocol Message Validation', () {
    setUp(() async {
      logRecords.clear();
      Logger.root.level = Level.ALL;
      Logger.root.onRecord.listen(logRecords.add);
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
    });

    test('persistentKeyExchange message has correct type', () {
      const testKey = 'test_persistent_public_key';

      final message = ProtocolMessage.persistentKeyExchange(
        persistentPublicKey: testKey,
      );

      expect(message.type, ProtocolMessageType.persistentKeyExchange);
    });

    test('persistentKeyExchange message payload contains key', () {
      const testKey = 'test_persistent_public_key';

      final message = ProtocolMessage.persistentKeyExchange(
        persistentPublicKey: testKey,
      );

      expect(message.payload, containsPair('persistentPublicKey', testKey));
    });

    test('persistentKeyExchange message serializes and deserializes', () {
      const testKey = 'test_persistent_public_key_with_lots_of_data';

      final originalMessage = ProtocolMessage.persistentKeyExchange(
        persistentPublicKey: testKey,
      );

      // Serialize to bytes
      final bytes = originalMessage.toBytes();

      // Deserialize back
      final deserializedMessage = ProtocolMessage.fromBytes(bytes);

      expect(
        deserializedMessage.type,
        ProtocolMessageType.persistentKeyExchange,
      );
      expect(
        deserializedMessage.payload['persistentPublicKey'],
        equals(testKey),
      );
    });

    test('persistentKeyExchange message has timestamp', () {
      const testKey = 'test_key';
      final before = DateTime.now();

      final message = ProtocolMessage.persistentKeyExchange(
        persistentPublicKey: testKey,
      );

      final after = DateTime.now();

      expect(
        message.timestamp.isAfter(before.subtract(Duration(seconds: 1))),
        isTrue,
      );
      expect(
        message.timestamp.isBefore(after.add(Duration(seconds: 1))),
        isTrue,
      );
    });

    test('persistentKeyExchange preserves long public keys', () {
      const longKey =
          'very_long_persistent_public_key_with_lots_of_cryptographic_data_0123456789abcdef';

      final message = ProtocolMessage.persistentKeyExchange(
        persistentPublicKey: longKey,
      );

      expect(message.payload['persistentPublicKey'], equals(longKey));
      expect(
        message.payload['persistentPublicKey']!.length,
        equals(longKey.length),
      );
    });

    test('persistentKeyExchange handles special characters in keys', () {
      const keyWithSpecialChars = 'key+with/special=chars_123';

      final message = ProtocolMessage.persistentKeyExchange(
        persistentPublicKey: keyWithSpecialChars,
      );

      final bytes = message.toBytes();
      final deserialized = ProtocolMessage.fromBytes(bytes);

      expect(
        deserialized.payload['persistentPublicKey'],
        equals(keyWithSpecialChars),
      );
    });
  });

  group('STEP 4: Message Type Ordering', () {
    setUp(() async {
      logRecords.clear();
      Logger.root.level = Level.ALL;
      Logger.root.onRecord.listen(logRecords.add);
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
    });

    test('persistentKeyExchange comes after pairing messages in protocol', () {
      final types = ProtocolMessageType.values;
      final pairingRequestIndex = types.indexOf(
        ProtocolMessageType.pairingRequest,
      );
      final pairingAcceptIndex = types.indexOf(
        ProtocolMessageType.pairingAccept,
      );
      final pairingCodeIndex = types.indexOf(ProtocolMessageType.pairingCode);
      final pairingVerifyIndex = types.indexOf(
        ProtocolMessageType.pairingVerify,
      );
      final keyExchangeIndex = types.indexOf(
        ProtocolMessageType.persistentKeyExchange,
      );

      // Key exchange should come after all pairing steps
      expect(keyExchangeIndex > pairingRequestIndex, isTrue);
      expect(keyExchangeIndex > pairingAcceptIndex, isTrue);
      expect(keyExchangeIndex > pairingCodeIndex, isTrue);
      expect(keyExchangeIndex > pairingVerifyIndex, isTrue);
    });
  });
}
