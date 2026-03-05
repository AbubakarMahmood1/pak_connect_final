import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:pak_connect/domain/interfaces/i_contact_repository.dart';
import 'package:pak_connect/domain/interfaces/i_group_repository.dart';
import 'package:pak_connect/domain/interfaces/i_shared_message_queue_provider.dart';
import 'package:pak_connect/domain/messaging/offline_message_queue_contract.dart';
import 'package:pak_connect/domain/models/contact_group.dart';
import 'package:pak_connect/domain/services/group_messaging_service.dart';
import 'package:pak_connect/domain/values/id_types.dart';
import 'package:pak_connect/presentation/providers/group_providers.dart';

class _FakeGroupRepository implements IGroupRepository {
  final Map<String, ContactGroup> groups = <String, ContactGroup>{};
  final Map<String, GroupMessage> messages = <String, GroupMessage>{};

  @override
  Future<ContactGroup> createGroup(ContactGroup group) async {
    groups[group.id] = group;
    return group;
  }

  @override
  Future<void> deleteGroup(String groupId) async {
    groups.remove(groupId);
  }

  @override
  Future<List<ContactGroup>> getAllGroups() async => groups.values.toList();

  @override
  Future<ContactGroup?> getGroup(String groupId) async => groups[groupId];

  @override
  Future<GroupMessage?> getMessage(String messageId) async =>
      messages[messageId];

  @override
  Future<List<GroupMessage>> getGroupMessages(String groupId, {int limit = 50}) async {
    return messages.values
        .where((message) => message.groupId == groupId)
        .take(limit)
        .toList();
  }

  @override
  Future<List<ContactGroup>> getGroupsForMember(String memberKey) async {
    return groups.values
        .where((group) => group.memberKeys.contains(memberKey))
        .toList();
  }

  @override
  Future<Map<String, int>> getStatistics() async => <String, int>{
    'groups': groups.length,
    'messages': messages.length,
  };

  @override
  Future<void> saveGroupMessage(GroupMessage message) async {
    messages[message.id] = message;
  }

  @override
  Future<void> updateDeliveryStatus(
    String messageId,
    String memberKey,
    MessageDeliveryStatus status,
  ) async {
    final message = messages[messageId];
    if (message == null) {
      return;
    }
    messages[messageId] = message.updateDeliveryStatus(memberKey, status);
  }

  @override
  Future<void> updateGroup(ContactGroup group) async {
    groups[group.id] = group;
  }
}

class _FakeGroupMessagingService extends Fake implements GroupMessagingService {
  final List<GroupMessage> sentMessages = <GroupMessage>[];
  final List<GroupMessage> storedMessages = <GroupMessage>[];
  final Map<String, Map<MessageDeliveryStatus, int>> summaries =
      <String, Map<MessageDeliveryStatus, int>>{};

  int getGroupMessagesCalls = 0;
  MessageId? deliveredMessageId;
  ChatId? deliveredMemberId;
  MessageId? failedMessageId;
  ChatId? failedMemberId;

  @override
  Future<GroupMessage> sendGroupMessage({
    required String groupId,
    required String senderKey,
    required String content,
  }) async {
    final message = GroupMessage(
      id: 'outbound-${sentMessages.length + 1}',
      groupId: groupId,
      senderKey: senderKey,
      content: content,
      timestamp: DateTime(2026, 1, 1, 10, 0),
      deliveryStatus: const <String, MessageDeliveryStatus>{
        'peer-a': MessageDeliveryStatus.sent,
      },
    );
    sentMessages.add(message);
    storedMessages.add(message);
    return message;
  }

  @override
  Future<List<GroupMessage>> getGroupMessages(String groupId, {int limit = 50}) async {
    getGroupMessagesCalls++;
    return storedMessages.where((message) => message.groupId == groupId).toList();
  }

  @override
  Future<GroupMessage?> getMessage(MessageId messageId) async {
    return storedMessages
        .where((message) => message.id == messageId.value)
        .cast<GroupMessage?>()
        .firstWhere((_) => true, orElse: () => null);
  }

  @override
  Future<Map<MessageDeliveryStatus, int>> getDeliverySummary(
    MessageId messageId,
  ) async {
    return summaries[messageId.value] ??
        const <MessageDeliveryStatus, int>{
          MessageDeliveryStatus.sent: 1,
        };
  }

  @override
  Future<void> markDelivered(MessageId messageId, String memberKey) async {}

  @override
  Future<void> markDeliveredForMember(MessageId messageId, ChatId memberId) async {
    deliveredMessageId = messageId;
    deliveredMemberId = memberId;
  }

  @override
  Future<void> markFailed(MessageId messageId, String memberKey) async {}

  @override
  Future<void> markFailedForMember(MessageId messageId, ChatId memberId) async {
    failedMessageId = messageId;
    failedMemberId = memberId;
  }
}

class _FakeOfflineQueue extends Fake implements OfflineMessageQueueContract {}

class _FakeSharedQueueProvider implements ISharedMessageQueueProvider {
  _FakeSharedQueueProvider({required this.isInitialized, required this.queue});

  @override
  final bool isInitialized;

  @override
  bool get isInitializing => false;

  final OfflineMessageQueueContract queue;

  @override
  OfflineMessageQueueContract get messageQueue => queue;

  @override
  Future<void> initialize() async {}
}

class _FakeContactRepository extends Fake implements IContactRepository {}

ContactGroup _group({
  required String id,
  required String name,
  required List<String> members,
}) {
  return ContactGroup(
    id: id,
    name: name,
    memberKeys: members,
    created: DateTime(2026, 1, 1),
    lastModified: DateTime(2026, 1, 1),
  );
}

GroupMessage _groupMessage({required String id, required String groupId}) {
  return GroupMessage(
    id: id,
    groupId: groupId,
    senderKey: 'sender',
    content: 'hello',
    timestamp: DateTime(2026, 1, 1, 9, 0),
    deliveryStatus: const <String, MessageDeliveryStatus>{
      'peer-a': MessageDeliveryStatus.delivered,
    },
  );
}

void main() {
  final locator = GetIt.instance;

  void unregisterIfPresent<T extends Object>() {
    if (locator.isRegistered<T>()) {
      locator.unregister<T>();
    }
  }

  void registerSingleton<T extends Object>(T value) {
    unregisterIfPresent<T>();
    locator.registerSingleton<T>(value);
  }

  setUp(() async {
    await locator.reset();
  });

  tearDown(() async {
    await locator.reset();
  });

  group('group_providers', () {
    test('groupRepositoryProvider resolves repository from service locator', () {
      final repo = _FakeGroupRepository();
      registerSingleton<IGroupRepository>(repo);

      final container = ProviderContainer();
      addTearDown(container.dispose);

      expect(container.read(groupRepositoryProvider), same(repo));
    });

    test('group readers expose repository-backed data', () async {
      final repo = _FakeGroupRepository();
      final g1 = _group(
        id: 'g1',
        name: 'Alpha',
        members: const <String>['alice', 'bob'],
      );
      final g2 = _group(
        id: 'g2',
        name: 'Beta',
        members: const <String>['carol'],
      );
      await repo.createGroup(g1);
      await repo.createGroup(g2);

      final container = ProviderContainer(
        overrides: [groupRepositoryProvider.overrideWithValue(repo)],
      );
      addTearDown(container.dispose);

      final allGroups = await container.read(allGroupsProvider.future);
      final byId = await container.read(groupByIdProvider('g1').future);
      final memberGroups = await container.read(groupsForMemberProvider('alice').future);

      expect(allGroups.length, 2);
      expect(byId?.name, 'Alpha');
      expect(memberGroups.map((group) => group.id), contains('g1'));
    });

    test('create update delete providers mutate repository state', () async {
      final repo = _FakeGroupRepository();
      final container = ProviderContainer(
        overrides: [groupRepositoryProvider.overrideWithValue(repo)],
      );
      addTearDown(container.dispose);

      final createGroup = container.read(createGroupProvider);
      await createGroup(
        name: 'Project',
        memberKeys: const <String>['alice', 'bob'],
        description: 'sync',
      );

      expect(repo.groups.values.single.name, 'Project');

      final created = repo.groups.values.single;
      final updated = created.copyWith(name: 'Project Updated');
      await container.read(updateGroupProvider)(updated);
      expect(repo.groups[created.id]?.name, 'Project Updated');

      await container.read(deleteGroupProvider)(created.id);
      expect(repo.groups, isEmpty);
    });

    test('message providers delegate to group messaging service and invalidate', () async {
      final service = _FakeGroupMessagingService();
      service.storedMessages.add(_groupMessage(id: 'm1', groupId: 'g1'));
      service.summaries['m1'] = const <MessageDeliveryStatus, int>{
        MessageDeliveryStatus.delivered: 1,
      };

      final container = ProviderContainer(
        overrides: [
          groupMessagingServiceProvider.overrideWithValue(service),
        ],
      );
      addTearDown(container.dispose);

      final summarySub = container.listen(
        messageDeliverySummaryProvider('m1'),
        (previous, next) {},
        fireImmediately: true,
      );
      addTearDown(summarySub.close);

      final messagesSub = container.listen(
        groupMessagesProvider('g1'),
        (previous, next) {},
        fireImmediately: true,
      );
      addTearDown(messagesSub.close);

      await Future<void>.delayed(Duration.zero);
      final initialMessageLoads = service.getGroupMessagesCalls;

      final sendMessage = container.read(sendGroupMessageProvider);
      final sent = await sendMessage(
        groupId: 'g1',
        senderKey: 'sender',
        content: 'new message',
      );

      final fetchedMessage = await container.read(groupMessageByIdProvider('m1').future);
      final fetchedSummary = await container.read(
        messageDeliverySummaryProvider('m1').future,
      );

      await container.read(markMessageDeliveredProvider)(
        messageId: 'm1',
        memberKey: 'peer-a',
      );
      await container.read(markMessageFailedProvider)(
        messageId: 'm1',
        memberKey: 'peer-b',
      );
      await Future<void>.delayed(Duration.zero);

      expect(sent.content, 'new message');
      expect(fetchedMessage?.id, 'm1');
      expect(fetchedSummary[MessageDeliveryStatus.delivered], 1);
      expect(service.getGroupMessagesCalls, greaterThan(initialMessageLoads));
      expect(service.deliveredMessageId?.value, 'm1');
      expect(service.deliveredMemberId?.value, 'peer-a');
      expect(service.failedMessageId?.value, 'm1');
      expect(service.failedMemberId?.value, 'peer-b');
    });

    test('groupMessagingServiceProvider validates queue initialization', () {
      registerSingleton<IGroupRepository>(_FakeGroupRepository());
      registerSingleton<IContactRepository>(_FakeContactRepository());
      registerSingleton<ISharedMessageQueueProvider>(
        _FakeSharedQueueProvider(
          isInitialized: false,
          queue: _FakeOfflineQueue(),
        ),
      );

      final container = ProviderContainer();
      addTearDown(container.dispose);

      expect(
        () => container.read(groupMessagingServiceProvider),
        throwsA(
          predicate(
            (error) => error
                .toString()
                .contains('Shared message queue is not initialized'),
          ),
        ),
      );
    });

    test('groupMessagingServiceProvider builds service when queue is ready', () {
      registerSingleton<IGroupRepository>(_FakeGroupRepository());
      registerSingleton<IContactRepository>(_FakeContactRepository());
      registerSingleton<ISharedMessageQueueProvider>(
        _FakeSharedQueueProvider(
          isInitialized: true,
          queue: _FakeOfflineQueue(),
        ),
      );

      final container = ProviderContainer();
      addTearDown(container.dispose);

      final service = container.read(groupMessagingServiceProvider);
      expect(service, isA<GroupMessagingService>());
    });
  });
}







