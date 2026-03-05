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

class _FakeMessageRepository implements IMessageRepository {
  List<Message> messages = <Message>[];
  Message? savedMessage;
  Message? updatedMessage;
  MessageId? deletedMessageId;

  Object? getMessagesError;
  Object? deleteMessageError;
  bool deleteMessageResult = true;

  @override
  Future<void> clearMessages(ChatId chatId) async {}

  @override
  Future<bool> deleteMessage(MessageId messageId) async {
    final Object? error = deleteMessageError;
    if (error != null) {
      if (error is Error) throw error;
      throw Exception(error.toString());
    }
    deletedMessageId = messageId;
    return deleteMessageResult;
  }

  @override
  Future<List<Message>> getAllMessages() async => messages;

  @override
  Future<Message?> getMessageById(MessageId messageId) async {
    for (final Message message in messages) {
      if (message.id == messageId) return message;
    }
    return null;
  }

  @override
  Future<List<Message>> getMessages(ChatId chatId) async {
    final Object? error = getMessagesError;
    if (error != null) {
      if (error is Error) throw error;
      throw Exception(error.toString());
    }
    return messages.where((message) => message.chatId == chatId).toList();
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
    updatedMessage = message;
  }
}

class _FakeContactRepository implements IContactRepository {
  Contact? contact;
  Object? getContactError;

  @override
  Future<Contact?> getContact(String publicKey) async {
    final Object? error = getContactError;
    if (error != null) {
      if (error is Error) throw error;
      throw Exception(error.toString());
    }
    return contact;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeSecurityService implements ISecurityService {
  SecurityLevel level = SecurityLevel.low;
  EncryptionMethod method = EncryptionMethod.global();

  @override
  Future<SecurityLevel> getCurrentLevel(
    String publicKey, [
    IContactRepository? repo,
  ]) async {
    return level;
  }

  @override
  Future<EncryptionMethod> getEncryptionMethod(
    String publicKey,
    IContactRepository repo,
  ) async {
    return method;
  }

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
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeUserPreferences implements IUserPreferences {
  String publicKey = 'sender-public-key';

  @override
  Future<String?> getDeviceId() async => 'device-id';

  @override
  Future<bool> getHintBroadcastEnabled() async => true;

  @override
  Future<Map<String, String>> getOrCreateKeyPair() async => <String, String>{
    'public': publicKey,
    'private': 'private-key',
  };

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
  bool initializeCalled = false;
  int queueMessageCalls = 0;
  String queuedId = 'queued-message-id';

  String? lastChatId;
  String? lastContent;
  String? lastRecipientKey;
  String? lastSenderKey;

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
  }) async {
    initializeCalled = true;
  }

  @override
  Future<String> queueMessage({
    required String chatId,
    required String content,
    required String recipientPublicKey,
    required String senderPublicKey,
    MessagePriority priority = MessagePriority.normal,
    String? replyToMessageId,
    List<String> attachments = const <String>[],
    bool isRelayMessage = false,
    RelayMetadata? relayMetadata,
    String? originalMessageId,
    String? relayNodeId,
    String? messageHash,
    bool persistToStorage = true,
  }) async {
    queueMessageCalls++;
    lastChatId = chatId;
    lastContent = content;
    lastRecipientKey = recipientPublicKey;
    lastSenderKey = senderPublicKey;
    return queuedId;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeSharedMessageQueueProvider implements ISharedMessageQueueProvider {
  _FakeSharedMessageQueueProvider(this.queue);

  final _FakeOfflineQueue queue;

  int initializeCalls = 0;
  bool initialized = false;

  @override
  bool get isInitialized => initialized;

  @override
  bool get isInitializing => false;

  @override
  Future<void> initialize() async {
    initializeCalls++;
    initialized = true;
    await queue.initialize();
  }

  @override
  OfflineMessageQueueContract get messageQueue => queue;
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

Contact _contact({
  required String publicKey,
  String? persistent,
  String? ephemeral,
}) {
  final DateTime now = DateTime.now();
  return Contact(
    publicKey: publicKey,
    persistentPublicKey: persistent,
    currentEphemeralId: ephemeral,
    displayName: 'Alice',
    trustStatus: TrustStatus.verified,
    securityLevel: SecurityLevel.high,
    firstSeen: now,
    lastSeen: now,
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

void main() {
  group('ChatMessagingViewModel', () {
    test('updateRecipientKey only updates for non-empty new keys', () {
      final ChatMessagingViewModel viewModel = _buildViewModel();

      viewModel.updateRecipientKey('');
      expect(viewModel.contactPublicKey, 'contact-key');

      viewModel.updateRecipientKey('contact-key');
      expect(viewModel.contactPublicKey, 'contact-key');

      viewModel.updateRecipientKey('new-key');
      expect(viewModel.contactPublicKey, 'new-key');
    });

    test(
      'loadMessages merges delivered and queued messages with dedupe',
      () async {
        final _FakeMessageRepository messageRepo = _FakeMessageRepository();
        final DateTime now = DateTime.now();
        messageRepo.messages = <Message>[
          _message(id: 'm1', chatId: 'chat-1', time: now),
          _message(
            id: 'm2',
            chatId: 'chat-1',
            time: now.add(const Duration(minutes: 2)),
          ),
        ];

        final ChatMessagingViewModel viewModel = _buildViewModel(
          messageRepository: messageRepo,
        );

        final List<bool> loadingStates = <bool>[];
        bool scrolled = false;
        final List<QueuedMessage> queuedMessages = <QueuedMessage>[
          QueuedMessage(
            id: 'm2',
            chatId: 'chat-1',
            content: 'duplicate',
            recipientPublicKey: 'recipient',
            senderPublicKey: 'sender',
            priority: MessagePriority.normal,
            queuedAt: now.add(const Duration(minutes: 1)),
            maxRetries: 3,
            status: QueuedMessageStatus.pending,
          ),
          QueuedMessage(
            id: 'm3',
            chatId: 'chat-1',
            content: 'pending',
            recipientPublicKey: 'recipient',
            senderPublicKey: 'sender',
            priority: MessagePriority.normal,
            queuedAt: now.add(const Duration(minutes: 1)),
            maxRetries: 3,
            status: QueuedMessageStatus.pending,
          ),
        ];

        final List<Message> all = await viewModel.loadMessages(
          onLoadingStateChanged: loadingStates.add,
          onGetQueuedMessages: () => queuedMessages,
          onScrollToBottom: () {
            scrolled = true;
          },
        );

        expect(loadingStates, <bool>[true, false]);
        expect(scrolled, isTrue);
        expect(all.map((m) => m.id.value).toList(), <String>['m1', 'm3', 'm2']);
        expect(
          all.firstWhere((m) => m.id == const MessageId('m3')).status,
          MessageStatus.sending,
        );
      },
    );

    test(
      'loadMessages forwards errors and preserves loading callback order',
      () async {
        final _FakeMessageRepository messageRepo = _FakeMessageRepository()
          ..getMessagesError = StateError('read fail');
        final ChatMessagingViewModel viewModel = _buildViewModel(
          messageRepository: messageRepo,
        );

        final List<bool> loadingStates = <bool>[];
        String? errorMessage;

        await expectLater(
          viewModel.loadMessages(
            onLoadingStateChanged: loadingStates.add,
            onError: (message) {
              errorMessage = message;
            },
          ),
          throwsA(isA<StateError>()),
        );

        expect(loadingStates, <bool>[true, false]);
        expect(errorMessage, contains('Failed to load messages'));
      },
    );

    test('sendMessage skips empty content', () async {
      final _FakeOfflineQueue queue = _FakeOfflineQueue();
      final _FakeSharedMessageQueueProvider queueProvider =
          _FakeSharedMessageQueueProvider(queue)..initialized = true;
      final ChatMessagingViewModel viewModel = _buildViewModel(
        queueProvider: queueProvider,
      );

      await viewModel.sendMessage(content: '   ');
      expect(queue.queueMessageCalls, 0);
    });

    test(
      'sendMessage resolves recipient key, queues and persists message',
      () async {
        final _FakeMessageRepository messageRepo = _FakeMessageRepository();
        final _FakeContactRepository contactRepo = _FakeContactRepository()
          ..contact = _contact(
            publicKey: 'contact-key',
            persistent: 'persistent-key',
            ephemeral: 'ephemeral-key',
          );
        final _FakeSecurityService securityService = _FakeSecurityService()
          ..level = SecurityLevel.high;
        final _FakeUserPreferences preferences = _FakeUserPreferences()
          ..publicKey = 'sender-key';
        final _FakeOfflineQueue queue = _FakeOfflineQueue();
        final _FakeSharedMessageQueueProvider queueProvider =
            _FakeSharedMessageQueueProvider(queue);

        final ChatMessagingViewModel viewModel = _buildViewModel(
          messageRepository: messageRepo,
          contactRepository: contactRepo,
          securityService: securityService,
          userPreferences: preferences,
          queueProvider: queueProvider,
        );

        final List<Message> added = <Message>[];
        String? successText;
        bool scrolled = false;

        await viewModel.sendMessage(
          content: 'hello world',
          onMessageAdded: added.add,
          onShowSuccess: (value) {
            successText = value;
          },
          onScrollToBottom: () {
            scrolled = true;
          },
        );

        expect(queue.queueMessageCalls, 1);
        expect(queue.lastRecipientKey, 'persistent-key');
        expect(queue.lastSenderKey, 'sender-key');
        expect(messageRepo.savedMessage?.id.value, 'queued-message-id');
        expect(viewModel.contactPublicKey, 'persistent-key');
        expect(added, hasLength(1));
        expect(successText, contains('queued for delivery'));
        expect(scrolled, isTrue);
      },
    );

    test('sendMessage surfaces sender-key errors and rethrows', () async {
      final _FakeUserPreferences preferences = _FakeUserPreferences()
        ..publicKey = '';
      final _FakeOfflineQueue queue = _FakeOfflineQueue();
      final _FakeSharedMessageQueueProvider queueProvider =
          _FakeSharedMessageQueueProvider(queue)..initialized = true;

      final ChatMessagingViewModel viewModel = _buildViewModel(
        userPreferences: preferences,
        queueProvider: queueProvider,
      );

      String? errorText;
      await expectLater(
        viewModel.sendMessage(
          content: 'hello',
          onShowError: (value) {
            errorText = value;
          },
        ),
        throwsA(isA<StateError>()),
      );

      expect(queue.queueMessageCalls, 0);
      expect(errorText, contains('Failed to send message'));
    });

    test('retryMessage updates message state to sending', () async {
      final _FakeMessageRepository messageRepo = _FakeMessageRepository();
      final ChatMessagingViewModel viewModel = _buildViewModel(
        messageRepository: messageRepo,
      );

      final Message failed = _message(
        id: 'failed-1',
        chatId: 'chat-1',
        time: DateTime.now(),
        status: MessageStatus.failed,
      );

      await viewModel.retryMessage(failed);
      expect(messageRepo.updatedMessage?.status, MessageStatus.sending);
    });

    test(
      'deleteMessage local success path notifies removal and success',
      () async {
        final _FakeMessageRepository messageRepo = _FakeMessageRepository();
        final ChatMessagingViewModel viewModel = _buildViewModel(
          messageRepository: messageRepo,
        );

        MessageId? removedId;
        String? successText;

        await viewModel.deleteMessage(
          messageId: const MessageId('m-1'),
          onMessageRemoved: (id) {
            removedId = id;
          },
          onShowSuccess: (message) {
            successText = message;
          },
        );

        expect(removedId, const MessageId('m-1'));
        expect(successText, 'Message deleted');
      },
    );

    test('deleteMessage handles false return without throwing', () async {
      final _FakeMessageRepository messageRepo = _FakeMessageRepository()
        ..deleteMessageResult = false;
      final ChatMessagingViewModel viewModel = _buildViewModel(
        messageRepository: messageRepo,
      );

      String? errorText;
      await viewModel.deleteMessage(
        messageId: const MessageId('m-2'),
        onShowError: (message) {
          errorText = message;
        },
      );

      expect(errorText, 'Failed to delete message');
    });

    test(
      'deleteMessage deleteForEveryone degrades safely when router unavailable',
      () async {
        final _FakeMessageRepository messageRepo = _FakeMessageRepository();
        final ChatMessagingViewModel viewModel = _buildViewModel(
          messageRepository: messageRepo,
        );

        String? successText;
        await viewModel.deleteMessage(
          messageId: const MessageId('m-3'),
          deleteForEveryone: true,
          onShowSuccess: (message) {
            successText = message;
          },
        );

        expect(successText, 'Message deleted locally (remote deletion failed)');
      },
    );

    test('addReceivedMessage deduplicates and honors listener state', () {
      final ChatMessagingViewModel viewModel = _buildViewModel();
      final DateTime now = DateTime.now();

      final Message first = _message(id: 'm-1', chatId: 'chat-1', time: now);
      final Message second = _message(
        id: 'm-2',
        chatId: 'chat-1',
        time: now.add(const Duration(seconds: 1)),
      );

      expect(viewModel.addReceivedMessage(first), isFalse);

      viewModel.setupMessageListener();
      expect(viewModel.messageListenerActive, isTrue);

      expect(viewModel.addReceivedMessage(second), isTrue);
      expect(viewModel.addReceivedMessage(first), isFalse);
    });
  });
}
