import 'dart:async';
import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:logging/logging.dart';
import '../../core/app_core.dart';
import '../../core/interfaces/i_connection_service.dart';
import '../../core/models/connection_info.dart';
import '../../core/messaging/message_router.dart';
import '../../core/security/message_security.dart';
import '../../core/services/message_retry_coordinator.dart';
import '../../core/services/persistent_chat_state_manager.dart';
import '../../core/services/security_manager.dart';
import '../../core/utils/chat_utils.dart';
import '../../core/utils/string_extensions.dart';
import '../../data/repositories/chats_repository.dart';
import '../../data/repositories/contact_repository.dart';
import '../../data/repositories/message_repository.dart';
import '../../data/services/ble_state_manager.dart';
import '../../domain/entities/message.dart';
import '../../domain/models/mesh_network_models.dart';
import '../../domain/services/notification_service.dart';
import '../models/chat_screen_config.dart';
import '../../presentation/controllers/chat_pairing_dialog_controller.dart';
import '../../presentation/controllers/chat_scrolling_controller.dart'
    as chat_controller;
import '../../presentation/controllers/chat_search_controller.dart';
import '../../presentation/models/chat_ui_state.dart';
import '../../presentation/providers/ble_providers.dart';
import '../../presentation/providers/chat_messaging_view_model.dart';
import '../../presentation/providers/mesh_networking_provider.dart';
import '../../presentation/providers/security_state_provider.dart';
import '../widgets/chat_search_bar.dart' show SearchResult;
import 'chat_retry_helper.dart';

class ChatScreenControllerArgs {
  const ChatScreenControllerArgs({
    required this.ref,
    required this.context,
    required this.config,
    this.messageRepository,
    this.contactRepository,
    this.chatsRepository,
    this.persistentChatManager,
    this.retryCoordinator,
    this.messagingViewModel,
    this.repositoryRetryHandler,
    this.pairingDialogController,
  });

  final WidgetRef ref;
  final BuildContext context;
  final ChatScreenConfig config;
  final MessageRepository? messageRepository;
  final ContactRepository? contactRepository;
  final ChatsRepository? chatsRepository;
  final PersistentChatStateManager? persistentChatManager;
  final MessageRetryCoordinator? retryCoordinator;
  final ChatMessagingViewModel? messagingViewModel;
  final Future<void> Function(Message message)? repositoryRetryHandler;
  final ChatPairingDialogController? pairingDialogController;
}

/// Coordinates all non-UI chat behaviors so the widget can stay lean.
class ChatScreenController extends ChangeNotifier {
  final _logger = Logger('ChatScreenController');
  final WidgetRef ref;
  final BuildContext context;
  final ChatScreenConfig config;
  final MessageRepository messageRepository;
  final ContactRepository contactRepository;
  final ChatsRepository chatsRepository;
  late final Future<void> Function(Message message) _repositoryRetryHandler;
  final ChatPairingDialogController? _injectedPairingController;

  late ChatMessagingViewModel _messagingViewModel;
  late chat_controller.ChatScrollingController _scrollingController;
  late ChatSearchController _searchController;
  late ChatPairingDialogController _pairingDialogController;
  late ChatRetryHelper _retryHelper;
  PersistentChatStateManager? _persistentChatManager;

  StreamSubscription<String>? _messageSubscription;
  StreamSubscription<String>? _deliverySubscription;
  Timer? _initializationTimeoutTimer;
  final List<StreamSubscription<dynamic>> _managedSubscriptions = [];
  bool _initialized = false;

  ChatUIState _state = const ChatUIState();
  String _chatId = '';
  String? _cachedContactPublicKey;
  bool _messageListenerActive = false;
  bool _disposed = false;
  final List<String> _messageBuffer = [];

  ChatScreenController(ChatScreenControllerArgs args)
    : ref = args.ref,
      context = args.context,
      config = args.config,
      messageRepository = args.messageRepository ?? MessageRepository(),
      contactRepository = args.contactRepository ?? ContactRepository(),
      chatsRepository = args.chatsRepository ?? ChatsRepository(),
      _persistentChatManager = args.persistentChatManager,
      _injectedPairingController = args.pairingDialogController {
    _repositoryRetryHandler =
        args.repositoryRetryHandler ?? _retryRepositoryMessage;
    _chatId = _calculateInitialChatId();
    _cachedContactPublicKey = _contactPublicKey;
    _initializeControllers(messagingViewModel: args.messagingViewModel);
    _retryHelper = ChatRetryHelper(
      ref: ref,
      config: config,
      chatId: () => _chatId,
      contactPublicKey: () => _contactPublicKey,
      displayContactName: () => displayContactName,
      messageRepository: messageRepository,
      repositoryRetryHandler: _repositoryRetryHandler,
      showSuccess: _showSuccess,
      showError: _showError,
      showInfo: _showInfo,
      scrollToBottom: scrollToBottom,
      getMessages: () => _state.messages,
      logger: _logger,
      initialCoordinator: args.retryCoordinator,
    );
  }

  ChatUIState get state => _state;
  String get chatId => _chatId;
  chat_controller.ChatScrollingController get scrollingController =>
      _scrollingController;
  ChatSearchController get searchController => _searchController;
  ChatPairingDialogController get pairingDialogController =>
      _pairingDialogController;

  /// Legacy-style constructor kept for compatibility in tests and widgets that
  /// still pass named parameters directly.
  @visibleForTesting
  ChatScreenController.deprecated({
    required WidgetRef ref,
    required BuildContext context,
    required ChatScreenConfig config,
    MessageRepository? messageRepository,
    ContactRepository? contactRepository,
    ChatsRepository? chatsRepository,
    PersistentChatStateManager? persistentChatManager,
    MessageRetryCoordinator? retryCoordinator,
    ChatMessagingViewModel? messagingViewModel,
    Future<void> Function(Message message)? repositoryRetryHandler,
    ChatPairingDialogController? pairingDialogController,
  }) : this(
         ChatScreenControllerArgs(
           ref: ref,
           context: context,
           config: config,
           messageRepository: messageRepository,
           contactRepository: contactRepository,
           chatsRepository: chatsRepository,
           persistentChatManager: persistentChatManager,
           retryCoordinator: retryCoordinator,
           messagingViewModel: messagingViewModel,
           repositoryRetryHandler: repositoryRetryHandler,
           pairingDialogController: pairingDialogController,
         ),
       );

  String get displayContactName {
    if (config.isRepositoryMode) {
      return config.contactName ?? 'Unknown';
    }

    final connectionService = ref.read(connectionServiceProvider);
    final connectionInfo = connectionService.currentConnectionInfo;
    if (connectionInfo.otherUserName != null &&
        connectionInfo.otherUserName!.isNotEmpty) {
      return connectionInfo.otherUserName!;
    }

    if (config.isCentralMode && config.device != null) {
      return config.device!.uuid.toString().shortId(8);
    }
    if (config.isPeripheralMode && config.central != null) {
      return config.central!.uuid.toString().shortId(8);
    }
    return 'Unknown';
  }

  String? get securityStateKey {
    final publicKey = config.contactPublicKey ?? _contactPublicKey;
    if (publicKey != null && publicKey.isNotEmpty) {
      return 'repo_$publicKey';
    }

    return ref.read(connectionServiceProvider).currentSessionId;
  }

  String? get _contactPublicKey {
    if (config.contactPublicKey != null &&
        config.contactPublicKey!.isNotEmpty) {
      return config.contactPublicKey;
    }

    final connectionService = ref.read(connectionServiceProvider);
    final currentKey = connectionService.currentSessionId;
    if (currentKey != null && currentKey.isNotEmpty) {
      _cachedContactPublicKey = currentKey;
      return currentKey;
    }

    return _cachedContactPublicKey;
  }

  void _initializeControllers({ChatMessagingViewModel? messagingViewModel}) {
    _messagingViewModel =
        messagingViewModel ??
        ChatMessagingViewModel(
          chatId: _chatId,
          contactPublicKey: _contactPublicKey ?? '',
          messageRepository: messageRepository,
          contactRepository: contactRepository,
        );

    _scrollingController = chat_controller.ChatScrollingController(
      chatsRepository: chatsRepository,
      chatId: _chatId,
      onScrollToBottom: () => _updateState(
        (state) => state.copyWith(newMessagesWhileScrolledUp: 0),
      ),
      onUnreadCountChanged: (count) =>
          _updateState((state) => state.copyWith(unreadMessageCount: count)),
      onStateChanged: _syncScrollState,
    );

    _searchController = ChatSearchController(
      onSearchModeToggled: (isSearchMode) =>
          _updateState((state) => state.copyWith(isSearchMode: isSearchMode)),
      onSearchResultsChanged: _onSearch,
      onNavigateToResult: _navigateToSearchResult,
      scrollController: _scrollingController.scrollController,
    );

    final connectionService = ref.read(connectionServiceProvider);
    _pairingDialogController =
        _injectedPairingController ??
        ChatPairingDialogController(
          stateManager: _resolvePairingStateManager(connectionService),
          connectionService: connectionService,
          contactRepository: contactRepository,
          context: context,
          navigator: Navigator.of(context),
          getTheirPersistentKey: () =>
              connectionService.theirPersistentPublicKey,
          onPairingCompleted: (success) {
            if (success && securityStateKey != null) {
              ref.invalidate(securityStateProvider(securityStateKey));
            }
          },
          onPairingError: _showError,
          onPairingSuccess: _showSuccess,
        );
  }

  BLEStateManager _resolvePairingStateManager(
    IConnectionService connectionService,
  ) {
    if (_injectedPairingController != null) {
      return _injectedPairingController!.stateManager;
    }

    try {
      final dynamic maybeWithManager = connectionService;
      final manager = maybeWithManager.stateManager;
      if (manager is BLEStateManager) {
        return manager;
      }
    } catch (_) {
      // Fall back below when the connection service doesn't expose stateManager.
    }

    _logger.warning(
      'BLEStateManager not exposed by connection service; using fallback instance',
    );
    return BLEStateManager();
  }

  Future<void> initialize({bool logChatOpen = true}) async {
    if (_disposed || _initialized) return;
    if (logChatOpen) {
      await _logChatOpenState();
    }
    await _loadMessages();
    _setupPersistentChatManager();
    _checkAndSetupLiveMessaging();
    _setupMeshNetworking();
    _setupDeliveryListener();
    _retryHelper.ensureRetryCoordinator();
    _setupSecurityStateListener();
    _initialized = true;
  }

  void _updateState(ChatUIState Function(ChatUIState) updater) {
    if (_disposed) return;
    _state = updater(_state);
    notifyListeners();
  }

  void _syncScrollState() {
    _updateState(
      (state) => state.copyWith(
        unreadMessageCount: _scrollingController.unreadMessageCount,
        newMessagesWhileScrolledUp:
            _scrollingController.newMessagesWhileScrolledUp,
        showUnreadSeparator: _scrollingController.showUnreadSeparator,
      ),
    );
  }

  Future<void> _logChatOpenState() async {
    final publicKey = config.contactPublicKey ?? _chatId;
    if (publicKey == null) {
      _logger.warning('Chat open with no public key available');
      return;
    }

    final contact = await contactRepository.getContact(publicKey);
    final securityLevel = await SecurityManager.instance.getCurrentLevel(
      publicKey,
      contactRepository,
    );
    final encryptionMethod = await SecurityManager.instance.getEncryptionMethod(
      publicKey,
      contactRepository,
    );

    _logger.info(
      'Chat open: ${config.contactName ?? "Unknown"} | Security=${securityLevel.name} | Encryption=${encryptionMethod.type.name}',
    );
    final pkDisp = publicKey.length > 16
        ? '${publicKey.shortId()}...'
        : publicKey;
    final eph = contact?.currentEphemeralId;
    final ephDisp = eph != null
        ? (eph.length > 16 ? '${eph.shortId()}...' : eph)
        : 'NULL';
    final sid = contact?.sessionIdForNoise;
    final sidDisp = sid != null
        ? (sid.length > 16 ? '${sid.shortId()}...' : sid)
        : 'NULL';
    _logger.info(
      'Keys: PubKey=$pkDisp | CurrentEphemeralID=$ephDisp | NoiseSession=$sidDisp',
    );
  }

  void _checkAndSetupLiveMessaging() {
    final connectionInfo = ref.read(connectionInfoProvider).value;
    if (connectionInfo?.isConnected == true) {
      _setupMessageListener();
      _setupContactRequestListener();
    }
  }

  void _setupMeshNetworking() {
    try {
      final meshStatusAsync = ref.read(meshNetworkStatusProvider);
      meshStatusAsync.when(
        data: (status) {
          if (status.isInitialized) {
            _updateState(
              (state) => state.copyWith(
                meshInitializing: false,
                initializationStatus: 'Ready',
              ),
            );
          } else {
            _updateState(
              (state) => state.copyWith(
                meshInitializing: true,
                initializationStatus: 'Initializing mesh network...',
              ),
            );
            _startInitializationTimeoutTimer();
          }
        },
        loading: () {
          _updateState(
            (state) => state.copyWith(
              meshInitializing: true,
              initializationStatus: 'Checking mesh status...',
            ),
          );
          _startInitializationTimeoutTimer();
        },
        error: (error, stack) {
          _updateState(
            (state) => state.copyWith(
              meshInitializing: false,
              initializationStatus: 'Mesh ready (fallback)',
            ),
          );
          _logger.warning('Mesh status error - skipping banner: $error');
        },
      );
    } catch (e) {
      _logger.warning('Failed to set up mesh networking: $e');
      _updateState(
        (state) => state.copyWith(
          meshInitializing: false,
          initializationStatus: 'Failed to initialize',
        ),
      );
    }
  }

  void _setupDeliveryListener() {
    try {
      final meshService = ref.read(meshNetworkingServiceProvider);
      _deliverySubscription = meshService.messageDeliveryStream.listen((
        messageId,
      ) {
        _updateMessageStatus(messageId, MessageStatus.delivered);
      });
      _managedSubscriptions.add(_deliverySubscription!);
    } catch (e) {
      _logger.warning('Failed to set up delivery listener: $e');
    }
  }

  void _updateMessageStatus(String messageId, MessageStatus newStatus) {
    _updateState((state) {
      final messages = [...state.messages];
      final index = messages.indexWhere((m) => m.id == messageId);
      if (index != -1) {
        messages[index] = messages[index].copyWith(status: newStatus);
      }
      return state.copyWith(messages: messages);
    });
  }

  @visibleForTesting
  void applyMessageUpdate(Message updatedMessage) {
    _updateState((state) {
      final messages = [...state.messages];
      final index = messages.indexWhere((m) => m.id == updatedMessage.id);
      if (index != -1) {
        messages[index] = updatedMessage;
      }
      return state.copyWith(messages: messages);
    });
  }

  void _startInitializationTimeoutTimer() {
    _initializationTimeoutTimer?.cancel();
    final timeoutDuration = _state.initializationStatus.contains('Checking')
        ? const Duration(seconds: 3)
        : const Duration(seconds: 15);

    _initializationTimeoutTimer = Timer(timeoutDuration, () {
      if (_disposed || !_state.meshInitializing) return;
      _logger.info('Mesh initialization timeout reached - hiding banner');
      _updateState(
        (state) => state.copyWith(
          meshInitializing: false,
          initializationStatus: 'Ready (timeout fallback)',
        ),
      );
      _showSuccess('Mesh networking ready (fallback mode)');
    });
  }

  void handleMeshInitializationStatusChange(
    AsyncValue<MeshNetworkStatus>? previous,
    AsyncValue<MeshNetworkStatus> next,
  ) {
    if (_disposed) return;
    next.when(
      data: (status) {
        if (status.isInitialized && _state.meshInitializing) {
          _initializationTimeoutTimer?.cancel();
          _updateState(
            (state) => state.copyWith(
              meshInitializing: false,
              initializationStatus: 'Ready',
            ),
          );
          _showSuccess('Mesh networking ready');
        } else if (!status.isInitialized && !_state.meshInitializing) {
          _updateState(
            (state) => state.copyWith(initializationStatus: 'Initializing...'),
          );
        }
      },
      loading: () {
        if (!_state.meshInitializing) {
          _updateState(
            (state) => state.copyWith(
              meshInitializing: true,
              initializationStatus: 'Initializing mesh network...',
            ),
          );
        }
      },
      error: (error, stack) {
        _updateState(
          (state) => state.copyWith(
            meshInitializing: false,
            initializationStatus: 'Initialization failed',
          ),
        );
        _logger.severe('Mesh initialization error: $error');
      },
    );
  }

  void _setupSecurityStateListener() {
    final connectionService = ref.read(connectionServiceProvider);
    connectionService.setContactRequestCompletedListener((success) {
      if (success && securityStateKey != null) {
        ref.invalidate(securityStateProvider(securityStateKey));
      }
    });
  }

  Future<void> userRequestedPairing() async {
    final connectionService = ref.read(connectionServiceProvider);
    final connectionInfoAsync = ref.read(connectionInfoProvider);
    final connectionInfo =
        connectionInfoAsync.value ?? connectionService.currentConnectionInfo;

    if (connectionInfo == null || !connectionInfo.isConnected) {
      _showError('Not connected - cannot pair');
      return;
    }
    await _pairingDialogController.userRequestedPairing();
  }

  Future<void> _manualReconnection() async {
    final connectionService = ref.read(connectionServiceProvider);
    if (connectionService.isConnected) {
      _showSuccess('Already connected');
      return;
    }

    _showSuccess('Manually searching for device...');

    try {
      final foundDevice = await connectionService.scanForSpecificDevice(
        timeout: const Duration(seconds: 10),
      );

      if (foundDevice != null) {
        if (connectionService.connectedDevice?.uuid == foundDevice.uuid) {
          _showSuccess('Already connected to this device');
          return;
        }

        await connectionService.connectToDevice(foundDevice);
        _showSuccess('Manual reconnection successful!');
      } else {
        _showError(
          'Device not found - ensure other device is in discoverable mode',
        );
      }
    } catch (e) {
      final errorMsg = e.toString();
      if (errorMsg.contains('1049')) {
        _showSuccess('Already connected to device');
      } else {
        _showError('Manual reconnection failed: ${errorMsg.split(':').last}');
      }
    }
  }

  bool _hasMessagesQueuedForRelay() {
    try {
      final offlineQueue = AppCore.instance.messageQueue;
      final queuedMessages = offlineQueue.getPendingMessages();
      final chatMessages = queuedMessages.where(
        (msg) => msg.recipientPublicKey == _contactPublicKey,
      );
      return chatMessages.isNotEmpty;
    } catch (e) {
      _logger.warning('Error checking relay queue: $e');
      return false;
    }
  }

  Future<void> _loadMessages() async {
    try {
      final meshService = ref.read(meshNetworkingServiceProvider);
      final allMessages = await _messagingViewModel.loadMessages(
        onLoadingStateChanged: (isLoading) {
          _updateState((state) => state.copyWith(isLoading: isLoading));
        },
        onGetQueuedMessages: () =>
            meshService.getQueuedMessagesForChat(_chatId),
        onScrollToBottom: scrollToBottom,
        onError: _showError,
      );

      _updateState((state) => state.copyWith(messages: allMessages));

      if (config.isRepositoryMode) {
        await _scrollingController.syncUnreadCount(messages: allMessages);
        _syncScrollState();
      }

      await _processBufferedMessages();

      Future.delayed(const Duration(milliseconds: 1000), () {
        if (!_disposed) {
          _retryHelper.ensureRetryCoordinator();
          _retryHelper.autoRetryFailedMessages();
        }
      });
    } catch (e) {
      _logger.severe('Error in loadMessages: $e');
      _showError('Failed to load messages: $e');
      _updateState((state) => state.copyWith(isLoading: false));
    }
  }

  Future<void> _autoRetryFailedMessages() =>
      _retryHelper.autoRetryFailedMessages();

  Future<void> _retryRepositoryMessage(Message message) async {
    try {
      final retryMessage = message.copyWith(status: MessageStatus.sending);
      await messageRepository.updateMessage(retryMessage);
      _updateState((state) {
        final messages = [...state.messages];
        final index = messages.indexWhere((m) => m.id == message.id);
        if (index != -1) {
          messages[index] = retryMessage;
        }
        return state.copyWith(messages: messages);
      });

      bool success = false;
      final connectionInfo = ref.read(connectionInfoProvider).value;
      final isConnected = connectionInfo?.isConnected ?? false;
      final isReady = connectionInfo?.isReady ?? false;

      try {
        final router = MessageRouter.instance;
        final result = await router.sendMessage(
          content: message.content,
          recipientId: _contactPublicKey ?? _chatId,
          messageId: message.id,
          recipientName: displayContactName,
        );

        success = result.isSentDirectly;

        if (result.isQueued) {
          _showInfo('Message queued - will send when peer comes online');
        }
      } catch (e) {
        if (isConnected && isReady) {
          final connectionService = ref.read(connectionServiceProvider);

          if (config.isCentralMode) {
            success = await connectionService.sendMessage(
              message.content,
              messageId: message.id,
            );
          } else {
            success = await connectionService.sendPeripheralMessage(
              message.content,
              messageId: message.id,
            );
          }
        }
      }

      if (!success && _contactPublicKey != null) {
        try {
          final meshController = ref.read(meshNetworkingControllerProvider);
          final meshResult = await meshController.sendMeshMessage(
            content: message.content,
            recipientPublicKey: _contactPublicKey!,
          );

          if (meshResult.isSuccess) {
            success = true;
          }
        } catch (_) {}
      }

      final newStatus = success
          ? MessageStatus.delivered
          : MessageStatus.failed;
      final updatedMessage = retryMessage.copyWith(status: newStatus);
      await messageRepository.updateMessage(updatedMessage);
      _updateState((state) {
        final messages = [...state.messages];
        final index = messages.indexWhere((m) => m.id == message.id);
        if (index != -1) {
          messages[index] = updatedMessage;
        }
        return state.copyWith(messages: messages);
      });
    } catch (e) {
      final failedAgain = message.copyWith(status: MessageStatus.failed);
      await messageRepository.updateMessage(failedAgain);
      _updateState((state) {
        final messages = [...state.messages];
        final index = messages.indexWhere((m) => m.id == message.id);
        if (index != -1) {
          messages[index] = failedAgain;
        }
        return state.copyWith(messages: messages);
      });
      rethrow;
    }
  }

  Future<void> _fallbackRetryFailedMessages() =>
      _retryHelper.fallbackRetryFailedMessages();

  void _setupPersistentChatManager() {
    _persistentChatManager ??= ref.read(persistentChatStateManagerProvider);
    _persistentChatManager?.registerChatScreen(
      _chatId,
      _handlePersistentMessage,
    );
  }

  void _handlePersistentMessage(String content) async {
    await _addReceivedMessage(content);
  }

  void _activateMessageListener() {
    if (_messageListenerActive) {
      return;
    }

    _messageListenerActive = true;
    final connectionService = ref.read(connectionServiceProvider);

    if (_persistentChatManager != null &&
        !_persistentChatManager!.hasActiveListener(_chatId)) {
      _persistentChatManager!.setupPersistentListener(
        _chatId,
        connectionService.receivedMessages,
      );
    } else if (_persistentChatManager != null &&
        _persistentChatManager!.hasActiveListener(_chatId)) {
      return;
    } else {
      _messageSubscription = connectionService.receivedMessages.listen((
        content,
      ) {
        if (!_disposed && _messageListenerActive) {
          _addReceivedMessage(content);
        } else if (_disposed) {
          _messageBuffer.add(content);
        }
      });
      _managedSubscriptions.add(_messageSubscription!);
    }
  }

  void _setupMessageListener() {
    _activateMessageListener();
  }

  Future<void> _addReceivedMessage(String content) async {
    final senderPublicKey = _contactPublicKey ?? _chatId;
    final secureMessageId = await MessageSecurity.generateSecureMessageId(
      senderPublicKey: senderPublicKey,
      content: content,
    );

    final existingMessage = await messageRepository.getMessageById(
      secureMessageId,
    );
    if (existingMessage != null) {
      final inUiList = _state.messages.any((m) => m.id == secureMessageId);
      if (!inUiList) {
        _updateState(
          (state) =>
              state.copyWith(messages: [...state.messages, existingMessage]),
        );
        scrollToBottom();
      }
      return;
    }

    final message = Message(
      id: secureMessageId,
      chatId: _chatId,
      content: content,
      timestamp: DateTime.now(),
      isFromMe: false,
      status: MessageStatus.delivered,
    );

    await messageRepository.saveMessage(message);

    try {
      await NotificationService.showMessageNotification(
        message: message,
        contactName: displayContactName,
        contactAvatar: null,
      );
    } catch (e, stackTrace) {
      _logger.severe('Failed to show notification: $e', e, stackTrace);
    }

    final shouldAutoScroll = _scrollingController.shouldAutoScrollOnIncoming;

    if (!shouldAutoScroll) {
      await _scrollingController.handleIncomingWhileScrolledAway();
    }

    _updateState(
      (state) => state.copyWith(messages: [...state.messages, message]),
    );

    if (shouldAutoScroll) {
      scrollToBottom();
      _scrollingController.scheduleMarkAsRead();
    }
  }

  Future<void> _processBufferedMessages() async {
    if (_messageBuffer.isEmpty) return;
    final bufferedMessages = List<String>.from(_messageBuffer);
    _messageBuffer.clear();

    for (final content in bufferedMessages) {
      await _addReceivedMessage(content);
    }
  }

  Future<void> sendMessage(String content) async {
    if (content.trim().isEmpty) return;
    try {
      await _messagingViewModel.sendMessage(
        content: content,
        onMessageAdded: (message) {
          _updateState(
            (state) => state.copyWith(messages: [...state.messages, message]),
          );
        },
        onShowSuccess: _showSuccess,
        onShowError: _showError,
        onScrollToBottom: scrollToBottom,
      );
    } catch (e) {
      _logger.severe('Unexpected error in sendMessage: $e');
    }
  }

  Future<void> deleteMessage(String messageId, bool deleteForEveryone) async {
    try {
      await _messagingViewModel.deleteMessage(
        messageId: messageId,
        deleteForEveryone: deleteForEveryone,
        onMessageRemoved: (id) {
          _updateState(
            (state) => state.copyWith(
              messages: state.messages
                  .where((message) => message.id != id)
                  .toList(),
            ),
          );
        },
        onShowSuccess: _showSuccess,
        onShowError: _showError,
      );
    } catch (e) {
      _logger.severe('Unexpected error in deleteMessage: $e');
    }
  }

  void scrollToBottom() {
    _scrollingController.scrollToBottom();
  }

  String _calculateInitialChatId() {
    if (config.isRepositoryMode) {
      return config.chatId!;
    }

    final connectionService = ref.read(connectionServiceProvider);
    final otherPersistentId = connectionService.currentSessionId;

    if (otherPersistentId != null) {
      return ChatUtils.generateChatId(otherPersistentId);
    }

    final deviceId = config.isCentralMode
        ? config.device!.uuid.toString()
        : config.central!.uuid.toString();

    return 'temp_${deviceId.shortId(8)}';
  }

  Future<void> handleIdentityReceived() async {
    final connectionService = ref.read(connectionServiceProvider);
    final otherPersistentId = connectionService.theirPersistentPublicKey;
    if (otherPersistentId == null) return;

    final newChatId = ChatUtils.generateChatId(otherPersistentId);
    if (newChatId == _chatId) return;

    final oldChatId = _chatId;
    final messagesToMigrate = await messageRepository.getMessages(oldChatId);
    if (messagesToMigrate.isNotEmpty) {
      await _migrateMessages(oldChatId, newChatId);
    }
    _chatId = newChatId;
    _cachedContactPublicKey = otherPersistentId;
    _messagingViewModel = ChatMessagingViewModel(
      chatId: _chatId,
      contactPublicKey: otherPersistentId,
      messageRepository: messageRepository,
      contactRepository: contactRepository,
    );

    // Defer disposing the old scroll/search controllers until after the next
    // frame so the ListView has detached from the old ScrollController. This
    // avoids "ScrollController was disposed with one or more ScrollPositions
    // attached" when identity swap happens mid-frame.
    final oldScrollingController = _scrollingController;
    final oldSearchController = _searchController;

    _scrollingController = chat_controller.ChatScrollingController(
      chatsRepository: chatsRepository,
      chatId: _chatId,
      onScrollToBottom: () => _updateState(
        (state) => state.copyWith(newMessagesWhileScrolledUp: 0),
      ),
      onUnreadCountChanged: (count) =>
          _updateState((state) => state.copyWith(unreadMessageCount: count)),
      onStateChanged: _syncScrollState,
    );

    _searchController = ChatSearchController(
      onSearchModeToggled: (isSearchMode) =>
          _updateState((state) => state.copyWith(isSearchMode: isSearchMode)),
      onSearchResultsChanged: _onSearch,
      onNavigateToResult: _navigateToSearchResult,
      scrollController: _scrollingController.scrollController,
    );

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_disposed) return;
      oldSearchController.clear();
      oldScrollingController.dispose();
    });

    _persistentChatManager?.unregisterChatScreen(oldChatId);
    _persistentChatManager?.registerChatScreen(
      _chatId,
      _handlePersistentMessage,
    );

    _updateState((state) => state.copyWith(messages: []));
    await _loadMessages();
  }

  Future<void> _migrateMessages(String oldChatId, String newChatId) async {
    final oldMessages = await messageRepository.getMessages(oldChatId);

    for (final message in oldMessages) {
      final migratedMessage = Message(
        id: message.id,
        chatId: newChatId,
        content: message.content,
        timestamp: message.timestamp,
        isFromMe: message.isFromMe,
        status: message.status,
      );
      await messageRepository.saveMessage(migratedMessage);
    }

    await messageRepository.clearMessages(oldChatId);
    _logger.info(
      'Migrated ${oldMessages.length} messages from $oldChatId to $newChatId',
    );
  }

  void handleConnectionChange(
    ConnectionInfo? previous,
    ConnectionInfo? current,
  ) {
    if (_disposed) return;

    final wasConnected = previous?.isConnected ?? false;
    final isConnected = current?.isConnected ?? false;
    final wasReady = previous?.isReady ?? false;
    final isReady = current?.isReady ?? false;

    if (!wasConnected && isConnected) {
      _showSuccess('Connected to device!');
    } else if (wasConnected && !isConnected) {
      _showError('Device disconnected');
    } else if (isConnected && !wasReady && isReady) {
      _showSuccess('Identity exchange complete!');
      Future.delayed(const Duration(milliseconds: 1000), () {
        if (!_disposed) _autoRetryFailedMessages();
      });
    }

    if (current?.otherUserName != null &&
        current!.otherUserName!.isNotEmpty &&
        previous?.otherUserName != current.otherUserName) {
      handleIdentityReceived();
    }

    if (isConnected) {
      Future.delayed(const Duration(milliseconds: 2500), () {
        if (!_disposed) {
          _autoRetryFailedMessages();
        }
      });
    } else {
      final connectionService = ref.read(connectionServiceProvider);
      if (!connectionService.isPeripheralMode) {
        if (_hasMessagesQueuedForRelay()) {
          _showInfo('Messages queued for relay - maintaining connection');
        } else {
          connectionService.startConnectionMonitoring();
        }
      }
    }
  }

  void _setupContactRequestListener() {
    final connectionService = ref.read(connectionServiceProvider);

    connectionService.setContactRequestCompletedListener((success) {
      if (success && securityStateKey != null) {
        ref.invalidate(securityStateProvider(securityStateKey));
      }
    });

    connectionService.setContactRequestReceivedListener((
      publicKey,
      displayName,
    ) {
      if (!context.mounted) return;

      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Contact Request'),
          content: Text(
            '$displayName wants to add you as a trusted contact. This enables enhanced encryption.',
          ),
          actions: [
            TextButton(
              onPressed: () {
                connectionService.rejectContactRequest();
                Navigator.pop(dialogContext);
              },
              child: const Text('Decline'),
            ),
            FilledButton(
              onPressed: () async {
                Navigator.pop(dialogContext);
                await connectionService.acceptContactRequest();
              },
              child: const Text('Accept'),
            ),
          ],
        ),
      );
    });

    connectionService.setAsymmetricContactListener((publicKey, displayName) {
      handleAsymmetricContact(publicKey, displayName);
    });
  }

  Future<void> handleAsymmetricContact(
    String publicKey,
    String displayName,
  ) async {
    await _pairingDialogController.handleAsymmetricContact(
      publicKey,
      displayName,
    );
  }

  Future<void> addAsVerifiedContact(String publicKey, String displayName) =>
      _pairingDialogController.addAsVerifiedContact(publicKey, displayName);

  void toggleSearchMode() {
    _searchController.toggleSearchMode();
  }

  void _onSearch(String query, List<SearchResult> results) {
    _updateState((state) => state.copyWith(searchQuery: query));
  }

  void _navigateToSearchResult(int messageIndex) {
    _searchController.navigateToSearchResult(
      messageIndex,
      _state.messages.length,
    );
  }

  Future<void> manualReconnection() => _manualReconnection();

  Future<void> retryFailedMessages() => _autoRetryFailedMessages();

  void _showError(String message) {
    _logger.warning('Error: $message');
  }

  void _showInfo(String message) {
    _logger.info('Info: $message');
  }

  void _showSuccess(String message) {
    _logger.info('Success: $message');
  }

  @override
  void dispose() {
    _disposed = true;
    _persistentChatManager?.unregisterChatScreen(_chatId);
    _messageListenerActive = false;
    for (final sub in _managedSubscriptions) {
      sub.cancel();
    }
    _managedSubscriptions.clear();
    _initializationTimeoutTimer?.cancel();
    _scrollingController.dispose();
    _messagingViewModel.dispose();
    _searchController.clear();
    _pairingDialogController.clear();
    _retryHelper.dispose();
    super.dispose();
  }
}

final chatScreenControllerProvider = ChangeNotifierProvider.autoDispose
    .family<ChatScreenController, ChatScreenControllerArgs>((ref, args) {
      final controller = ChatScreenController(args);
      unawaited(controller.initialize());
      return controller;
    });
