import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';

import 'package:pak_connect/domain/services/ephemeral_key_manager.dart';
import 'package:pak_connect/data/services/ble_message_handler.dart';
import 'package:pak_connect/data/repositories/contact_repository.dart';

import 'test_helpers/message_handler_test_utils.dart';
import 'test_helpers/test_setup.dart';

void main() {
  setUpAll(() async {
    await TestSetup.initializeTestEnvironment(dbLabel: 'message_routing_fix');
  });

  group('Message Routing Fix Tests', () {
    final List<LogRecord> logRecords = [];
    final Set<String> allowedSevere = {
      'DECRYPT: All methods failed',
      'Decryption failed',
    };

    late BLEMessageHandler messageHandler;
    late ContactRepository contactRepository;

    const String aliPublicKey = 'ali_public_key_12345';
    const String arshadPublicKey = 'arshad_public_key_67890';

    setUp(() async {
      logRecords.clear();
      Logger.root.level = Level.ALL;
      Logger.root.onRecord.listen(logRecords.add);
      await TestSetup.configureTestDatabase(label: 'message_routing_fix');
      TestSetup.resetSharedPreferences();
      await EphemeralKeyManager.initialize('test_private_key_1234567890');
      await seedTestUserPublicKey(aliPublicKey);
      messageHandler = BLEMessageHandler();
      contactRepository = ContactRepository();
      messageHandler.setCurrentNodeId(aliPublicKey);
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

    test('Should block own messages from appearing as incoming', () async {
      final protocolMessage = buildV2EncryptedTestMessage(
        messageId: 'test_msg_1',
        content: 'ciphertext-self',
        senderId: aliPublicKey,
      );

      // Process the message as if it came from Ali (same as current user)
      final result = await messageHandler.processReceivedData(
        protocolMessageToWireBytes(protocolMessage),
        senderPublicKey: aliPublicKey, // Same as current user
        contactRepository: contactRepository,
      );

      // Should return null (blocked) since it's from the current user
      expect(result, isNull, reason: 'Own messages should be blocked');
    });

    test(
      'Should allow legitimate direct messages between different users',
      () async {
        final protocolMessage = buildV2EncryptedTestMessage(
          messageId: 'test_msg_2',
          content: 'ciphertext-for-ali',
          senderId: arshadPublicKey,
        );

        // Process the message as if it came from Arshad (different user)
        final result = await messageHandler.processReceivedData(
          protocolMessageToWireBytes(protocolMessage),
          senderPublicKey: arshadPublicKey, // Different from current user
          contactRepository: contactRepository,
        );

        // The hardened v2 inbound path should allow routing/auth processing
        // even if the test ciphertext cannot be decrypted in this harness.
        expect(
          result,
          isNotNull,
          reason: 'Direct v2 messages from other users should not be dropped',
        );
      },
    );

    test(
      'Should block messages with intendedRecipient not matching current user',
      () async {
        final protocolMessage = buildV2EncryptedTestMessage(
          messageId: 'test_msg_3',
          content: 'ciphertext-for-arshad',
          intendedRecipient: arshadPublicKey,
          senderId: 'some_other_user',
        );

        // Process the message (should be blocked since not intended for Ali)
        final result = await messageHandler.processReceivedData(
          protocolMessageToWireBytes(protocolMessage),
          senderPublicKey: 'some_other_user',
          contactRepository: contactRepository,
        );

        // Should return null (blocked) since it's not intended for current user
        expect(
          result,
          isNull,
          reason: 'Messages intended for other users should be blocked',
        );
      },
    );

    test(
      'Should allow messages with intendedRecipient matching current user',
      () async {
        final protocolMessage = buildV2EncryptedTestMessage(
          messageId: 'test_msg_4',
          content: 'ciphertext-for-ali',
          intendedRecipient: aliPublicKey,
          senderId: arshadPublicKey,
        );

        // Process the message (should be allowed since intended for Ali)
        final result = await messageHandler.processReceivedData(
          protocolMessageToWireBytes(protocolMessage),
          senderPublicKey: arshadPublicKey,
          contactRepository: contactRepository,
        );

        // Should survive routing and security policy checks.
        expect(
          result,
          isNotNull,
          reason: 'Messages intended for current user should be processed',
        );
      },
    );

    tearDown(() async {
      messageHandler.dispose();
      await TestSetup.completeCleanup();
    });
  });
}
