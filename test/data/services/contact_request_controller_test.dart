import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:mockito/mockito.dart';
import 'package:pak_connect/data/services/contact_request_controller.dart';
import 'package:pak_connect/domain/entities/contact.dart';
import 'package:pak_connect/domain/models/security_level.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'ble_messaging_service_test.mocks.dart';

void main() {
  group('ContactRequestController', () {
    late MockContactRepository contactRepository;
    late ContactRequestController controller;
    late String? sessionId;
    late String? otherUserName;
    late String? myUserName;
    late Map<String, String> conversationKeys;
    late List<String> bilateralSyncKeys;

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      resetMockitoState();

      sessionId = 'peer-session';
      otherUserName = 'Peer';
      myUserName = 'Me';
      conversationKeys = <String, String>{};
      bilateralSyncKeys = <String>[];

      contactRepository = MockContactRepository();
      controller = ContactRequestController(
        logger: Logger('ContactRequestControllerTest'),
        contactRepository: contactRepository,
        contactRequestTimeout: const Duration(milliseconds: 30),
        myPersistentIdProvider: () async => 'my-public-key',
        currentSessionIdProvider: () => sessionId,
        otherUserNameProvider: () => otherUserName,
        myUserNameProvider: () => myUserName,
        conversationKeys: conversationKeys,
        markBilateralSyncComplete: bilateralSyncKeys.add,
      );
    });

    test(
      'initiateContactRequest returns false when session context is missing',
      () async {
        sessionId = null;
        expect(await controller.initiateContactRequest(), isFalse);

        sessionId = 'peer-session';
        otherUserName = null;
        expect(await controller.initiateContactRequest(), isFalse);
      },
    );

    test('initiateContactRequest resolves true on accept response', () async {
      sessionId = 'peer-id';
      final sent = <String>[];
      controller.onSendContactRequest = (publicKey, displayName) {
        sent.add('$publicKey|$displayName');
        controller.handleContactRequestAcceptResponse('peer-id', 'Peer');
      };

      final result = await controller.initiateContactRequest();

      expect(result, isTrue);
      expect(sent, ['my-public-key|Me']);
      await untilCalled(contactRepository.markContactVerified('peer-id'));
      verify(
        contactRepository.saveContactWithSecurity(
          'peer-id',
          'Peer',
          SecurityLevel.high,
          currentEphemeralId: null,
          persistentPublicKey: null,
        ),
      ).called(1);
      verify(contactRepository.markContactVerified('peer-id')).called(1);
    });

    test(
      'initiateContactRequest resolves false on rejection response',
      () async {
        controller.onSendContactRequest = (_, _) {
          controller.handleContactRequestRejectResponse();
        };

        final result = await controller.initiateContactRequest();
        expect(result, isFalse);
      },
    );

    test(
      'handleContactRequest auto-rejects when new contacts are disabled',
      () async {
        SharedPreferences.setMockInitialValues({'allow_new_contacts': false});
        var rejected = 0;
        controller.onSendContactReject = () => rejected++;

        await controller.handleContactRequest('their-key', 'Alice');

        expect(rejected, 1);
        expect(controller.hasPendingRequest, isFalse);
      },
    );

    test(
      'handleContactRequest stores pending request and notifies UI',
      () async {
        final received = <String>[];
        controller.onContactRequestReceived = (publicKey, displayName) {
          received.add('$publicKey|$displayName');
        };

        await controller.handleContactRequest('their-key', 'Alice');

        expect(controller.hasPendingRequest, isTrue);
        expect(controller.pendingContactName, 'Alice');
        expect(received, ['their-key|Alice']);
      },
    );

    test(
      'acceptContactRequest no-ops when there is no pending request',
      () async {
        var sentAccept = 0;
        controller.onSendContactAccept = (_, _) => sentAccept++;

        await controller.acceptContactRequest();

        expect(sentAccept, 0);
        verifyNever(contactRepository.saveContactWithSecurity(any, any, any));
      },
    );

    test(
      'acceptContactRequest finalizes contact and clears pending state',
      () async {
        final completed = <bool>[];
        controller.onContactRequestCompleted = completed.add;
        var sentAccept = 0;
        controller.onSendContactAccept = (_, _) => sentAccept++;

        await controller.handleContactRequest('their-key', 'Alice');
        await controller.acceptContactRequest();

        expect(sentAccept, 1);
        expect(controller.hasPendingRequest, isFalse);
        expect(controller.pendingContactName, isNull);
        expect(completed, contains(true));
        expect(bilateralSyncKeys, contains('their-key'));
        verify(
          contactRepository.saveContactWithSecurity(
            'their-key',
            'Alice',
            SecurityLevel.high,
            currentEphemeralId: null,
            persistentPublicKey: null,
          ),
        ).called(1);
        verify(contactRepository.markContactVerified('their-key')).called(1);
      },
    );

    test(
      'rejectContactRequest clears pending state and reports failure',
      () async {
        var rejected = 0;
        final completed = <bool>[];
        controller.onSendContactReject = () => rejected++;
        controller.onContactRequestCompleted = completed.add;

        await controller.handleContactRequest('their-key', 'Alice');
        controller.rejectContactRequest();

        expect(rejected, 1);
        expect(controller.hasPendingRequest, isFalse);
        expect(completed, [false]);
      },
    );

    test('weHaveThemAsContact reflects verified trust status', () async {
      sessionId = null;
      expect(await controller.weHaveThemAsContact, isFalse);

      sessionId = 'peer-id';
      when(contactRepository.getContact('peer-id')).thenAnswer(
        (_) async => Contact(
          publicKey: 'peer-id',
          displayName: 'Peer',
          trustStatus: TrustStatus.newContact,
          securityLevel: SecurityLevel.low,
          firstSeen: DateTime.now(),
          lastSeen: DateTime.now(),
        ),
      );
      expect(await controller.weHaveThemAsContact, isFalse);

      when(contactRepository.getContact('peer-id')).thenAnswer(
        (_) async => Contact(
          publicKey: 'peer-id',
          displayName: 'Peer',
          trustStatus: TrustStatus.verified,
          securityLevel: SecurityLevel.high,
          firstSeen: DateTime.now(),
          lastSeen: DateTime.now(),
        ),
      );
      expect(await controller.weHaveThemAsContact, isTrue);
    });
  });
}
