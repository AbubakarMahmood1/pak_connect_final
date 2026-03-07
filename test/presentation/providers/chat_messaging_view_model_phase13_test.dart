/// Phase 13: Supplementary tests for ChatMessagingViewModel
/// Covers uncovered lines: _mapQueuedStatus all branches,
///   loadMessages dedup/merge/sort, loadMessages error path,
///   sendMessage empty-content guard, sendMessage empty-recipient guard,
///   sendMessage _queueSecureMessage error (no provider),
///   sendMessage _queueSecureMessage error (empty sender key),
///   retryMessage success + error, deleteMessage local-only success,
///   deleteMessage returns-false path, deleteMessage error path,
///   addReceivedMessage duplicate detection, setupMessageListener,
///   updateRecipientKey no-op on same key / empty key,
///   _logMessageSendState error fallback
import 'package:flutter_test/flutter_test.dart';

import 'package:pak_connect/domain/entities/contact.dart';
import 'package:pak_connect/domain/entities/message.dart';
import 'package:pak_connect/domain/interfaces/i_contact_repository.dart';
import 'package:pak_connect/domain/interfaces/i_message_repository.dart';
import 'package:pak_connect/domain/interfaces/i_security_service.dart';
import 'package:pak_connect/domain/interfaces/i_shared_message_queue_provider.dart';
import 'package:pak_connect/domain/interfaces/i_user_preferences.dart';
import 'package:pak_connect/domain/messaging/offline_message_queue_contract.dart';
import 'package:pak_connect/domain/models/encryption_method.dart';
import 'package:pak_connect/domain/models/mesh_relay_models.dart';
import 'package:pak_connect/domain/models/security_level.dart';
import 'package:pak_connect/domain/values/id_types.dart';
import 'package:pak_connect/presentation/providers/chat_messaging_view_model.dart';

void main() {
  group('ChatMessagingViewModel – _mapQueuedStatus branches', () {
    test('loadMessages maps QueuedMessageStatus.awaitingAck to sending',
        () async {
      final vm = _buildViewModel();
      final queued = [
        _queuedMessage(id: 'q1', status: QueuedMessageStatus.awaitingAck),
      ];
      final result =
          await vm.loadMessages(onGetQueuedMessages: () => queued);
      expect(result.first.status, MessageStatus.sending);
    });

    test('loadMessages maps QueuedMessageStatus.retrying to sending',
        () async {
      final vm = _buildViewModel();
      final queued = [
        _queuedMessage(id: 'q2', status: QueuedMessageStatus.retrying),
      ];
      final result =
          await vm.loadMessages(onGetQueuedMessages: () => queued);
      expect(result.first.status, MessageStatus.sending);
    });

    test('loadMessages maps QueuedMessageStatus.failed to failed', () async {
      final vm = _buildViewModel();
      final queued = [
        _queuedMessage(id: 'q3', status: QueuedMessageStatus.failed),
      ];
      final result =
          await vm.loadMessages(onGetQueuedMessages: () => queued);
      expect(result.first.status, MessageStatus.failed);
    });

    test('loadMessages maps QueuedMessageStatus.delivered to delivered',
        () async {
      final vm = _buildViewModel();
      final queued = [
        _queuedMessage(id: 'q4', status: QueuedMessageStatus.delivered),
      ];
      final result =
          await vm.loadMessages(onGetQueuedMessages: () => queued);
      expect(result.first.status, MessageStatus.delivered);
    });

    test('loadMessages maps QueuedMessageStatus.sending to sending', () async {
      final vm = _buildViewModel();
      final queued = [
        _queuedMessage(id: 'q5', status: QueuedMessageStatus.sending),
      ];
      final result =
          await vm.loadMessages(onGetQueuedMessages: () => queued);
      expect(result.first.status, MessageStatus.sending);
    });

    test('loadMessages maps QueuedMessageStatus.pending to sending', () async {
      final vm = _buildViewModel();
      final queued = [
        _queuedMessage(id: 'q6', status: QueuedMessageStatus.pending),
      ];
      final result =
          await vm.loadMessages(onGetQueuedMessages: () => queued);
      expect(result.first.status, MessageStatus.sending);
    });
  });

  group('ChatMessagingViewModel – loadMessages dedup/merge/sort', () {
    test('deduplicates when queue and repo share message IDs', () async {
      final repo = _FakeMessageRepository();
      repo.messages = [
        _msg(id: 'shared-1', chatId: 'chat-1', time: DateTime(2025, 1, 1)),
      ];
      final vm = _buildViewModel(messageRepository: repo);

      final queued = [
        _queuedMessage(id: 'shared-1', status: QueuedMessageStatus.pending),
        _queuedMessage(id: 'unique-q', status: QueuedMessageStatus.pending),
      ];

      final result =
          await vm.loadMessages(onGetQueuedMessages: () => queued);
      // shared-1 from repo + unique-q from queue = 2 total
      expect(result.length, 2);
      final ids = result.map((m) => m.id.value).toList();
      expect(ids, contains('shared-1'));
      expect(ids, contains('unique-q'));
    });

    test('sorts merged messages by timestamp ascending', () async {
      final repo = _FakeMessageRepository();
      repo.messages = [
        _msg(id: 'm2', chatId: 'chat-1', time: DateTime(2025, 3, 1)),
        _msg(id: 'm1', chatId: 'chat-1', time: DateTime(2025, 1, 1)),
      ];
      final vm = _buildViewModel(messageRepository: repo);
      final queued = [
        _queuedMessage(
          id: 'q1',
          status: QueuedMessageStatus.pending,
          queuedAt: DateTime(2025, 2, 1),
        ),
      ];

      final result =
          await vm.loadMessages(onGetQueuedMessages: () => queued);
      expect(result.length, 3);
      expect(result[0].id.value, 'm1');
      expect(result[1].id.value, 'q1');
      expect(result[2].id.value, 'm2');
    });

    test('calls onScrollToBottom and onLoadingStateChanged', () async {
      final vm = _buildViewModel();
      bool scrollCalled = false;
      final loadingStates = <bool>[];

      await vm.loadMessages(
        onScrollToBottom: () => scrollCalled = true,
        onLoadingStateChanged: (v) => loadingStates.add(v),
      );

      expect(scrollCalled, isTrue);
      expect(loadingStates, [true, false]);
    });
  });

  group('ChatMessagingViewModel – loadMessages error path', () {
    test('error calls onError and onLoadingStateChanged(false)', () async {
      final repo = _FakeMessageRepository()..shouldThrowOnGet = true;
      final vm = _buildViewModel(messageRepository: repo);
      String? errorMsg;
      final loadingStates = <bool>[];

      await expectLater(
        vm.loadMessages(
          onError: (msg) => errorMsg = msg,
          onLoadingStateChanged: (v) => loadingStates.add(v),
        ),
        throwsException,
      );

      expect(errorMsg, isNotNull);
      expect(errorMsg, contains('Failed to load'));
      // true then false on error
      expect(loadingStates, [true, false]);
    });
  });

  group('ChatMessagingViewModel – sendMessage guards', () {
    test('empty content is a no-op', () async {
      final queue = _FakeOfflineQueue();
      final qp = _FakeSharedMessageQueueProvider(queue);
      final vm = _buildViewModel(queueProvider: qp);

      await vm.sendMessage(content: '   ');
      expect(queue.queueMessageCalls, 0);
    });

    test('empty contactPublicKey calls onShowError', () async {
      final queue = _FakeOfflineQueue();
      final qp = _FakeSharedMessageQueueProvider(queue);
      final vm = _buildViewModel(
        queueProvider: qp,
        contactPublicKey: '',
      );

      String? errorMsg;
      await vm.sendMessage(
        content: 'hello',
        onShowError: (msg) => errorMsg = msg,
      );
      expect(errorMsg, contains('Connection not ready'));
      expect(queue.queueMessageCalls, 0);
    });
  });

  group('ChatMessagingViewModel – sendMessage queue errors', () {
    test('throws when sender public key is empty', () async {
      final queue = _FakeOfflineQueue();
      final qp = _FakeSharedMessageQueueProvider(queue);
      final prefs = _FakeUserPreferences()..publicKey = '';
      final contactRepo = _FakeContactRepository()
        ..contact = _contact(publicKey: 'pk1');
      final vm = _buildViewModel(
        contactRepository: contactRepo,
        queueProvider: qp,
        userPreferences: prefs,
        contactPublicKey: 'pk1',
      );

      String? errorMsg;
      await expectLater(
        vm.sendMessage(
          content: 'test',
          onShowError: (msg) => errorMsg = msg,
        ),
        throwsA(isA<StateError>()),
      );
      expect(errorMsg, contains('Failed to send'));
    });
  });

  group('ChatMessagingViewModel – sendMessage invokes onMessageAdded', () {
    test('successful send calls onMessageAdded and saves message', () async {
      final repo = _FakeMessageRepository();
      final contactRepo = _FakeContactRepository()
        ..contact = _contact(publicKey: 'pk1');
      final queue = _FakeOfflineQueue();
      final qp = _FakeSharedMessageQueueProvider(queue);
      final vm = _buildViewModel(
        messageRepository: repo,
        contactRepository: contactRepo,
        queueProvider: qp,
        contactPublicKey: 'pk1',
      );

      Message? addedMsg;
      await vm.sendMessage(
        content: 'hello world',
        onMessageAdded: (m) => addedMsg = m,
      );

      expect(addedMsg, isNotNull);
      expect(addedMsg!.content, 'hello world');
      expect(addedMsg!.isFromMe, isTrue);
      expect(addedMsg!.status, MessageStatus.sending);
      expect(repo.savedMessage, isNotNull);
    });
  });

  group('ChatMessagingViewModel – retryMessage', () {
    test('retryMessage updates status to sending', () async {
      final repo = _FakeMessageRepository();
      final vm = _buildViewModel(messageRepository: repo);

      final msg = _msg(
        id: 'retry-1',
        chatId: 'chat-1',
        time: DateTime(2025, 1, 1),
        status: MessageStatus.failed,
      );

      await vm.retryMessage(msg);
      expect(repo.updatedMessage, isNotNull);
      expect(repo.updatedMessage!.status, MessageStatus.sending);
    });

    test('retryMessage rethrows on repository error', () async {
      final repo = _FakeMessageRepository()..shouldThrowOnUpdate = true;
      final vm = _buildViewModel(messageRepository: repo);

      final msg = _msg(
        id: 'retry-err',
        chatId: 'chat-1',
        time: DateTime(2025, 1, 1),
        status: MessageStatus.failed,
      );

      await expectLater(vm.retryMessage(msg), throwsException);
    });
  });

  group('ChatMessagingViewModel – deleteMessage', () {
    test('local-only delete calls onShowSuccess with "Message deleted"',
        () async {
      final repo = _FakeMessageRepository();
      final vm = _buildViewModel(messageRepository: repo);

      String? successMsg;
      MessageId? removedId;
      await vm.deleteMessage(
        messageId: const MessageId('del-1'),
        deleteForEveryone: false,
        onMessageRemoved: (id) => removedId = id,
        onShowSuccess: (msg) => successMsg = msg,
      );

      expect(removedId?.value, 'del-1');
      expect(successMsg, 'Message deleted');
    });

    test('delete returns false calls onShowError', () async {
      final repo = _FakeMessageRepository()..deleteResult = false;
      final vm = _buildViewModel(messageRepository: repo);

      String? errorMsg;
      await vm.deleteMessage(
        messageId: const MessageId('del-2'),
        onShowError: (msg) => errorMsg = msg,
      );

      expect(errorMsg, contains('Failed to delete'));
    });

    test('repository exception calls onShowError and rethrows', () async {
      final repo = _FakeMessageRepository()..shouldThrowOnDelete = true;
      final vm = _buildViewModel(messageRepository: repo);

      String? errorMsg;
      await expectLater(
        vm.deleteMessage(
          messageId: const MessageId('del-3'),
          onShowError: (msg) => errorMsg = msg,
        ),
        throwsException,
      );
      expect(errorMsg, contains('Failed to delete'));
    });
  });

  group('ChatMessagingViewModel – addReceivedMessage', () {
    test('returns true when listener active, false for duplicate', () {
      final vm = _buildViewModel();

      vm.setupMessageListener();
      expect(vm.messageListenerActive, isTrue);

      final msg = _msg(id: 'rcv-1', chatId: 'chat-1', time: DateTime(2025));
      final first = vm.addReceivedMessage(msg);
      expect(first, isTrue);

      final second = vm.addReceivedMessage(msg);
      expect(second, isFalse);
    });

    test('returns false when listener is not active', () {
      final vm = _buildViewModel();
      final msg = _msg(id: 'rcv-2', chatId: 'chat-1', time: DateTime(2025));
      final result = vm.addReceivedMessage(msg);
      expect(result, isFalse);
    });
  });

  group('ChatMessagingViewModel – updateRecipientKey', () {
    test('no-op when key is same', () {
      final vm = _buildViewModel(contactPublicKey: 'pk1');
      vm.updateRecipientKey('pk1');
      expect(vm.contactPublicKey, 'pk1');
    });

    test('no-op when key is empty', () {
      final vm = _buildViewModel(contactPublicKey: 'pk1');
      vm.updateRecipientKey('');
      expect(vm.contactPublicKey, 'pk1');
    });

    test('updates when key is different and non-empty', () {
      final vm = _buildViewModel(contactPublicKey: 'pk1');
      vm.updateRecipientKey('new-key');
      expect(vm.contactPublicKey, 'new-key');
    });
  });

  group('ChatMessagingViewModel – _logMessageSendState error fallback', () {
    test('sendMessage still works when getContact throws during logging',
        () async {
      final contactRepo = _FakeContactRepository()
        ..getContactError = StateError('log error');
      final secService = _FakeSecurityService()..level = SecurityLevel.low;
      final queue = _FakeOfflineQueue();
      final qp = _FakeSharedMessageQueueProvider(queue);

      // contactPublicKey must be non-empty but getContact will throw
      // The _logMessageSendState catch block handles it gracefully
      // However _resolveRecipientKey also calls getContact and will catch
      // the error, falling back to contactPublicKey.
      final vm = _buildViewModel(
        contactRepository: contactRepo,
        securityService: secService,
        queueProvider: qp,
        contactPublicKey: 'pk1',
      );

      await vm.sendMessage(content: 'log-error test');
      expect(queue.queueMessageCalls, 1);
    });
  });

  group('ChatMessagingViewModel – sendMessage long message preview', () {
    test('long message content is truncated in log without error', () async {
      final contactRepo = _FakeContactRepository()
        ..contact = _contact(publicKey: 'pk1');
      final queue = _FakeOfflineQueue();
      final qp = _FakeSharedMessageQueueProvider(queue);
      final vm = _buildViewModel(
        contactRepository: contactRepo,
        queueProvider: qp,
        contactPublicKey: 'pk1',
      );

      final longContent = 'A' * 100;
      await vm.sendMessage(content: longContent);
      expect(queue.queueMessageCalls, 1);
    });
  });

  group('ChatMessagingViewModel – sendMessage with uninitialized queue',
      () {
    test('initializes queue provider if not yet initialized', () async {
      final contactRepo = _FakeContactRepository()
        ..contact = _contact(publicKey: 'pk1');
      final queue = _FakeOfflineQueue();
      final qp = _FakeSharedMessageQueueProvider(queue)..initialized = false;
      final vm = _buildViewModel(
        contactRepository: contactRepo,
        queueProvider: qp,
        contactPublicKey: 'pk1',
      );

      await vm.sendMessage(content: 'init test');
      expect(qp.initialized, isTrue);
      expect(queue.queueMessageCalls, 1);
    });
  });
}

// --- Helpers ---

Contact _contact({
  required String publicKey,
  String? persistent,
  String? ephemeral,
}) {
  return Contact(
    publicKey: publicKey,
    persistentPublicKey: persistent,
    currentEphemeralId: ephemeral,
    displayName: 'Test',
    trustStatus: TrustStatus.verified,
    securityLevel: SecurityLevel.high,
    firstSeen: DateTime(2025, 12, 1),
    lastSeen: DateTime(2026, 2, 1),
  );
}

Message _msg({
  required String id,
  required String chatId,
  required DateTime time,
  MessageStatus status = MessageStatus.delivered,
}) {
  return Message(
    id: MessageId(id),
    chatId: ChatId(chatId),
    content: 'content-$id',
    timestamp: time,
    isFromMe: true,
    status: status,
  );
}

QueuedMessage _queuedMessage({
  required String id,
  required QueuedMessageStatus status,
  DateTime? queuedAt,
}) {
  return QueuedMessage(
    id: id,
    chatId: 'chat-1',
    content: 'queued-$id',
    recipientPublicKey: 'r',
    senderPublicKey: 's',
    priority: MessagePriority.normal,
    queuedAt: queuedAt ?? DateTime(2025, 1, 1),
    maxRetries: 3,
    status: status,
  );
}

ChatMessagingViewModel _buildViewModel({
  _FakeMessageRepository? messageRepository,
  _FakeContactRepository? contactRepository,
  _FakeSecurityService? securityService,
  _FakeUserPreferences? userPreferences,
  _FakeSharedMessageQueueProvider? queueProvider,
  String contactPublicKey = 'contact-key',
}) {
  return ChatMessagingViewModel(
    chatId: const ChatId('chat-1'),
    contactPublicKey: contactPublicKey,
    messageRepository: messageRepository ?? _FakeMessageRepository(),
    contactRepository: contactRepository ?? _FakeContactRepository(),
    securityService: securityService ?? _FakeSecurityService(),
    userPreferences: userPreferences ?? _FakeUserPreferences(),
    sharedQueueProvider: queueProvider ??
        (_FakeSharedMessageQueueProvider(_FakeOfflineQueue())
          ..initialized = true),
  );
}

// --- Fakes ---

class _FakeMessageRepository implements IMessageRepository {
  List<Message> messages = [];
  Message? savedMessage;
  Message? updatedMessage;
  bool deleteResult = true;
  bool shouldThrowOnGet = false;
  bool shouldThrowOnUpdate = false;
  bool shouldThrowOnDelete = false;

  @override
  Future<void> clearMessages(ChatId chatId) async {}
  @override
  Future<bool> deleteMessage(MessageId messageId) async {
    if (shouldThrowOnDelete) throw Exception('delete failed');
    return deleteResult;
  }

  @override
  Future<List<Message>> getAllMessages() async => messages;
  @override
  Future<Message?> getMessageById(MessageId messageId) async =>
      messages.cast<Message?>().firstWhere(
            (m) => m?.id == messageId,
            orElse: () => null,
          );
  @override
  Future<List<Message>> getMessages(ChatId chatId) async {
    if (shouldThrowOnGet) throw Exception('get failed');
    return messages.where((m) => m.chatId == chatId).toList();
  }

  @override
  Future<List<Message>> getMessagesForContact(String publicKey) async =>
      messages;
  @override
  Future<void> migrateChatId(ChatId oldChatId, ChatId newChatId) async {}
  @override
  Future<void> saveMessage(Message message) async {
    savedMessage = message;
    messages.add(message);
  }

  @override
  Future<void> updateMessage(Message message) async {
    if (shouldThrowOnUpdate) throw Exception('update failed');
    updatedMessage = message;
  }
}

class _FakeContactRepository implements IContactRepository {
  Contact? contact;
  Object? getContactError;

  @override
  Future<Contact?> getContact(String publicKey) async {
    if (getContactError != null) throw getContactError!;
    return contact;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

class _FakeSecurityService implements ISecurityService {
  SecurityLevel level = SecurityLevel.low;
  EncryptionMethod method = EncryptionMethod.global();

  @override
  Future<SecurityLevel> getCurrentLevel(
    String publicKey, [
    IContactRepository? repo,
  ]) async =>
      level;
  @override
  Future<EncryptionMethod> getEncryptionMethod(
    String publicKey,
    IContactRepository repo,
  ) async =>
      method;
  @override
  void registerIdentityMapping({
    required String persistentPublicKey,
    required String ephemeralID,
  }) {}
  @override
  void unregisterIdentityMapping(String persistentPublicKey) {}
  @override
  bool hasEstablishedNoiseSession(String peerSessionId) => false;
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

class _FakeUserPreferences implements IUserPreferences {
  String publicKey = 'sender-public-key';

  @override
  Future<String?> getDeviceId() async => 'device-id';
  @override
  Future<bool> getHintBroadcastEnabled() async => true;
  @override
  Future<Map<String, String>> getOrCreateKeyPair() async =>
      {'public': publicKey, 'private': 'private-key'};
  @override
  Future<String> getOrCreateDeviceId() async => 'device-id';
  @override
  Future<String> getPrivateKey() async => 'private-key';
  @override
  Future<String> getPublicKey() async => publicKey;
  @override
  Future<String> getUserName() async => 'User';
  @override
  Future<void> regenerateKeyPair() async {}
  @override
  Future<void> setHintBroadcastEnabled(bool enabled) async {}
  @override
  Future<void> setUserName(String name) async {}
}

class _FakeOfflineQueue implements OfflineMessageQueueContract {
  int queueMessageCalls = 0;
  String? lastRecipientKey;

  @override
  set onConnectivityCheck(Function()? callback) {}
  @override
  set onMessageDelivered(Function(QueuedMessage message)? callback) {}
  @override
  set onMessageFailed(
    Function(QueuedMessage message, String reason)? callback,
  ) {}
  @override
  set onMessageQueued(Function(QueuedMessage message)? callback) {}
  @override
  set onSendMessage(Function(String p1)? callback) {}
  @override
  set onStatsUpdated(Function(QueueStatistics stats)? callback) {}

  @override
  Future<void> initialize({
    Function(QueuedMessage p1)? onMessageQueued,
    Function(QueuedMessage p1)? onMessageDelivered,
    Function(QueuedMessage p1, String p2)? onMessageFailed,
    Function(QueueStatistics p1)? onStatsUpdated,
    Function(String p1)? onSendMessage,
    Function()? onConnectivityCheck,
  }) async {}

  @override
  Future<String> queueMessage({
    required String chatId,
    required String content,
    required String recipientPublicKey,
    required String senderPublicKey,
    MessagePriority priority = MessagePriority.normal,
    String? replyToMessageId,
    List<String> attachments = const [],
    bool isRelayMessage = false,
    RelayMetadata? relayMetadata,
    String? originalMessageId,
    String? relayNodeId,
    String? messageHash,
    bool persistToStorage = true,
  }) async {
    queueMessageCalls++;
    lastRecipientKey = recipientPublicKey;
    return 'queued-msg-id';
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

class _FakeSharedMessageQueueProvider implements ISharedMessageQueueProvider {
  _FakeSharedMessageQueueProvider(this.queue);
  final _FakeOfflineQueue queue;
  bool initialized = false;

  @override
  bool get isInitialized => initialized;
  @override
  bool get isInitializing => false;
  @override
  Future<void> initialize() async {
    initialized = true;
    await queue.initialize();
  }

  @override
  OfflineMessageQueueContract get messageQueue => queue;
}
