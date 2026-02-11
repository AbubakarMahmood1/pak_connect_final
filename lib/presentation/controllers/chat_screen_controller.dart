import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:logging/logging.dart';
import '../../domain/interfaces/i_connection_service.dart';
import '../../domain/models/connection_info.dart';
import '../../domain/services/message_router.dart';
import '../../domain/messaging/offline_message_queue_contract.dart';
import '../../domain/services/message_security.dart';
import '../../domain/services/message_retry_coordinator.dart';
import '../../domain/services/persistent_chat_state_manager.dart';
import 'package:pak_connect/domain/services/security_service_locator.dart';
import '../../domain/utils/chat_utils.dart';
import '../../domain/utils/string_extensions.dart';
import '../../domain/interfaces/i_chats_repository.dart';
import '../../domain/interfaces/i_contact_repository.dart';
import '../../domain/interfaces/i_message_repository.dart';
import '../../domain/interfaces/i_pairing_state_manager.dart';
import '../../domain/entities/message.dart';
import '../../domain/models/mesh_network_models.dart';
import '../../domain/models/security_level.dart';
import '../../domain/interfaces/i_mesh_networking_service.dart';
import '../models/chat_screen_config.dart';
import '../../presentation/controllers/chat_pairing_dialog_controller.dart';
import '../../presentation/controllers/chat_scrolling_controller.dart'
    as chat_controller;
import '../../presentation/controllers/chat_search_controller.dart';
import '../../presentation/controllers/chat_session_lifecycle.dart';
import '../../presentation/models/chat_ui_state.dart';
import '../../presentation/providers/ble_providers.dart';
import '../../presentation/providers/chat_messaging_view_model.dart';
import '../../presentation/providers/mesh_networking_provider.dart';
import '../../presentation/providers/security_state_provider.dart';
import '../widgets/chat_search_bar.dart' show SearchResult;
import '../providers/chat_session_providers.dart';
import '../viewmodels/chat_session_view_model.dart';
import '../notifiers/chat_session_state_notifier.dart';
import 'package:pak_connect/domain/values/id_types.dart';

class ChatScreenControllerArgs {
  const ChatScreenControllerArgs({
    required this.ref,
    required this.context,
    required this.config,
    required this.messageRepository,
    required this.contactRepository,
    required this.chatsRepository,
    this.persistentChatManager,
    this.retryCoordinator,
    this.messagingViewModel,
    this.repositoryRetryHandler,
    this.pairingDialogController,
    this.messageRouter,
    this.sessionViewModel,
    this.sessionLifecycle,
    this.stateStore,
    required this.messagingViewModelFactory,
    required this.scrollingControllerFactory,
    required this.searchControllerFactory,
    required this.pairingControllerFactory,
    required this.sessionViewModelFactory,
    required this.sessionLifecycleFactory,
  });

  final WidgetRef ref;
  final BuildContext context;
  final ChatScreenConfig config;
  final IMessageRepository messageRepository;
  final IContactRepository contactRepository;
  final IChatsRepository chatsRepository;
  final PersistentChatStateManager? persistentChatManager;
  final MessageRetryCoordinator? retryCoordinator;
  final ChatMessagingViewModel? messagingViewModel;
  final Future<void> Function(Message message)? repositoryRetryHandler;
  final ChatPairingDialogController? pairingDialogController;
  final MessageRouter? messageRouter;
  final ChatSessionViewModel? sessionViewModel;
  final ChatSessionLifecycle? sessionLifecycle;
  final ChatSessionStateStore? stateStore;
  final ChatMessagingViewModel Function(ChatId chatId, String contactPublicKey)
  messagingViewModelFactory;
  final chat_controller.ChatScrollingController Function(
    ChatId chatId,
    VoidCallback onScrollToBottom,
    Function(int) onUnreadCountChanged,
    VoidCallback onStateChanged,
  )
  scrollingControllerFactory;
  final ChatSearchController Function(
    void Function(bool) onSearchModeToggled,
    void Function(String, List<SearchResult>) onSearchResultsChanged,
    void Function(int) onNavigateToResult,
    ScrollController scrollController,
  )
  searchControllerFactory;
  final ChatPairingDialogController Function(
    BuildContext context,
    IConnectionService connectionService,
    IContactRepository contactRepository,
    NavigatorState navigator,
    IPairingStateManager stateManager,
    void Function(bool success) onPairingCompleted,
    void Function(String) onPairingError,
    void Function(String) onPairingSuccess,
  )
  pairingControllerFactory;
  final ChatSessionViewModel Function({
    required ChatScreenConfig config,
    required IMessageRepository messageRepository,
    required IContactRepository contactRepository,
    required IChatsRepository chatsRepository,
    required ChatMessagingViewModel messagingViewModel,
    required chat_controller.ChatScrollingController scrollingController,
    required ChatSearchController searchController,
    required ChatPairingDialogController pairingDialogController,
    MessageRetryCoordinator? retryCoordinator,
    ChatSessionLifecycle? sessionLifecycle,
    String Function()? displayContactNameFn,
    String? Function()? getContactPublicKeyFn,
    String Function()? getChatIdFn,
    void Function(String)? onChatIdUpdated,
    void Function(String?)? onContactPublicKeyUpdated,
    void Function()? onScrollToBottom,
    void Function(String)? onShowError,
    void Function(String)? onShowSuccess,
    void Function(String)? onShowInfo,
    bool Function()? isDisposedFn,
    void Function({
      required ChatMessagingViewModel messagingViewModel,
      required chat_controller.ChatScrollingController scrollingController,
      required ChatSearchController searchController,
      ChatMessagingViewModel? previousMessagingViewModel,
      chat_controller.ChatScrollingController? previousScrollingController,
      ChatSearchController? previousSearchController,
    })?
    onControllersRebound,
    IConnectionService Function()? getConnectionServiceFn,
  })
  sessionViewModelFactory;
  final ChatSessionLifecycle Function({
    required ChatSessionViewModel viewModel,
    required IConnectionService connectionService,
    required IMeshNetworkingService meshService,
    MessageRouter? messageRouter,
    required MessageSecurity messageSecurity,
    required IMessageRepository messageRepository,
    MessageRetryCoordinator? retryCoordinator,
    OfflineMessageQueueContract? offlineQueue,
    Logger? logger,
  })
  sessionLifecycleFactory;
}

/// Coordinates all non-UI chat behaviors so the widget can stay lean.
class ChatScreenController extends ChangeNotifier {
  final ChatScreenControllerArgs _args;
  final _logger = Logger('ChatScreenController');
  final WidgetRef ref;
  final BuildContext context;
  final ChatScreenConfig config;
  final IMessageRepository messageRepository;
  final IContactRepository contactRepository;
  final IChatsRepository chatsRepository;
  late final Future<void> Function(Message message) _repositoryRetryHandler;
  final MessageRouter? _injectedMessageRouter;
  final ChatPairingDialogController? _injectedPairingController;
  final MessageRetryCoordinator? _initialRetryCoordinator;

  late ChatMessagingViewModel _messagingViewModel;
  late chat_controller.ChatScrollingController _scrollingController;
  late ChatSearchController _searchController;
  late ChatPairingDialogController _pairingDialogController;
  late ChatSessionViewModel _sessionViewModel;
  late ChatSessionLifecycle _sessionLifecycle;
  late final ChatSessionStateStore _stateStore;

  bool _initialized = false;

  ChatId _chatId = ChatId('pending_chat_id');
  String? _cachedContactPublicKey;
  bool _disposed = false;
  bool _waitingForConnection = false;
  StreamSubscription<ConnectionInfo>? _connectionInfoSub;
  void Function(ChatUIState)? _stateListener;
  void Function()? _disposeStateListener;

  ChatScreenController(ChatScreenControllerArgs args)
    : _args = args,
      ref = args.ref,
      context = args.context,
      config = args.config,
      messageRepository = args.messageRepository,
      contactRepository = args.contactRepository,
      chatsRepository = args.chatsRepository,
      _injectedMessageRouter = args.messageRouter,
      _injectedPairingController = args.pairingDialogController,
      _initialRetryCoordinator = args.retryCoordinator {
    _chatId = _calculateInitialChatId();
    _cachedContactPublicKey = _contactPublicKey;
    _stateStore =
        args.stateStore ??
        ref.read(chatSessionStateStoreProvider(_args).notifier);
    _stateStore.markMounted(true);
    _stateListener = (newState) {
      if (_disposed) return;
      _publishStateToOwnedNotifier(newState);
      notifyListeners();
    };
    _disposeStateListener = _stateStore.addListener(
      _stateListener!,
      fireImmediately: false,
    );
    _initializeControllers(messagingViewModel: args.messagingViewModel);
    _repositoryRetryHandler =
        _args.repositoryRetryHandler ??
        _sessionViewModel.retryRepositoryMessage;
    _sessionViewModel.bindStateStore(_stateStore);
    _sessionLifecycle.configureRetryHelper(
      ref: ref,
      config: config,
      chatId: () => _chatId.value,
      contactPublicKey: () => _contactPublicKey,
      displayContactName: () => displayContactName,
      messageRepository: messageRepository,
      repositoryRetryHandler: _repositoryRetryHandler,
      showSuccess: _showSuccess,
      showError: _showError,
      showInfo: _showInfo,
      scrollToBottom: _sessionViewModel.scrollToBottom,
      getMessages: () => state.messages,
    );
    _sessionLifecycle.persistentChatManager =
        _args.persistentChatManager ??
        ref.read(persistentChatStateManagerProvider);
    _publishInitialState();

    // Ensure messaging VM has the latest recipient key once available.
    final key = _contactPublicKey;
    if (key != null && key.isNotEmpty) {
      _messagingViewModel.updateRecipientKey(key);
    }
  }

  ChatUIState get state => _stateStore.current;
  String get chatId => _chatId.value;
  chat_controller.ChatScrollingController get scrollingController =>
      _scrollingController;
  ChatSearchController get searchController => _searchController;
  ChatPairingDialogController get pairingDialogController =>
      _pairingDialogController;
  ChatSessionViewModel get sessionViewModel => _sessionViewModel;
  ChatSessionLifecycle get sessionLifecycle => _sessionLifecycle;
  ChatScreenControllerArgs get args => _args;

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
    final connectionService = ref.read(connectionServiceProvider);
    final publicKey =
        config.contactPublicKey ??
        ChatUtils.resolveChatKey(
          persistentPublicKey: connectionService.theirPersistentKey,
          currentSessionId: connectionService.currentSessionId,
          currentEphemeralId: connectionService.theirEphemeralId,
        );

    return (publicKey != null && publicKey.isNotEmpty)
        ? publicKey
        : connectionService.currentSessionId;
  }

  String? get _contactPublicKey {
    final configKey = config.contactPublicKey;
    if (configKey != null && configKey.isNotEmpty) {
      _cachedContactPublicKey = configKey;
      return configKey;
    }

    final connectionService = ref.read(connectionServiceProvider);
    final resolved = ChatUtils.resolveChatKey(
      persistentPublicKey: connectionService.theirPersistentKey,
      currentSessionId: connectionService.currentSessionId,
      currentEphemeralId: connectionService.theirEphemeralId,
    );

    if (resolved != null && resolved.isNotEmpty) {
      _cachedContactPublicKey = resolved;
      return resolved;
    }

    return _cachedContactPublicKey;
  }

  UserId? get _contactUserId {
    final key = _contactPublicKey;
    if (key == null || key.isEmpty) return null;
    return UserId(key);
  }

  void _initializeControllers({ChatMessagingViewModel? messagingViewModel}) {
    _messagingViewModel =
        messagingViewModel ??
        _args.messagingViewModel ??
        _args.messagingViewModelFactory.call(_chatId, _contactPublicKey ?? '');

    _scrollingController = _args.scrollingControllerFactory.call(
      _chatId,
      () => _stateStore.clearNewWhileScrolledUp(),
      (count) => _stateStore.setUnreadCount(count),
      () => _sessionViewModel.onScrollStateChanged(),
    );

    _searchController = _args.searchControllerFactory.call(
      (isSearchMode) => _stateStore.setSearchMode(isSearchMode),
      (query, _) => _sessionViewModel.onSearchResultsChanged(query),
      (messageIndex) =>
          _sessionViewModel.onNavigateToSearchResultIndex(messageIndex),
      _scrollingController.scrollController,
    );

    final connectionService = ref.read(connectionServiceProvider);
    _pairingDialogController =
        _injectedPairingController ??
        _args.pairingControllerFactory.call(
          context,
          connectionService,
          contactRepository,
          Navigator.of(context),
          _resolvePairingStateManager(connectionService),
          (success) {
            if (success && securityStateKey != null) {
              ref.invalidate(securityStateProvider(securityStateKey));
            }
          },
          _showError,
          _showSuccess,
        );

    _sessionViewModel =
        _args.sessionViewModel ??
        _args.sessionViewModelFactory.call(
          config: config,
          messageRepository: messageRepository,
          contactRepository: contactRepository,
          chatsRepository: chatsRepository,
          messagingViewModel: _messagingViewModel,
          scrollingController: _scrollingController,
          searchController: _searchController,
          pairingDialogController: _pairingDialogController,
          retryCoordinator: _initialRetryCoordinator,
          sessionLifecycle: null,
          displayContactNameFn: () => displayContactName,
          getContactPublicKeyFn: () => _contactPublicKey,
          getChatIdFn: () => _chatId.value,
          onChatIdUpdated: (newChatId) => _chatId = ChatId(newChatId),
          onContactPublicKeyUpdated: (newKey) {
            _cachedContactPublicKey = newKey;
            if (newKey != null && newKey.isNotEmpty) {
              _messagingViewModel.updateRecipientKey(newKey);
            }
          },
          onScrollToBottom: () => _scrollingController.scrollToBottom(),
          onShowError: _showError,
          onShowSuccess: _showSuccess,
          onShowInfo: _showInfo,
          isDisposedFn: () => _disposed,
          onControllersRebound:
              ({
                required messagingViewModel,
                required scrollingController,
                required searchController,
                ChatMessagingViewModel? previousMessagingViewModel,
                chat_controller.ChatScrollingController?
                previousScrollingController,
                ChatSearchController? previousSearchController,
              }) => _handleControllersRebound(
                messagingViewModel: messagingViewModel,
                scrollingController: scrollingController,
                searchController: searchController,
                previousMessagingViewModel: previousMessagingViewModel,
                previousScrollingController: previousScrollingController,
                previousSearchController: previousSearchController,
              ),
          getConnectionServiceFn: () => ref.read(connectionServiceProvider),
        );

    _sessionLifecycle =
        _args.sessionLifecycle ??
        _args.sessionLifecycleFactory.call(
          viewModel: _sessionViewModel,
          connectionService: connectionService,
          meshService: ref.read(meshNetworkingServiceProvider),
          messageRouter: _injectedMessageRouter,
          messageSecurity: MessageSecurity(),
          messageRepository: messageRepository,
          retryCoordinator: _initialRetryCoordinator,
          offlineQueue: null,
          logger: _logger,
        );
    _sessionLifecycle.pairingController = _pairingDialogController;
    // Phase 6A: Set lifecycle reference on ViewModel after creation
    _sessionViewModel.sessionLifecycle = _sessionLifecycle;
  }

  IPairingStateManager _resolvePairingStateManager(
    IConnectionService connectionService,
  ) {
    if (_injectedPairingController != null) {
      return _injectedPairingController.stateManager;
    }

    try {
      final dynamic maybeWithManager = connectionService;
      final manager = maybeWithManager.stateManager;
      if (manager is IPairingStateManager) {
        return manager;
      }
      // Best effort: some facades expose legacyStateManager dynamically.
      try {
        final dynamic dynamicManager = manager;
        final legacy = dynamicManager.legacyStateManager;
        if (legacy is IPairingStateManager) {
          return legacy;
        }
      } catch (_) {}
    } catch (_) {
      // Fall back below when the connection service doesn't expose stateManager.
    }

    _logger.warning(
      'Pairing state manager not exposed by connection service; using no-op fallback',
    );
    return const _NoopPairingStateManager();
  }

  Future<void> initialize({bool logChatOpen = true}) async {
    if (_disposed || _initialized) return;
    final connectionService = ref.read(connectionServiceProvider);
    final connectionInfo = connectionService.currentConnectionInfo;
    final hasContactKey =
        _contactPublicKey != null && _contactPublicKey!.isNotEmpty;

    if (!config.isRepositoryMode &&
        (!connectionInfo.isReady || !hasContactKey)) {
      _logger.warning(
        'Chat initialization deferred: connection not ready or missing key',
      );
      if (!_waitingForConnection) {
        _waitingForConnection = true;
        _connectionInfoSub ??= connectionService.connectionInfo.listen((
          info,
        ) async {
          if (_disposed || _initialized || !context.mounted) return;
          final keyReady =
              _contactPublicKey != null && _contactPublicKey!.isNotEmpty;
          if (info.isReady && keyReady) {
            await _connectionInfoSub?.cancel();
            _connectionInfoSub = null;
            _waitingForConnection = false;
            unawaited(initialize(logChatOpen: false));
          }
        });
      }
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_disposed) return;
        _stateStore.setInitializationStatus('Waiting for connection...');
      });
      return;
    } else {
      _waitingForConnection = false;
      await _connectionInfoSub?.cancel();
      _connectionInfoSub = null;
    }

    if (logChatOpen) {
      await _logChatOpenState();
      if (_disposed || !context.mounted) return;
    }
    await _loadMessages();
    if (_disposed || !context.mounted) return;

    final connectionInfoAsync = ref.read(connectionInfoProvider);
    final meshStatusAsync = ref.read(meshNetworkStatusProvider);

    await _sessionLifecycle.startSession(
      chatId: _chatId,
      stateStore: _stateStore,
      incomingStream: () =>
          ref.read(connectionServiceProvider).receivedMessages,
      context: context,
      disposed: () => _disposed,
      mounted: () => context.mounted,
      onSecurityStateInvalidate: () {
        final key = securityStateKey;
        if (key != null) {
          ref.invalidate(securityStateProvider(key));
        }
      },
      meshStatusAsync: meshStatusAsync,
      connectionInfoAsync: connectionInfoAsync,
      onSuccessMessage: _showSuccess,
      onMessage: (content) => _sessionViewModel.addReceivedMessage(content),
      onProcessBufferedMessages: () =>
          _sessionViewModel.processBufferedMessages(),
      onDelivered: (messageId, status) =>
          _updateMessageStatus(messageId, status),
    );
    if (_disposed || !context.mounted) return;
    _initialized = true;
  }

  /// Publishes state to both local controller and provider-owned notifier.
  void publishState(ChatUIState newState) {
    if (_disposed) return;
    _stateStore.replace(newState);
  }

  void _publishStateToOwnedNotifier(ChatUIState newState) {
    if (_disposed || !context.mounted) return;
    // Publish state for provider consumers.
    final ownedState = ref.read(
      chatSessionOwnedStateNotifierProvider(_args).notifier,
    );
    ownedState.replace(newState);
  }

  void _publishInitialState() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_disposed || !context.mounted) return;
      _stateListener?.call(_stateStore.current);
    });
  }

  void _handleControllersRebound({
    required ChatMessagingViewModel messagingViewModel,
    required chat_controller.ChatScrollingController scrollingController,
    required ChatSearchController searchController,
    ChatMessagingViewModel? previousMessagingViewModel,
    chat_controller.ChatScrollingController? previousScrollingController,
    ChatSearchController? previousSearchController,
  }) {
    final scrollChanged =
        previousScrollingController != null &&
        previousScrollingController != scrollingController;
    final searchChanged =
        previousSearchController != null &&
        previousSearchController != searchController;
    final messagingChanged =
        previousMessagingViewModel != null &&
        previousMessagingViewModel != messagingViewModel;

    _messagingViewModel = messagingViewModel;
    _scrollingController = scrollingController;
    _searchController = searchController;

    if (!scrollChanged && !searchChanged && !messagingChanged) {
      return;
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_disposed) return;
      if (searchChanged) {
        previousSearchController.clear();
      }
      if (scrollChanged) {
        previousScrollingController.dispose();
      }
      if (messagingChanged) {
        previousMessagingViewModel.dispose();
      }
    });
  }

  Future<void> _logChatOpenState() async {
    final configKey = config.contactPublicKey;
    final userId =
        _contactUserId ??
        (configKey != null && configKey.isNotEmpty ? UserId(configKey) : null);
    if (userId == null) {
      _logger.warning('Chat open with no public key available');
      return;
    }

    final contact = await contactRepository.getContactByUserId(userId);
    final securityLevel = await SecurityServiceLocator.instance.getCurrentLevel(
      userId.value,
      contactRepository,
    );
    final encryptionMethod = await SecurityServiceLocator.instance
        .getEncryptionMethod(userId.value, contactRepository);

    _logger.info(
      'Chat open: ${config.contactName ?? "Unknown"} | Security=${securityLevel.name} | Encryption=${encryptionMethod.type.name}',
    );
    if (kDebugMode) {
      final ephPresent = contact?.currentEphemeralId != null;
      final sessionPresent = contact?.sessionIdForNoise != null;
      _logger.info(
        'event=chat_key_state_debug hasPublicKey=true hasCurrentEphemeralId=$ephPresent hasNoiseSessionId=$sessionPresent',
      );
    }
  }

  void _updateMessageStatus(MessageId messageId, MessageStatus newStatus) {
    // Phase 6A: Delegate to ViewModel
    final currentState = _stateStore.current;
    final newState = _sessionViewModel.applyMessageStatus(
      currentState,
      messageId,
      newStatus,
    );
    _stateStore.setMessages(newState.messages);
  }

  @visibleForTesting
  void applyMessageUpdate(Message updatedMessage) {
    // Phase 6A: Delegate to ViewModel
    final currentState = _stateStore.current;
    final newState = _sessionViewModel.applyMessageUpdate(
      currentState,
      updatedMessage,
    );
    _stateStore.setMessages(newState.messages);
  }

  void handleMeshInitializationStatusChange(
    AsyncValue<MeshNetworkStatus>? previous,
    AsyncValue<MeshNetworkStatus> next,
  ) {
    if (_disposed) return;
    _sessionLifecycle.handleMeshStatus(
      statusAsync: next,
      isCurrentlyInitializing: _stateStore.current.meshInitializing,
      updateState: _stateStore.update,
      onSuccessMessage: _showSuccess,
    );
  }

  Future<void> userRequestedPairing() async {
    final connectionService = ref.read(connectionServiceProvider);
    final connectionInfoAsync = ref.read(connectionInfoProvider);
    final connectionInfo =
        connectionInfoAsync.value ?? connectionService.currentConnectionInfo;

    await _sessionLifecycle.requestPairing(
      connectionInfo: connectionInfo,
      onErrorMessage: _showError,
    );
  }

  Future<void> _manualReconnection() => _sessionLifecycle.manualReconnection(
    disposed: () => _disposed,
    onSuccessMessage: _showSuccess,
    onErrorMessage: _showError,
  );

  Future<void> _loadMessages() async {
    // Phase 6A: Delegate to ViewModel
    await _sessionViewModel.loadMessages();
  }

  Future<void> sendMessage(String content) async {
    // Phase 6A: Delegate to ViewModel
    await _sessionViewModel.sendMessage(content);
  }

  Future<void> deleteMessage(
    MessageId messageId,
    bool deleteForEveryone,
  ) async {
    // Phase 6A: Delegate to ViewModel
    await _sessionViewModel.deleteMessage(messageId, deleteForEveryone);
  }

  ChatId _calculateInitialChatId() {
    // Fallback calculation that does not depend on ViewModel initialization
    if (config.isRepositoryMode && config.chatId != null) {
      return ChatId(config.chatId!);
    }

    final explicitKey = config.contactPublicKey;
    if (explicitKey != null && explicitKey.isNotEmpty) {
      return ChatId(ChatUtils.generateChatId(explicitKey));
    }

    final connectionService = ref.read(connectionServiceProvider);
    final sessionId = connectionService.currentSessionId;
    if (sessionId != null && sessionId.isNotEmpty) {
      return ChatId(ChatUtils.generateChatId(sessionId));
    }

    // Fallback to device/central UUIDs if available (prevents collision)
    if (config.isCentralMode && config.device != null) {
      return ChatId(ChatUtils.generateChatId(config.device!.uuid.toString()));
    }
    if (config.isPeripheralMode && config.central != null) {
      return ChatId(ChatUtils.generateChatId(config.central!.uuid.toString()));
    }

    // Last resort: placeholder ID (will be replaced once identity is resolved)
    return ChatId('pending_chat_id');
  }

  Future<void> handleIdentityReceived() async {
    await _sessionViewModel.handleIdentityReceived();
  }

  void handleConnectionChange(
    ConnectionInfo? previous,
    ConnectionInfo? current,
  ) {
    _sessionLifecycle.handleConnectionChange(
      previous: previous,
      current: current,
      disposed: () => _disposed,
      onIdentityReceived: handleIdentityReceived,
      onSuccessMessage: _showSuccess,
      onErrorMessage: _showError,
      contactPublicKey: _contactPublicKey ?? _chatId.value,
      onInfoMessage: _showInfo,
    );
    final key = _contactPublicKey;
    if (key != null && key.isNotEmpty) {
      _messagingViewModel.updateRecipientKey(key);
    }
    if (current?.isConnected == true &&
        !_sessionLifecycle.messageListenerActive) {
      unawaited(
        _sessionLifecycle
            .startMessageListener(
              chatId: _chatId,
              incomingStream: () =>
                  ref.read(connectionServiceProvider).receivedMessages,
              persistentManager: _sessionLifecycle.persistentChatManager,
              disposed: () => _disposed,
              onMessage: (content) =>
                  _sessionViewModel.addReceivedMessage(content),
            )
            .then((_) => _sessionViewModel.processBufferedMessages()),
      );
    }
  }

  Future<void> handleAsymmetricContact(
    String publicKey,
    String displayName,
  ) async {
    await _sessionLifecycle.handleAsymmetricContact(publicKey, displayName);
  }

  Future<void> addAsVerifiedContact(String publicKey, String displayName) =>
      _sessionLifecycle.addAsVerifiedContact(publicKey, displayName);

  Future<void> manualReconnection() => _manualReconnection();

  Future<void> retryFailedMessages() {
    // Phase 6A: Delegate to ViewModel
    return _sessionViewModel.retryFailedMessages();
  }

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
    _stateStore.markMounted(false);
    _disposeStateListener?.call();
    _sessionLifecycle.unregisterPersistentListener(_chatId);
    _sessionLifecycle.messageListenerActive = false;
    _connectionInfoSub?.cancel();
    _scrollingController.dispose();
    _messagingViewModel.dispose();
    _searchController.clear();
    _pairingDialogController.clear();
    _sessionLifecycle.dispose();
    super.dispose();
  }
}

final chatScreenControllerProvider = ChangeNotifierProvider.autoDispose
    .family<ChatScreenController, ChatScreenControllerArgs>((ref, args) {
      final controller = ChatScreenController(args);
      unawaited(controller.initialize());
      return controller;
    });

class _NoopPairingStateManager implements IPairingStateManager {
  const _NoopPairingStateManager();

  @override
  void clearPairing() {}

  @override
  Future<bool> completePairing(String theirCode) async => false;

  @override
  Future<bool> confirmSecurityUpgrade(
    String publicKey,
    SecurityLevel newLevel,
  ) async => false;

  @override
  String generatePairingCode() => '';
}
