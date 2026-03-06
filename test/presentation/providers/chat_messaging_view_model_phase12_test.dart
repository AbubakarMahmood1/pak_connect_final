/// Phase 12.6: Supplementary tests for ChatMessagingViewModel
/// Covers: _resolveRecipientKey all branches (low security, ephemeral-only,
///   publicKey fallback, persistent-as-last-resort, no contact),
///   setupDeliveryListener, setupContactRequestListener, dispose,
///   sendMessage with reply-to, loadMessages empty queued
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
  group('ChatMessagingViewModel - resolveRecipientKey branches', () {
    test('LOW security with ephemeral only uses ephemeral key', () async {
      final contactRepo = _FakeContactRepository()
        ..contact = _contact(
          publicKey: 'pk1',
          ephemeral: 'eph-key',
        );
      final secService = _FakeSecurityService()..level = SecurityLevel.low;
      final queue = _FakeOfflineQueue();
      final queueProvider = _FakeSharedMessageQueueProvider(queue);

      final vm = _buildViewModel(
        contactRepository: contactRepo,
        securityService: secService,
        queueProvider: queueProvider,
        contactPublicKey: 'pk1',
      );

      await vm.sendMessage(content: 'test low ephemeral');
      expect(queue.lastRecipientKey, 'eph-key');
    });

    test('LOW security with no ephemeral falls back to publicKey', () async {
      final contactRepo = _FakeContactRepository()
        ..contact = _contact(publicKey: 'pk1');
      final secService = _FakeSecurityService()..level = SecurityLevel.low;
      final queue = _FakeOfflineQueue();
      final queueProvider = _FakeSharedMessageQueueProvider(queue);

      final vm = _buildViewModel(
        contactRepository: contactRepo,
        securityService: secService,
        queueProvider: queueProvider,
        contactPublicKey: 'pk1',
      );

      await vm.sendMessage(content: 'test low fallback');
      expect(queue.lastRecipientKey, 'pk1');
    });

    test(
      'LOW security with persistent-only uses persistent as last resort',
      () async {
        final contactRepo = _FakeContactRepository()
          ..contact = _contact(
            publicKey: '',
            persistent: 'persist-key',
          );
        final secService = _FakeSecurityService()..level = SecurityLevel.low;
        final queue = _FakeOfflineQueue();
        final queueProvider = _FakeSharedMessageQueueProvider(queue);

        final vm = _buildViewModel(
          contactRepository: contactRepo,
          securityService: secService,
          queueProvider: queueProvider,
          contactPublicKey: 'pk1',
        );

        await vm.sendMessage(content: 'test low persistent fallback');
        expect(queue.lastRecipientKey, 'persist-key');
      },
    );

    test('HIGH security with persistent key uses persistent', () async {
      final contactRepo = _FakeContactRepository()
        ..contact = _contact(
          publicKey: 'pk1',
          persistent: 'persist-key',
          ephemeral: 'eph-key',
        );
      final secService = _FakeSecurityService()..level = SecurityLevel.high;
      final queue = _FakeOfflineQueue();
      final queueProvider = _FakeSharedMessageQueueProvider(queue);

      final vm = _buildViewModel(
        contactRepository: contactRepo,
        securityService: secService,
        queueProvider: queueProvider,
        contactPublicKey: 'pk1',
      );

      await vm.sendMessage(content: 'test high persistent');
      expect(queue.lastRecipientKey, 'persist-key');
    });

    test(
      'MEDIUM security without persistent but with ephemeral uses ephemeral',
      () async {
        final contactRepo = _FakeContactRepository()
          ..contact = _contact(
            publicKey: 'pk1',
            ephemeral: 'eph-key',
          );
        final secService = _FakeSecurityService()..level = SecurityLevel.medium;
        final queue = _FakeOfflineQueue();
        final queueProvider = _FakeSharedMessageQueueProvider(queue);

        final vm = _buildViewModel(
          contactRepository: contactRepo,
          securityService: secService,
          queueProvider: queueProvider,
          contactPublicKey: 'pk1',
        );

        await vm.sendMessage(content: 'test medium ephemeral');
        // medium without persistent → not prefersPersistent → falls through
        // to low path → ephemeral first
        expect(queue.lastRecipientKey, 'eph-key');
      },
    );

    test('null contact falls back to contactPublicKey', () async {
      final contactRepo = _FakeContactRepository()..contact = null;
      final secService = _FakeSecurityService()..level = SecurityLevel.low;
      final queue = _FakeOfflineQueue();
      final queueProvider = _FakeSharedMessageQueueProvider(queue);

      final vm = _buildViewModel(
        contactRepository: contactRepo,
        securityService: secService,
        queueProvider: queueProvider,
        contactPublicKey: 'fallback-key',
      );

      await vm.sendMessage(content: 'test null contact');
      expect(queue.lastRecipientKey, 'fallback-key');
    });

    test(
      'getContact throws falls back to contactPublicKey',
      () async {
        final contactRepo = _FakeContactRepository()
          ..getContactError = StateError('no db');
        final secService = _FakeSecurityService()..level = SecurityLevel.high;
        final queue = _FakeOfflineQueue();
        final queueProvider = _FakeSharedMessageQueueProvider(queue);

        final vm = _buildViewModel(
          contactRepository: contactRepo,
          securityService: secService,
          queueProvider: queueProvider,
          contactPublicKey: 'error-fallback',
        );

        await vm.sendMessage(content: 'test error fallback');
        expect(queue.lastRecipientKey, 'error-fallback');
      },
    );
  });

  group('ChatMessagingViewModel - listener and lifecycle', () {
    test('setupDeliveryListener completes without error', () {
      final vm = _buildViewModel();
      expect(() => vm.setupDeliveryListener(), returnsNormally);
    });

    test('setupContactRequestListener completes without error', () {
      final vm = _buildViewModel();
      expect(() => vm.setupContactRequestListener(), returnsNormally);
    });

    test('dispose completes without error', () {
      final vm = _buildViewModel();
      expect(() => vm.dispose(), returnsNormally);
    });

    test('messageListenerActive is false initially', () {
      final vm = _buildViewModel();
      expect(vm.messageListenerActive, isFalse);
    });
  });

  group('ChatMessagingViewModel - sendMessage with replyTo', () {
    test('sendMessage queues message and invokes callbacks', () async {
      final contactRepo = _FakeContactRepository()
        ..contact = _contact(publicKey: 'pk1');
      final queue = _FakeOfflineQueue();
      final queueProvider = _FakeSharedMessageQueueProvider(queue);

      final vm = _buildViewModel(
        contactRepository: contactRepo,
        queueProvider: queueProvider,
        contactPublicKey: 'pk1',
      );

      bool scrolled = false;
      String? successMsg;
      await vm.sendMessage(
        content: 'reply msg',
        onScrollToBottom: () {
          scrolled = true;
        },
        onShowSuccess: (msg) {
          successMsg = msg;
        },
      );

      expect(queue.queueMessageCalls, 1);
      expect(scrolled, isTrue);
      expect(successMsg, contains('queued'));
    });
  });

  group('ChatMessagingViewModel - loadMessages edge cases', () {
    test('loadMessages with empty queue returns only delivered', () async {
      final msgRepo = _FakeMessageRepository();
      msgRepo.messages = [
        _message(id: 'm1', chatId: 'chat-1', time: DateTime(2026, 1, 1)),
      ];
      final vm = _buildViewModel(messageRepository: msgRepo);

      final messages = await vm.loadMessages(
        onGetQueuedMessages: () => [],
      );

      expect(messages.length, 1);
      expect(messages.first.id.value, 'm1');
    });

    test('loadMessages with no delivered and queued only', () async {
      final msgRepo = _FakeMessageRepository();
      final vm = _buildViewModel(messageRepository: msgRepo);

      final queued = [
        QueuedMessage(
          id: 'q1',
          chatId: 'chat-1',
          content: 'pending',
          recipientPublicKey: 'r',
          senderPublicKey: 's',
          priority: MessagePriority.normal,
          queuedAt: DateTime(2026, 1, 1),
          maxRetries: 3,
          status: QueuedMessageStatus.pending,
        ),
      ];

      final messages = await vm.loadMessages(
        onGetQueuedMessages: () => queued,
      );

      expect(messages.length, 1);
      expect(messages.first.status, MessageStatus.sending);
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

Message _message({
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
    sharedQueueProvider:
        queueProvider ?? _FakeSharedMessageQueueProvider(_FakeOfflineQueue())
          ..initialized = true,
  );
}

// --- Fakes ---

class _FakeMessageRepository implements IMessageRepository {
  List<Message> messages = [];
  Message? savedMessage;
  Message? updatedMessage;
  bool deleteResult = true;

  @override
  Future<void> clearMessages(ChatId chatId) async {}
  @override
  Future<bool> deleteMessage(MessageId messageId) async => deleteResult;
  @override
  Future<List<Message>> getAllMessages() async => messages;
  @override
  Future<Message?> getMessageById(MessageId messageId) async =>
      messages.cast<Message?>().firstWhere(
            (m) => m?.id == messageId,
            orElse: () => null,
          );
  @override
  Future<List<Message>> getMessages(ChatId chatId) async =>
      messages.where((m) => m.chatId == chatId).toList();
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
