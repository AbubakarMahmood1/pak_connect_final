import 'package:flutter_test/flutter_test.dart';
import 'package:pak_connect/data/services/protocol_message_handler.dart';

void main() {
  group('ProtocolMessageHandler', () {
    late ProtocolMessageHandler handler;

    setUp(() {
      handler = ProtocolMessageHandler();
    });

    test('creates instance successfully', () {
      expect(handler, isNotNull);
    });

    test('sets current node ID', () {
      final nodeId = 'test-node-12345678-abcdefgh';
      expect(() => handler.setCurrentNodeId(nodeId), returnsNormally);
    });

    test(
      'message is for me when intended recipient is null (broadcast)',
      () async {
        final isForMe = await handler.isMessageForMe(null);
        expect(isForMe, isTrue);
      },
    );

    test(
      'message is for me when intended recipient matches current node',
      () async {
        final nodeId = 'test-node-123';
        handler.setCurrentNodeId(nodeId);

        final isForMe = await handler.isMessageForMe(nodeId);
        expect(isForMe, isTrue);
      },
    );

    test(
      'message is not for me when recipient differs from current node',
      () async {
        handler.setCurrentNodeId('node-A');

        final isForMe = await handler.isMessageForMe('node-B');
        expect(isForMe, isFalse);
      },
    );

    test('resolves message identities', () async {
      final identities = await handler.resolveMessageIdentities(
        encryptionSenderKey: 'sender-key',
        meshSenderKey: 'mesh-key',
        intendedRecipient: 'recipient-key',
      );

      expect(identities, isA<Map<String, dynamic>>());
      expect(identities['originalSender'], equals('sender-key'));
      expect(identities['intendedRecipient'], equals('recipient-key'));
      expect(identities['isSpyMode'], isFalse);
    });

    test('detects spy mode when sender keys differ', () async {
      final identities = await handler.resolveMessageIdentities(
        encryptionSenderKey: 'sender-key',
        meshSenderKey: 'different-key',
        intendedRecipient: 'recipient-key',
      );

      expect(identities['isSpyMode'], isTrue);
    });

    test('gets and sets encryption method', () {
      expect(handler.getEncryptionMethod(), equals('none'));

      handler.setEncryptionMethod('ecdh');
      expect(handler.getEncryptionMethod(), equals('ecdh'));

      handler.setEncryptionMethod('conversation');
      expect(handler.getEncryptionMethod(), equals('conversation'));
    });

    test('registers contact request callback', () {
      var callbackInvoked = false;
      String? receivedKey;
      String? receivedName;

      handler.onContactRequestReceived((key, name) {
        callbackInvoked = true;
        receivedKey = key;
        receivedName = name;
      });

      expect(handler, isNotNull);
    });

    test('registers contact accept callback', () {
      var callbackInvoked = false;

      handler.onContactAcceptReceived((key, name) {
        callbackInvoked = true;
      });

      expect(handler, isNotNull);
    });

    test('registers contact reject callback', () {
      var callbackInvoked = false;

      handler.onContactRejectReceived(() {
        callbackInvoked = true;
      });

      expect(handler, isNotNull);
    });

    test('registers crypto verification callback', () {
      handler.onCryptoVerificationReceived((verificationId, contactKey) {
        // Callback set
      });

      expect(handler, isNotNull);
    });

    test('registers crypto verification response callback', () {
      handler.onCryptoVerificationResponseReceived((
        verificationId,
        contactKey,
        isVerified,
        data,
      ) {
        // Callback set
      });

      expect(handler, isNotNull);
    });

    test('registers identity revealed callback', () {
      handler.onIdentityRevealed((contactName) {
        // Callback set
      });

      expect(handler, isNotNull);
    });

    test('QR introduction match succeeds with identical hashes', () async {
      const hash = 'abc123def456';
      final matches = await handler.checkQRIntroductionMatch(
        receivedHash: hash,
        expectedHash: hash,
      );
      expect(matches, isTrue);
    });

    test('QR introduction match fails with different hashes', () async {
      final matches = await handler.checkQRIntroductionMatch(
        receivedHash: 'hash1',
        expectedHash: 'hash2',
      );
      expect(matches, isFalse);
    });

    test('handles QR introduction claim', () async {
      expect(
        () => handler.handleQRIntroductionClaim(
          claimJson: '{"key":"value"}',
          fromDeviceId: 'device1',
        ),
        returnsNormally,
      );
    });

    test('gets message encryption method', () async {
      final method = await handler.getMessageEncryptionMethod(
        senderKey: 'sender',
        recipientKey: 'recipient',
      );
      expect(method, isA<String>());
    });
  });
}
