import 'package:flutter_test/flutter_test.dart';
import 'package:pak_connect/domain/interfaces/i_preferences_repository.dart';
import 'package:pak_connect/domain/interfaces/i_user_preferences.dart';
import 'package:pak_connect/domain/messaging/offline_message_queue_contract.dart';
import 'package:pak_connect/domain/services/message_router.dart';
import 'package:pak_connect/domain/values/id_types.dart';
import '../../test_helpers/mocks/mock_connection_service.dart';

void main() {
  group('MessageRouter fallback queue', () {
    test(
      'supports queue lifecycle, delivery callbacks, and sync helpers',
      () async {
        MessageRouter.configureQueueFactories(
          standaloneQueueFactory: null,
          initializedQueueFactory: null,
        );
        MessageRouter.clearDependencyResolvers();

        final queue = MessageRouter.createStandaloneQueue();

        final sentMessageIds = <String>[];
        var connectivityChecks = 0;
        QueuedMessage? queuedEvent;
        QueuedMessage? deliveredEvent;
        String? failedReason;
        QueueStatistics? latestStats;

        await queue.initialize(
          onMessageQueued: (message) => queuedEvent = message,
          onMessageDelivered: (message) => deliveredEvent = message,
          onMessageFailed: (message, reason) => failedReason = reason,
          onStatsUpdated: (stats) => latestStats = stats,
          onSendMessage: (messageId) => sentMessageIds.add(messageId),
          onConnectivityCheck: () => connectivityChecks++,
        );

        final id1 = await queue.queueMessage(
          chatId: 'chat_1',
          content: 'hello peer1',
          recipientPublicKey: 'peer_1',
          senderPublicKey: 'sender',
          priority: MessagePriority.high,
        );

        final id2 = (await queue.queueMessageWithIds(
          chatId: const ChatId('chat_2'),
          content: 'hello peer2',
          recipientId: const ChatId('peer_2'),
          senderId: const ChatId('sender'),
          priority: MessagePriority.normal,
        )).value;

        expect(queuedEvent, isNotNull);
        expect(queue.getPendingMessages().length, 2);
        expect(queue.getStatistics().pendingMessages, 2);
        expect(latestStats, isNotNull);

        await queue.setOnline();
        expect(connectivityChecks, 1);

        await queue.flushQueueForPeer('peer_1');
        expect(sentMessageIds, contains(id1));

        await queue.markMessageFailed(id2, 'network');
        expect(queue.getMessagesByStatus(QueuedMessageStatus.failed).length, 1);
        expect(failedReason, 'network');

        await queue.retryFailedMessages();
        expect(
          queue
              .getMessagesByStatus(QueuedMessageStatus.pending)
              .any((message) => message.id == id2),
          isTrue,
        );

        await queue.markMessageDelivered(id1);
        expect(queue.getMessageById(id1), isNull);
        expect(deliveredEvent?.id, id1);

        expect(await queue.changePriority(id2, MessagePriority.urgent), isTrue);
        expect(
          await queue.changePriority('missing-id', MessagePriority.low),
          isFalse,
        );

        final syncMessage = queue.createSyncMessage('node_1');
        expect(syncMessage.messageIds, isNotEmpty);

        final localIds = queue.getPendingMessages().map(
          (message) => message.id,
        );
        final missingIds = queue.getMissingMessageIds(<String>[
          ...localIds,
          'remote_only',
        ]);
        expect(missingIds, contains('remote_only'));

        final excess = queue.getExcessMessages(const <String>['some_other_id']);
        expect(excess, isNotEmpty);

        final additionalSynced = QueuedMessage(
          id: 'synced_message',
          chatId: 'chat_sync',
          content: 'synced content',
          recipientPublicKey: 'peer_sync',
          senderPublicKey: 'sender',
          priority: MessagePriority.low,
          queuedAt: DateTime.now(),
          maxRetries: 5,
        );
        await queue.addSyncedMessage(additionalSynced);
        expect(queue.getMessageById('synced_message'), isNotNull);

        await queue.markMessageDeleted('synced_message');
        expect(queue.isMessageDeleted('synced_message'), isTrue);

        await queue.addSyncedMessage(additionalSynced);
        expect(queue.getMessageById('synced_message'), isNull);

        final hash = queue.calculateQueueHash();
        expect(queue.needsSynchronization(hash), isFalse);
        expect(queue.needsSynchronization('$hash-remote'), isTrue);

        final removed = await queue.removeMessagesForChat('chat_2');
        expect(removed, greaterThanOrEqualTo(0));

        await queue.removeMessage(id2);
        await queue.retryFailedMessagesForChat('chat_2');
        await queue.cleanupOldDeletedIds();
        queue.invalidateHashCache();

        final perf = queue.getPerformanceStats();
        expect(perf['isOnline'], isTrue);
        expect(perf['deletedIdsCount'], greaterThanOrEqualTo(1));

        await queue.clearQueue();
        expect(queue.getPendingMessages(), isEmpty);
        expect(queue.getStatistics().pendingMessages, 0);

        queue.dispose();
      },
    );
  });

  group('MessageRouter singleton', () {
    test(
      'initializes once, handles missing preferences, and routes via fallback queue',
      () async {
        MessageRouter.configureQueueFactories(
          standaloneQueueFactory: null,
          initializedQueueFactory: null,
        );
        MessageRouter.clearDependencyResolvers();

        final connectionService = MockConnectionService();
        final preferences = _MemoryPreferencesRepository(<String, dynamic>{
          'public_key': 'sender_pub_key',
        });

        expect(MessageRouter.maybeInstance, isNull);

        await MessageRouter.initialize(connectionService);
        final router = MessageRouter.instance;
        expect(MessageRouter.maybeInstance, same(router));

        final failed = await router.sendMessage(
          content: 'hello',
          recipientId: 'peer_a',
        );
        expect(failed.status, MessageRouteStatus.failed);
        expect(failed.isSuccess, isFalse);

        MessageRouter.configureDependencyResolvers(
          // ignore: deprecated_member_use
          preferencesRepositoryResolver: () => preferences,
          userPreferencesResolver: () => _FakeUserPreferences('sender_pub_key'),
        );

        final queued = await router.sendMessage(
          content: 'hello again',
          recipientId: 'peer_a',
        );
        expect(queued.status, MessageRouteStatus.queued);
        expect(queued.isQueued, isTrue);

        final typedQueued = await router.sendMessageWithIds(
          content: 'typed ids',
          recipientId: const ChatId('peer_b'),
          messageId: const MessageId('msg_typed'),
        );
        expect(typedQueued.isQueued, isTrue);
        expect(typedQueued.messageIdValue, MessageId(typedQueued.messageId));

        router.offlineQueue.onSendMessage = (_) {};
        await router.offlineQueue.setOnline();
        await router.flushOutboxFor('peer_a');
        await router.flushOutboxForId(const ChatId('peer_b'));
        await router.flushAllOutbox();

        final stats = router.getStatistics();
        expect(stats['delegatedToOfflineQueue'], isTrue);
        expect(stats['currentQueueSize'], greaterThanOrEqualTo(0));
        expect(router.getTotalQueuedMessages(), greaterThanOrEqualTo(0));

        await router.clearAll();
        expect(router.getTotalQueuedMessages(), 0);

        // Covers the already-initialized guard.
        await MessageRouter.initialize(
          connectionService,
          preferencesRepository: preferences,
        );
        expect(MessageRouter.instance, same(router));

        router.dispose();
      },
    );
  });

  group('MessageRouteResult helpers', () {
    test('typed and untyped factories map status and flags consistently', () {
      final direct = MessageRouteResult.sentDirectly('msg_1');
      final queued = MessageRouteResult.queuedId(const MessageId('msg_2'));
      final failed = MessageRouteResult.failedId(
        const MessageId('msg_3'),
        'boom',
      );

      expect(direct.isSentDirectly, isTrue);
      expect(direct.isSuccess, isTrue);

      expect(queued.isQueued, isTrue);
      expect(queued.messageIdValue, const MessageId('msg_2'));

      expect(failed.isSuccess, isFalse);
      expect(failed.errorMessage, 'boom');
    });
  });
}

class _MemoryPreferencesRepository implements IPreferencesRepository {
  final Map<String, dynamic> _store;

  _MemoryPreferencesRepository([Map<String, dynamic>? initial])
    : _store = <String, dynamic>{...?initial};

  @override
  Future<void> clearAll() async => _store.clear();

  @override
  Future<void> delete(String key) async => _store.remove(key);

  @override
  Future<Map<String, dynamic>> getAll() async =>
      Map<String, dynamic>.from(_store);

  @override
  Future<bool> getBool(String key, {bool? defaultValue}) async =>
      (_store[key] as bool?) ?? (defaultValue ?? false);

  @override
  Future<double> getDouble(String key, {double? defaultValue}) async =>
      (_store[key] as double?) ?? (defaultValue ?? 0.0);

  @override
  Future<int> getInt(String key, {int? defaultValue}) async =>
      (_store[key] as int?) ?? (defaultValue ?? 0);

  @override
  Future<String> getString(String key, {String? defaultValue}) async =>
      (_store[key] as String?) ?? (defaultValue ?? '');

  @override
  Future<void> setBool(String key, bool value) async {
    _store[key] = value;
  }

  @override
  Future<void> setDouble(String key, double value) async {
    _store[key] = value;
  }

  @override
  Future<void> setInt(String key, int value) async {
    _store[key] = value;
  }

  @override
  Future<void> setString(String key, String value) async {
    _store[key] = value;
  }
}

class _FakeUserPreferences implements IUserPreferences {
  final String _publicKey;
  _FakeUserPreferences(this._publicKey);

  @override
  Future<String> getPublicKey() async => _publicKey;

  @override
  Future<String> getPrivateKey() async => '';

  @override
  Future<String> getUserName() async => 'test';

  @override
  Future<void> setUserName(String name) async {}

  @override
  Future<String> getOrCreateDeviceId() async => 'device-id';

  @override
  Future<String?> getDeviceId() async => 'device-id';

  @override
  Future<Map<String, String>> getOrCreateKeyPair() async =>
      {'publicKey': _publicKey, 'privateKey': ''};

  @override
  Future<bool> getHintBroadcastEnabled() async => true;

  @override
  Future<void> setHintBroadcastEnabled(bool enabled) async {}

  @override
  Future<void> regenerateKeyPair() async {}
}
