import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';

import 'package:pak_connect/data/repositories/contact_repository.dart';
import 'package:pak_connect/data/services/contact_status_sync_controller.dart';
import 'package:pak_connect/domain/models/protocol_message.dart';
import 'package:pak_connect/domain/models/security_level.dart';

void main() {
  group('ContactStatusSyncController', () {
    late _FakeContactRepository repository;
    late List<ProtocolMessage> sentMessages;
    late List<String> promptedKeys;
    late List<String> asymmetricKeys;
    late int contactCompletedCount;
    late bool weHaveThem;
    late String? currentSessionId;
    late ContactStatusSyncController controller;

    setUp(() {
      repository = _FakeContactRepository();
      sentMessages = <ProtocolMessage>[];
      promptedKeys = <String>[];
      asymmetricKeys = <String>[];
      contactCompletedCount = 0;
      weHaveThem = false;
      currentSessionId = 'peer_public_key';

      controller =
          ContactStatusSyncController(
              logger: Logger('ContactStatusSyncControllerTest'),
              contactRepository: repository,
              myPersistentIdProvider: () async => 'my_persistent_key',
              weHaveThemAsContactProvider: () async => weHaveThem,
              currentSessionIdProvider: () => currentSessionId,
              triggerMutualConsentPrompt: promptedKeys.add,
              statusCooldown: Duration.zero,
            )
            ..onAsymmetricContactDetected = (publicKey, _) {
              asymmetricKeys.add(publicKey);
            }
            ..onContactRequestCompleted = (_) {
              contactCompletedCount++;
            }
            ..onSendContactStatus = sentMessages.add;
    });

    tearDown(() {
      controller.dispose();
    });

    test(
      'updateTheirContactClaim updates status and only notifies on change',
      () {
        expect(controller.theyHaveUsAsContact, isFalse);

        controller.updateTheirContactClaim(true);
        expect(controller.theyHaveUsAsContact, isTrue);
        expect(contactCompletedCount, 1);

        controller.updateTheirContactClaim(true);
        expect(contactCompletedCount, 1);

        controller.updateTheirContactClaim(false);
        expect(controller.theyHaveUsAsContact, isFalse);
        expect(contactCompletedCount, 2);
      },
    );

    test('requestContactStatusExchange sends only when changed', () async {
      weHaveThem = false;

      await controller.requestContactStatusExchange();
      expect(sentMessages, hasLength(1));
      expect(sentMessages.first.payload['hasAsContact'], isFalse);
      expect(sentMessages.first.payload['publicKey'], 'my_persistent_key');

      await controller.requestContactStatusExchange();
      expect(sentMessages, hasLength(1));

      weHaveThem = true;
      await controller.requestContactStatusExchange();
      expect(sentMessages, hasLength(2));
      expect(sentMessages.last.payload['hasAsContact'], isTrue);
    });

    test(
      'requestContactStatusExchange handles missing session and provider errors',
      () async {
        currentSessionId = null;
        await controller.requestContactStatusExchange();
        expect(sentMessages, isEmpty);

        controller = ContactStatusSyncController(
          logger: Logger('ContactStatusSyncControllerTestError'),
          contactRepository: repository,
          myPersistentIdProvider: () async => 'my_persistent_key',
          weHaveThemAsContactProvider: () async => throw StateError('boom'),
          currentSessionIdProvider: () => 'peer_public_key',
          triggerMutualConsentPrompt: promptedKeys.add,
        )..onSendContactStatus = sentMessages.add;

        await controller.requestContactStatusExchange();
        expect(sentMessages, isEmpty);
      },
    );

    test(
      'handleContactStatus processes first change and ignores duplicate',
      () async {
        weHaveThem = false;

        await controller.handleContactStatus(true, 'peer_public_key');
        expect(controller.theyHaveUsAsContact, isTrue);
        expect(sentMessages, hasLength(1));
        expect(asymmetricKeys, ['peer_public_key']);
        expect(promptedKeys, ['peer_public_key']);
        expect(contactCompletedCount, 1);

        await controller.handleContactStatus(true, 'peer_public_key');
        expect(sentMessages, hasLength(1));
        expect(asymmetricKeys, ['peer_public_key']);
        expect(promptedKeys, ['peer_public_key']);
        expect(contactCompletedCount, 1);
      },
    );

    test(
      'bilateral false-false marks sync complete and suppresses further sends',
      () async {
        weHaveThem = false;

        await controller.handleContactStatus(false, 'peer_public_key');
        expect(sentMessages, hasLength(1));
        expect(sentMessages.single.payload['hasAsContact'], isFalse);

        await controller.handleContactStatus(true, 'peer_public_key');
        expect(sentMessages, hasLength(1));
        expect(asymmetricKeys, ['peer_public_key']);
      },
    );

    test(
      'resetBilateralSyncStatus re-opens sync flow and allows fresh send',
      () async {
        weHaveThem = false;

        await controller.handleContactStatus(false, 'peer_public_key');
        expect(sentMessages, hasLength(1));

        controller.resetBilateralSyncStatus('peer_public_key');
        await controller.handleContactStatus(true, 'peer_public_key');

        expect(sentMessages, hasLength(2));
        expect(promptedKeys.length, greaterThanOrEqualTo(1));
      },
    );

    test(
      'initializeContactFlags is safe with and without active session',
      () async {
        currentSessionId = null;
        await controller.initializeContactFlags();
        expect(sentMessages, isEmpty);

        currentSessionId = 'peer_public_key';
        await controller.initializeContactFlags();
        expect(sentMessages, hasLength(1));
      },
    );

    test('markBilateralSyncComplete bypasses bilateral sync sends', () async {
      controller.markBilateralSyncComplete('peer_public_key');
      await controller.handleContactStatus(true, 'peer_public_key');

      expect(sentMessages, isEmpty);
      expect(asymmetricKeys, ['peer_public_key']);
    });

    test('reset clears state and allows fresh state transitions', () {
      controller.updateTheirContactClaim(true);
      expect(controller.theyHaveUsAsContact, isTrue);

      controller.reset();
      expect(controller.theyHaveUsAsContact, isFalse);

      controller.updateTheirContactClaim(true);
      expect(contactCompletedCount, 2);
    });

    test('dispose is safe after initialization paths', () async {
      await controller.initializeContactFlags();
      controller.dispose();

      expect(() => controller.dispose(), returnsNormally);
    });
  });
}

class _FakeContactRepository extends ContactRepository {
  String? cachedSecret;
  SecurityLevel level = SecurityLevel.low;

  @override
  Future<void> cacheSharedSecret(String publicKey, String sharedSecret) async {
    cachedSecret = sharedSecret;
  }

  @override
  Future<String?> getCachedSharedSecret(String publicKey) async {
    return cachedSecret;
  }

  @override
  Future<SecurityLevel> getContactSecurityLevel(String publicKey) async {
    return level;
  }

  @override
  Future<void> updateContactSecurityLevel(
    String publicKey,
    SecurityLevel securityLevel,
  ) async {
    level = securityLevel;
  }
}
