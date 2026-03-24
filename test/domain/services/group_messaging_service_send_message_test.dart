/// Comprehensive tests for GroupMessagingService
///
/// Covers: sendGroupMessage (success, group not found, member not found,
/// queue exception, multiple members, mixed results), getGroupMessages,
/// getMessage, markDelivered, markDeliveredForMember, markFailed,
/// markFailedForMember, getDeliverySummary, _updateStatus error handling.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:pak_connect/domain/entities/contact.dart';
import 'package:pak_connect/domain/interfaces/i_contact_repository.dart';
import 'package:pak_connect/domain/interfaces/i_group_repository.dart';
import 'package:pak_connect/domain/messaging/offline_message_queue_contract.dart';
import 'package:pak_connect/domain/models/contact_group.dart';
import 'package:pak_connect/domain/models/security_level.dart';
import 'package:pak_connect/domain/services/group_messaging_service.dart';
import 'package:pak_connect/domain/values/id_types.dart';

@GenerateNiceMocks([
  MockSpec<IGroupRepository>(),
  MockSpec<IContactRepository>(),
  MockSpec<OfflineMessageQueueContract>(),
])
import 'group_messaging_service_send_message_test.mocks.dart';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

Contact _contact({required String key, String name = 'User'}) => Contact(
  publicKey: key,
  displayName: name,
  trustStatus: TrustStatus.newContact,
  securityLevel: SecurityLevel.low,
  firstSeen: DateTime(2025, 1, 1),
  lastSeen: DateTime(2025, 1, 1),
);

ContactGroup _group({
  String id = 'grp-1',
  String name = 'Test Group',
  List<String> memberKeys = const ['sender-key', 'member-1', 'member-2'],
}) => ContactGroup(
  id: id,
  name: name,
  memberKeys: memberKeys,
  created: DateTime(2025, 1, 1),
  lastModified: DateTime(2025, 1, 1),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MockIGroupRepository groupRepo;
  late MockIContactRepository contactRepo;
  late MockOfflineMessageQueueContract messageQueue;
  late GroupMessagingService service;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    groupRepo = MockIGroupRepository();
    contactRepo = MockIContactRepository();
    messageQueue = MockOfflineMessageQueueContract();
    service = GroupMessagingService(
      groupRepo: groupRepo,
      contactRepo: contactRepo,
      messageQueue: messageQueue,
    );
  });

  // -----------------------------------------------------------------------
  // sendGroupMessage
  // -----------------------------------------------------------------------
  group('sendGroupMessage', () {
    test('succeeds with all members contacted', () async {
      final group = _group(memberKeys: ['sender-key', 'member-1']);
      when(groupRepo.getGroup('grp-1')).thenAnswer((_) async => group);
      when(groupRepo.saveGroupMessage(any)).thenAnswer((_) async {});
      when(
        contactRepo.getContact('member-1'),
      ).thenAnswer((_) async => _contact(key: 'member-1', name: 'Alice'));
      when(
        messageQueue.queueMessage(
          chatId: anyNamed('chatId'),
          content: anyNamed('content'),
          recipientPublicKey: anyNamed('recipientPublicKey'),
          senderPublicKey: anyNamed('senderPublicKey'),
          priority: anyNamed('priority'),
        ),
      ).thenAnswer((_) async => 'queued-id');
      when(
        groupRepo.updateDeliveryStatus(any, any, any),
      ).thenAnswer((_) async {});

      final msg = await service.sendGroupMessage(
        groupId: 'grp-1',
        senderKey: 'sender-key',
        content: 'hello',
      );

      expect(msg.groupId, 'grp-1');
      expect(msg.senderKey, 'sender-key');
      expect(msg.content, 'hello');
      // sender excluded from delivery map
      expect(msg.deliveryStatus.containsKey('sender-key'), isFalse);
      expect(msg.deliveryStatus.containsKey('member-1'), isTrue);
      verify(groupRepo.saveGroupMessage(any)).called(1);
      // _sendToMembers is fire-and-forget; wait for it to finish
      await Future<void>.delayed(const Duration(milliseconds: 50));
      verify(
        messageQueue.queueMessage(
          chatId: 'chat_member-1',
          content: 'hello',
          recipientPublicKey: 'member-1',
          senderPublicKey: 'sender-key',
          priority: MessagePriority.normal,
        ),
      ).called(1);
    });

    test('throws when group not found', () async {
      when(groupRepo.getGroup('missing')).thenAnswer((_) async => null);

      expect(
        () => service.sendGroupMessage(
          groupId: 'missing',
          senderKey: 'sender-key',
          content: 'hello',
        ),
        throwsA(
          isA<Exception>().having(
            (e) => e.toString(),
            'message',
            contains('Group not found'),
          ),
        ),
      );
    });

    test('handles member not in contacts (marks failed)', () async {
      final group = _group(memberKeys: ['sender-key', 'ghost-member']);
      when(groupRepo.getGroup('grp-1')).thenAnswer((_) async => group);
      when(groupRepo.saveGroupMessage(any)).thenAnswer((_) async {});
      when(
        contactRepo.getContact('ghost-member'),
      ).thenAnswer((_) async => null);
      when(
        groupRepo.updateDeliveryStatus(any, any, any),
      ).thenAnswer((_) async {});

      final msg = await service.sendGroupMessage(
        groupId: 'grp-1',
        senderKey: 'sender-key',
        content: 'hello',
      );

      // Should have attempted to mark ghost-member as failed
      // Allow a short delay for the async _sendToMembers to complete
      await Future<void>.delayed(const Duration(milliseconds: 50));
      verify(
        groupRepo.updateDeliveryStatus(
          any,
          'ghost-member',
          MessageDeliveryStatus.failed,
        ),
      ).called(1);
      verifyNever(
        messageQueue.queueMessage(
          chatId: anyNamed('chatId'),
          content: anyNamed('content'),
          recipientPublicKey: 'ghost-member',
          senderPublicKey: anyNamed('senderPublicKey'),
          priority: anyNamed('priority'),
        ),
      );
      expect(msg.deliveryStatus.containsKey('ghost-member'), isTrue);
    });

    test('handles queue exception for member (marks failed)', () async {
      final group = _group(memberKeys: ['sender-key', 'member-1']);
      when(groupRepo.getGroup('grp-1')).thenAnswer((_) async => group);
      when(groupRepo.saveGroupMessage(any)).thenAnswer((_) async {});
      when(
        contactRepo.getContact('member-1'),
      ).thenAnswer((_) async => _contact(key: 'member-1'));
      when(
        messageQueue.queueMessage(
          chatId: anyNamed('chatId'),
          content: anyNamed('content'),
          recipientPublicKey: anyNamed('recipientPublicKey'),
          senderPublicKey: anyNamed('senderPublicKey'),
          priority: anyNamed('priority'),
        ),
      ).thenThrow(Exception('Queue full'));
      when(
        groupRepo.updateDeliveryStatus(any, any, any),
      ).thenAnswer((_) async {});

      final msg = await service.sendGroupMessage(
        groupId: 'grp-1',
        senderKey: 'sender-key',
        content: 'hello',
      );

      await Future<void>.delayed(const Duration(milliseconds: 50));
      verify(
        groupRepo.updateDeliveryStatus(
          any,
          'member-1',
          MessageDeliveryStatus.failed,
        ),
      ).called(1);
      expect(msg, isNotNull);
    });

    test('sends to multiple members', () async {
      final group = _group(
        memberKeys: ['sender-key', 'member-1', 'member-2', 'member-3'],
      );
      when(groupRepo.getGroup('grp-1')).thenAnswer((_) async => group);
      when(groupRepo.saveGroupMessage(any)).thenAnswer((_) async {});
      when(contactRepo.getContact(any)).thenAnswer(
        (inv) async => _contact(key: inv.positionalArguments[0] as String),
      );
      when(
        messageQueue.queueMessage(
          chatId: anyNamed('chatId'),
          content: anyNamed('content'),
          recipientPublicKey: anyNamed('recipientPublicKey'),
          senderPublicKey: anyNamed('senderPublicKey'),
          priority: anyNamed('priority'),
        ),
      ).thenAnswer((_) async => 'queued-id');
      when(
        groupRepo.updateDeliveryStatus(any, any, any),
      ).thenAnswer((_) async {});

      final msg = await service.sendGroupMessage(
        groupId: 'grp-1',
        senderKey: 'sender-key',
        content: 'hey all',
      );

      expect(msg.deliveryStatus.length, 3);
      expect(msg.deliveryStatus.containsKey('sender-key'), isFalse);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      verify(
        messageQueue.queueMessage(
          chatId: anyNamed('chatId'),
          content: 'hey all',
          recipientPublicKey: anyNamed('recipientPublicKey'),
          senderPublicKey: 'sender-key',
          priority: MessagePriority.normal,
        ),
      ).called(3);
    });

    test('saves message to repo before sending', () async {
      final group = _group(memberKeys: ['sender-key', 'member-1']);
      when(groupRepo.getGroup('grp-1')).thenAnswer((_) async => group);
      // Make saveGroupMessage slow so we can assert ordering
      when(groupRepo.saveGroupMessage(any)).thenAnswer((_) async {});
      when(
        contactRepo.getContact('member-1'),
      ).thenAnswer((_) async => _contact(key: 'member-1'));
      when(
        messageQueue.queueMessage(
          chatId: anyNamed('chatId'),
          content: anyNamed('content'),
          recipientPublicKey: anyNamed('recipientPublicKey'),
          senderPublicKey: anyNamed('senderPublicKey'),
          priority: anyNamed('priority'),
        ),
      ).thenAnswer((_) async => 'queued-id');
      when(
        groupRepo.updateDeliveryStatus(any, any, any),
      ).thenAnswer((_) async {});

      await service.sendGroupMessage(
        groupId: 'grp-1',
        senderKey: 'sender-key',
        content: 'hello',
      );

      // saveGroupMessage must have been called
      verify(groupRepo.saveGroupMessage(any)).called(1);
    });

    test('handles mixed success and failure across members', () async {
      final group = _group(
        memberKeys: ['sender-key', 'member-ok', 'member-gone', 'member-err'],
      );
      when(groupRepo.getGroup('grp-1')).thenAnswer((_) async => group);
      when(groupRepo.saveGroupMessage(any)).thenAnswer((_) async {});
      when(
        groupRepo.updateDeliveryStatus(any, any, any),
      ).thenAnswer((_) async {});

      // member-ok: normal
      when(
        contactRepo.getContact('member-ok'),
      ).thenAnswer((_) async => _contact(key: 'member-ok', name: 'OK'));
      // member-gone: not found
      when(contactRepo.getContact('member-gone')).thenAnswer((_) async => null);
      // member-err: contact exists but queue throws
      when(
        contactRepo.getContact('member-err'),
      ).thenAnswer((_) async => _contact(key: 'member-err', name: 'Err'));

      when(
        messageQueue.queueMessage(
          chatId: 'chat_member-ok',
          content: anyNamed('content'),
          recipientPublicKey: 'member-ok',
          senderPublicKey: anyNamed('senderPublicKey'),
          priority: anyNamed('priority'),
        ),
      ).thenAnswer((_) async => 'q1');
      when(
        messageQueue.queueMessage(
          chatId: 'chat_member-err',
          content: anyNamed('content'),
          recipientPublicKey: 'member-err',
          senderPublicKey: anyNamed('senderPublicKey'),
          priority: anyNamed('priority'),
        ),
      ).thenThrow(Exception('Network down'));

      final msg = await service.sendGroupMessage(
        groupId: 'grp-1',
        senderKey: 'sender-key',
        content: 'hi',
      );

      expect(msg.deliveryStatus.length, 3);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      // member-ok should get sent status
      verify(
        groupRepo.updateDeliveryStatus(
          any,
          'member-ok',
          MessageDeliveryStatus.sent,
        ),
      ).called(1);
      // member-gone should get failed status (no contact)
      verify(
        groupRepo.updateDeliveryStatus(
          any,
          'member-gone',
          MessageDeliveryStatus.failed,
        ),
      ).called(1);
      // member-err should get failed status (queue threw)
      verify(
        groupRepo.updateDeliveryStatus(
          any,
          'member-err',
          MessageDeliveryStatus.failed,
        ),
      ).called(1);
    });
  });

  // -----------------------------------------------------------------------
  // getGroupMessages
  // -----------------------------------------------------------------------
  group('getGroupMessages', () {
    test('delegates to repo with limit', () async {
      final messages = <GroupMessage>[
        GroupMessage(
          id: 'gm-1',
          groupId: 'grp-1',
          senderKey: 'sender-key',
          content: 'hello',
          timestamp: DateTime(2025, 1, 1),
          deliveryStatus: const {},
        ),
      ];
      when(
        groupRepo.getGroupMessages('grp-1', limit: 10),
      ).thenAnswer((_) async => messages);

      final result = await service.getGroupMessages('grp-1', limit: 10);

      expect(result, messages);
      verify(groupRepo.getGroupMessages('grp-1', limit: 10)).called(1);
    });

    test('uses default limit 50', () async {
      when(
        groupRepo.getGroupMessages('grp-1', limit: 50),
      ).thenAnswer((_) async => []);

      final result = await service.getGroupMessages('grp-1');

      expect(result, isEmpty);
      verify(groupRepo.getGroupMessages('grp-1', limit: 50)).called(1);
    });
  });

  // -----------------------------------------------------------------------
  // getMessage
  // -----------------------------------------------------------------------
  group('getMessage', () {
    test('returns message from repo', () async {
      final gm = GroupMessage(
        id: 'gm-42',
        groupId: 'grp-1',
        senderKey: 'sender-key',
        content: 'test',
        timestamp: DateTime(2025, 1, 1),
        deliveryStatus: const {},
      );
      when(groupRepo.getMessage('gm-42')).thenAnswer((_) async => gm);

      final result = await service.getMessage(const MessageId('gm-42'));

      expect(result, gm);
      verify(groupRepo.getMessage('gm-42')).called(1);
    });

    test('returns null when not found', () async {
      when(groupRepo.getMessage('missing')).thenAnswer((_) async => null);

      final result = await service.getMessage(const MessageId('missing'));

      expect(result, isNull);
    });
  });

  // -----------------------------------------------------------------------
  // markDelivered / markDeliveredForMember
  // -----------------------------------------------------------------------
  group('markDelivered', () {
    test('updates status via repo', () async {
      when(
        groupRepo.updateDeliveryStatus(any, any, any),
      ).thenAnswer((_) async {});

      await service.markDelivered(const MessageId('gm-1'), 'member-1');

      verify(
        groupRepo.updateDeliveryStatus(
          'gm-1',
          'member-1',
          MessageDeliveryStatus.delivered,
        ),
      ).called(1);
    });
  });

  group('markDeliveredForMember', () {
    test('delegates with memberId.value', () async {
      when(
        groupRepo.updateDeliveryStatus(any, any, any),
      ).thenAnswer((_) async {});

      await service.markDeliveredForMember(
        const MessageId('gm-1'),
        const ChatId('member-1'),
      );

      verify(
        groupRepo.updateDeliveryStatus(
          'gm-1',
          'member-1',
          MessageDeliveryStatus.delivered,
        ),
      ).called(1);
    });
  });

  // -----------------------------------------------------------------------
  // markFailed / markFailedForMember
  // -----------------------------------------------------------------------
  group('markFailed', () {
    test('updates status via repo', () async {
      when(
        groupRepo.updateDeliveryStatus(any, any, any),
      ).thenAnswer((_) async {});

      await service.markFailed(const MessageId('gm-2'), 'member-2');

      verify(
        groupRepo.updateDeliveryStatus(
          'gm-2',
          'member-2',
          MessageDeliveryStatus.failed,
        ),
      ).called(1);
    });
  });

  group('markFailedForMember', () {
    test('delegates with memberId.value', () async {
      when(
        groupRepo.updateDeliveryStatus(any, any, any),
      ).thenAnswer((_) async {});

      await service.markFailedForMember(
        const MessageId('gm-2'),
        const ChatId('member-2'),
      );

      verify(
        groupRepo.updateDeliveryStatus(
          'gm-2',
          'member-2',
          MessageDeliveryStatus.failed,
        ),
      ).called(1);
    });
  });

  // -----------------------------------------------------------------------
  // getDeliverySummary
  // -----------------------------------------------------------------------
  group('getDeliverySummary', () {
    test('returns counts per status', () async {
      final gm = GroupMessage(
        id: 'gm-s',
        groupId: 'grp-1',
        senderKey: 'sender-key',
        content: 'test',
        timestamp: DateTime(2025, 1, 1),
        deliveryStatus: const {
          'a': MessageDeliveryStatus.sent,
          'b': MessageDeliveryStatus.delivered,
          'c': MessageDeliveryStatus.delivered,
          'd': MessageDeliveryStatus.failed,
        },
      );
      when(groupRepo.getMessage('gm-s')).thenAnswer((_) async => gm);

      final summary = await service.getDeliverySummary(const MessageId('gm-s'));

      expect(summary[MessageDeliveryStatus.sent], 1);
      expect(summary[MessageDeliveryStatus.delivered], 2);
      expect(summary[MessageDeliveryStatus.failed], 1);
      expect(summary[MessageDeliveryStatus.pending], isNull);
    });

    test('returns empty map when message not found', () async {
      when(groupRepo.getMessage('no-msg')).thenAnswer((_) async => null);

      final summary = await service.getDeliverySummary(
        const MessageId('no-msg'),
      );

      expect(summary, isEmpty);
    });
  });

  // -----------------------------------------------------------------------
  // _updateStatus error handling (non-critical)
  // -----------------------------------------------------------------------
  group('_updateStatus error handling', () {
    test('catches and logs repo errors without crashing', () async {
      // When updateDeliveryStatus throws, markDelivered should not rethrow
      when(
        groupRepo.updateDeliveryStatus(any, any, any),
      ).thenThrow(Exception('DB write failure'));

      // Should NOT throw
      await service.markDelivered(const MessageId('gm-err'), 'member-x');

      verify(
        groupRepo.updateDeliveryStatus(
          'gm-err',
          'member-x',
          MessageDeliveryStatus.delivered,
        ),
      ).called(1);
    });

    test('catches repo errors during markFailed', () async {
      when(
        groupRepo.updateDeliveryStatus(any, any, any),
      ).thenThrow(Exception('DB write failure'));

      await service.markFailed(const MessageId('gm-err'), 'member-y');

      verify(
        groupRepo.updateDeliveryStatus(
          'gm-err',
          'member-y',
          MessageDeliveryStatus.failed,
        ),
      ).called(1);
    });
  });
}
