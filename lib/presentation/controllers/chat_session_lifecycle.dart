import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logging/logging.dart';
import 'package:get_it/get_it.dart';

import '../../domain/interfaces/i_connection_service.dart';
import '../../domain/interfaces/i_mesh_networking_service.dart';
import '../../domain/interfaces/i_shared_message_queue_provider.dart';
import '../../domain/services/message_router.dart';
import '../../domain/messaging/offline_message_queue_contract.dart';
import '../../domain/models/connection_info.dart';
import '../../domain/services/message_security.dart';
import '../../domain/services/message_retry_coordinator.dart';
import '../../domain/services/persistent_chat_state_manager.dart';
import '../../domain/interfaces/i_message_repository.dart';
import '../../domain/entities/message.dart';
import '../../domain/models/mesh_network_models.dart';
import '../../domain/values/id_types.dart';
import '../models/chat_screen_config.dart';
import '../controllers/chat_retry_helper.dart';
import '../controllers/chat_pairing_dialog_controller.dart';
import '../models/chat_ui_state.dart';
import '../notifiers/chat_session_state_notifier.dart';
import '../viewmodels/chat_session_view_model.dart';
import '../widgets/contact_request_dialog.dart';

/// Planned lifecycle manager for ChatScreen orchestration.
/// Responsible for subscriptions, buffering, retry coordination, pairing hooks,
/// and persistence once migration moves logic out of ChatScreenController.
class ChatSessionLifecycle {
  ChatSessionLifecycle({
    required this.viewModel,
    required this.connectionService,
    required this.meshService,
    MessageRouter? messageRouter,
    required this.messageSecurity,
    required this.messageRepository,
    this.retryCoordinator,
    this.offlineQueue,
    Logger? logger,
  }) : _logger = logger ?? Logger('ChatSessionLifecycle') {
    this.messageRouter =
        messageRouter ?? _resolveMessageRouter(connectionService);
  }

  final ChatSessionViewModel viewModel;
  final IConnectionService connectionService;
  final IMeshNetworkingService meshService;
  late final MessageRouter? messageRouter;
  final MessageSecurity messageSecurity;
  final IMessageRepository messageRepository;
  final MessageRetryCoordinator? retryCoordinator;
  final OfflineMessageQueueContract? offlineQueue;
  final Logger _logger;
  ChatRetryHelper? retryHelper;
  ChatPairingDialogController? pairingController;

  final List<StreamSubscription<dynamic>> _managedSubscriptions = [];
  StreamSubscription<String>? _deliverySubscription;
  StreamSubscription<dynamic>? _messageSubscription;
  bool messageListenerActive = false;
  final List<String> messageBuffer = [];
  Timer? _initializationTimeoutTimer;
  Timer? _delayedRetryTimer;
  PersistentChatStateManager? persistentChatManager;
  OfflineMessageQueueContract? _fallbackOfflineQueue;
  bool _fallbackQueueInitialized = false;
  Future<void>? _fallbackQueueInitFuture;

  /// Placeholder init hook; real logic will move here during migration.
  Future<void> initialize() async {
    _logger.fine('ChatSessionLifecycle initialize (scaffold)');
  }

  /// Placeholder send hook; will orchestrate routing and retry later.
  Future<void> onSend(Message message) async {
    _logger.fine(
      'ChatSessionLifecycle onSend (scaffold) for ${message.id.value}',
    );
  }

  /// Subscribe to mesh delivery stream and notify caller on delivery.
  void setupDeliveryListener({
    required void Function(MessageId messageId) onDelivered,
  }) {
    try {
      _deliverySubscription = meshService.messageDeliveryStream.listen(
        (id) => onDelivered(MessageId(id)),
      );
      _managedSubscriptions.add(_deliverySubscription!);
    } catch (e) {
      _logger.warning('Failed to set up delivery listener: $e');
    }
  }

  /// Track subscriptions that should be cancelled with the lifecycle.
  void trackSubscription(StreamSubscription<dynamic> subscription) {
    _managedSubscriptions.add(subscription);
  }

  /// Activate the message listener with buffering semantics.
  void activateMessageListener(Stream<String> messageStream) {
    if (messageListenerActive) return;
    messageListenerActive = true;
    _messageSubscription = messageStream.listen((content) {
      if (messageListenerActive) {
        messageBuffer.add(content);
      }
    });
    _managedSubscriptions.add(_messageSubscription!);
  }

  /// Attach a direct message stream with buffering when disposed.
  void attachMessageStream({
    required Stream<String> stream,
    required bool Function() disposed,
    required bool Function() isActive,
    required Future<void> Function(String content) onMessage,
  }) {
    _messageSubscription = stream.listen((content) {
      if (!disposed() && isActive()) {
        unawaited(onMessage(content));
      } else if (disposed()) {
        messageBuffer.add(content);
      }
    });
    _managedSubscriptions.add(_messageSubscription!);
  }

  /// Flush buffered messages through the provided handler.
  Future<void> processBufferedMessages(
    Future<void> Function(String content) onMessage,
  ) async {
    if (messageBuffer.isEmpty) return;
    final buffered = List<String>.from(messageBuffer);
    messageBuffer.clear();
    for (final content in buffered) {
      await onMessage(content);
    }
  }

  /// Handle mesh initialization status updates and banner timeout.
  void handleMeshStatus({
    required AsyncValue<MeshNetworkStatus> statusAsync,
    required bool isCurrentlyInitializing,
    required void Function(ChatUIState Function(ChatUIState)) updateState,
    required void Function(String) onSuccessMessage,
    void Function(String message)? onWarningMessage,
  }) {
    statusAsync.when(
      data: (status) {
        if (status.isInitialized && isCurrentlyInitializing) {
          _initializationTimeoutTimer?.cancel();
          updateState(
            (state) => state.copyWith(
              meshInitializing: false,
              initializationStatus: 'Ready',
            ),
          );
          onSuccessMessage('Mesh networking ready');
        } else if (!status.isInitialized && !isCurrentlyInitializing) {
          updateState(
            (state) => state.copyWith(initializationStatus: 'Initializing...'),
          );
        }
      },
      loading: () {
        if (!isCurrentlyInitializing) {
          updateState(
            (state) => state.copyWith(
              meshInitializing: true,
              initializationStatus: 'Initializing mesh network...',
            ),
          );
        }
      },
      error: (error, stack) {
        updateState(
          (state) => state.copyWith(
            meshInitializing: false,
            initializationStatus: 'Initialization failed',
          ),
        );
        _logger.severe('Mesh initialization error: $error');
        onWarningMessage?.call('Mesh status error - skipping banner: $error');
      },
    );
  }

  /// Start a mesh initialization timeout with fallback messaging.
  void startInitializationTimeout({
    required bool isCheckingStatus,
    required bool Function() disposed,
    required bool Function() stillInitializing,
    required void Function(ChatUIState Function(ChatUIState)) updateState,
    required void Function(String) onSuccessMessage,
  }) {
    _initializationTimeoutTimer?.cancel();
    final timeoutDuration = isCheckingStatus
        ? const Duration(seconds: 3)
        : const Duration(seconds: 15);

    _initializationTimeoutTimer = Timer(timeoutDuration, () {
      if (disposed() || !stillInitializing()) return;
      _logger.info('Mesh initialization timeout reached - hiding banner');
      updateState(
        (state) => state.copyWith(
          meshInitializing: false,
          initializationStatus: 'Ready (timeout fallback)',
        ),
      );
      onSuccessMessage('Mesh networking ready (fallback mode)');
    });
  }

  /// Placeholder dispose hook; will close subscriptions after migration.
  void dispose() {
    _deliverySubscription?.cancel();
    _messageSubscription?.cancel();
    _initializationTimeoutTimer?.cancel();
    _delayedRetryTimer?.cancel();
    messageListenerActive = false;
    retryHelper?.dispose();
    for (final sub in _managedSubscriptions) {
      sub.cancel();
    }
    _managedSubscriptions.clear();
  }

  /// Schedule an auto-retry after a delay, respecting disposal.
  void scheduleAutoRetry({
    required Duration delay,
    required bool Function() disposed,
    required Future<void> Function() onRetry,
  }) {
    _delayedRetryTimer?.cancel();
    _delayedRetryTimer = Timer(delay, () {
      if (disposed()) return;
      unawaited(onRetry());
    });
  }

  Future<void> autoRetryFailedMessages() async {
    if (retryHelper == null) return;
    await retryHelper!.autoRetryFailedMessages();
  }

  Future<void> fallbackRetryFailedMessages() async {
    if (retryHelper == null) return;
    await retryHelper!.fallbackRetryFailedMessages();
  }

  void ensureRetryCoordinator() {
    retryHelper?.ensureRetryCoordinator();
  }

  bool hasMessagesQueuedForRelay(String? recipientPublicKey) {
    if (recipientPublicKey == null || recipientPublicKey.isEmpty) return false;
    try {
      final queue = offlineQueue ?? resolveOfflineQueue();
      if (queue == null) return false;
      final queuedMessages = queue.getPendingMessages();
      final chatMessages = queuedMessages.where(
        (msg) => msg.recipientPublicKey == recipientPublicKey,
      );
      return chatMessages.isNotEmpty;
    } catch (e) {
      _logger.warning('Error checking relay queue: $e');
      return false;
    }
  }

  OfflineMessageQueueContract? resolveOfflineQueue() {
    if (offlineQueue != null) {
      return offlineQueue;
    }
    final sharedQueue = _tryResolveSharedQueue();
    if (sharedQueue != null) {
      return sharedQueue;
    }

    try {
      return MessageRouter.instance.offlineQueue;
    } catch (_) {}

    _logger.fine('Using standalone OfflineMessageQueue fallback');
    return _getFallbackQueue();
  }

  OfflineMessageQueueContract? _tryResolveSharedQueue() {
    if (!GetIt.instance.isRegistered<ISharedMessageQueueProvider>()) {
      _logger.fine('Shared queue provider not registered');
      return null;
    }

    final provider = GetIt.instance<ISharedMessageQueueProvider>();
    if (!provider.isInitialized && !provider.isInitializing) {
      _logger.fine('Shared queue host not initialized; queue unavailable');
      return null;
    }

    try {
      return provider.messageQueue;
    } catch (error) {
      _logger.warning('Failed to access shared offline queue: $error');
      return null;
    }
  }

  Future<OfflineMessageQueueContract> _buildFallbackOfflineQueue() async {
    final queue = _getFallbackQueue(ensureInitialized: true);
    if (_fallbackQueueInitFuture != null) {
      try {
        await _fallbackQueueInitFuture;
      } catch (error, stack) {
        _logger.warning(
          'Fallback offline queue initialization failed: $error',
          stack,
        );
      }
    }
    return queue;
  }

  OfflineMessageQueueContract _getFallbackQueue({
    bool ensureInitialized = false,
  }) {
    _fallbackOfflineQueue ??= MessageRouter.createStandaloneQueue();
    if (_fallbackQueueInitFuture == null && !_fallbackQueueInitialized) {
      _fallbackQueueInitialized = true;
      _fallbackQueueInitFuture = _fallbackOfflineQueue!.initialize();
      if (!ensureInitialized) {
        _fallbackQueueInitFuture!.catchError((error, stack) {
          _logger.warning(
            'Fallback offline queue initialization failed: $error',
            stack,
          );
        });
      }
    } else if (ensureInitialized && _fallbackQueueInitFuture == null) {
      _fallbackQueueInitFuture = _fallbackOfflineQueue!.initialize();
    }
    return _fallbackOfflineQueue!;
  }

  Future<OfflineMessageQueueContract> buildFallbackOfflineQueue() =>
      _buildFallbackOfflineQueue();

  MessageRouter? _resolveMessageRouter(IConnectionService connectionService) {
    try {
      return MessageRouter.instance;
    } on StateError {
      _logger.warning(
        'MessageRouter not initialized; attempting on-demand initialization',
      );
      try {
        final fallbackQueue = resolveOfflineQueue();
        unawaited(
          MessageRouter.initialize(
            connectionService,
            offlineQueue: fallbackQueue,
            fallbackQueueBuilder: _buildFallbackOfflineQueue,
          ),
        );
        return MessageRouter.instance;
      } catch (error, stack) {
        _logger.warning(
          'MessageRouter initialization failed; routing hooks disabled: $error',
          stack,
        );
        return null;
      }
    }
  }

  List<QueuedMessage> getQueuedMessagesForChat() {
    try {
      final queue = resolveOfflineQueue();
      if (queue == null) return const [];
      return queue.getPendingMessages();
    } catch (e) {
      _logger.fine('Unable to fetch queued messages: $e');
      return const [];
    }
  }

  void configureRetryHelper({
    required WidgetRef ref,
    required ChatScreenConfig config,
    required String Function() chatId,
    required String? Function() contactPublicKey,
    required String Function() displayContactName,
    required IMessageRepository messageRepository,
    required Future<void> Function(Message message) repositoryRetryHandler,
    required void Function(String) showSuccess,
    required void Function(String) showError,
    required void Function(String) showInfo,
    required void Function() scrollToBottom,
    required List<Message> Function() getMessages,
    Duration? fallbackRetryDelay,
  }) {
    retryHelper = ChatRetryHelper(
      ref: ref,
      config: config,
      chatId: chatId,
      contactPublicKey: contactPublicKey,
      displayContactName: displayContactName,
      messageRepository: messageRepository,
      repositoryRetryHandler: repositoryRetryHandler,
      showSuccess: showSuccess,
      showError: showError,
      showInfo: showInfo,
      scrollToBottom: scrollToBottom,
      getMessages: getMessages,
      offlineQueueResolver: resolveOfflineQueue,
      logger: _logger,
      initialCoordinator: retryCoordinator,
      fallbackRetryDelay: fallbackRetryDelay,
    );
  }

  Future<void> startSession({
    required ChatId chatId,
    required ChatSessionStateStore stateStore,
    required Stream<String> Function() incomingStream,
    required BuildContext context,
    required bool Function() disposed,
    required bool Function() mounted,
    required VoidCallback onSecurityStateInvalidate,
    required AsyncValue<MeshNetworkStatus> meshStatusAsync,
    required AsyncValue<ConnectionInfo> connectionInfoAsync,
    required void Function(String message) onSuccessMessage,
    required Future<void> Function(String content) onMessage,
    required Future<void> Function() onProcessBufferedMessages,
    required void Function(MessageId messageId, MessageStatus status)
    onDelivered,
  }) async {
    if (disposed()) return;

    _setupMeshNetworking(
      meshStatusAsync: meshStatusAsync,
      stateStore: stateStore,
      disposed: disposed,
      onSuccessMessage: onSuccessMessage,
    );

    setupDeliveryListener(
      onDelivered: (messageId) =>
          onDelivered(messageId, MessageStatus.delivered),
    );

    setupContactRequestHandling(
      context: context,
      onSecurityStateInvalidate: onSecurityStateInvalidate,
      mounted: mounted,
    );

    ensureRetryCoordinator();

    if (persistentChatManager != null &&
        !persistentChatManager!.hasActiveListener(chatId.value)) {
      registerPersistentListener(
        chatId: chatId,
        incomingStream: incomingStream,
        onMessage: onMessage,
      );
    }

    final isConnected =
        connectionInfoAsync.value?.isConnected ??
        connectionService.currentConnectionInfo.isConnected;
    if (isConnected) {
      await startMessageListener(
        chatId: chatId,
        incomingStream: incomingStream,
        persistentManager: persistentChatManager,
        disposed: disposed,
        onMessage: onMessage,
      );
      await onProcessBufferedMessages();
    }
  }

  void _setupMeshNetworking({
    required AsyncValue<MeshNetworkStatus> meshStatusAsync,
    required ChatSessionStateStore stateStore,
    required bool Function() disposed,
    required void Function(String) onSuccessMessage,
  }) {
    try {
      handleMeshStatus(
        statusAsync: meshStatusAsync,
        isCurrentlyInitializing: stateStore.current.meshInitializing,
        updateState: stateStore.update,
        onSuccessMessage: onSuccessMessage,
        onWarningMessage: (msg) => _logger.warning(msg),
      );
      meshStatusAsync.when(
        data: (status) {
          if (!status.isInitialized) {
            startInitializationTimeout(
              isCheckingStatus: false,
              disposed: disposed,
              stillInitializing: () => stateStore.current.meshInitializing,
              updateState: stateStore.update,
              onSuccessMessage: onSuccessMessage,
            );
          }
        },
        loading: () {
          startInitializationTimeout(
            isCheckingStatus: true,
            disposed: disposed,
            stillInitializing: () => stateStore.current.meshInitializing,
            updateState: stateStore.update,
            onSuccessMessage: onSuccessMessage,
          );
        },
        error: (error, stack) {},
      );
    } catch (e) {
      _logger.warning('Failed to set up mesh networking: $e');
      stateStore.setMeshState(
        meshInitializing: false,
        initializationStatus: 'Failed to initialize',
      );
    }
  }

  Future<void> startMessageListener({
    required ChatId chatId,
    required Stream<String> Function() incomingStream,
    required PersistentChatStateManager? persistentManager,
    required bool Function() disposed,
    required Future<void> Function(String content) onMessage,
  }) async {
    if (messageListenerActive) return;

    messageListenerActive = true;
    persistentChatManager = persistentManager ?? persistentChatManager;

    if (persistentChatManager != null &&
        !persistentChatManager!.hasActiveListener(chatId.value)) {
      registerPersistentListener(
        chatId: chatId,
        incomingStream: incomingStream,
        onMessage: onMessage,
      );
      _logger.info('📡 Message listener activated (persistent mode)');
      return;
    }

    if (persistentChatManager != null &&
        persistentChatManager!.hasActiveListener(chatId.value)) {
      _logger.fine('Message listener already active (persistent)');
      return;
    }

    attachMessageStream(
      stream: incomingStream(),
      disposed: disposed,
      isActive: () => messageListenerActive,
      onMessage: (content) async {
        messageBuffer.add(content);
        await processBufferedMessages(onMessage);
      },
    );
    _logger.info('📡 Message listener activated (stream mode)');
  }

  /// Retry sending a repository-backed message using router → direct → mesh.
  Future<bool> sendRepositoryMessage({
    required Message message,
    required String fallbackRecipientId,
    required String displayContactName,
    String? contactPublicKey,
    void Function(String message)? onInfoMessage,
  }) async {
    bool success = false;

    try {
      if (messageRouter != null) {
        final routeResult = await messageRouter!.sendMessage(
          content: message.content,
          recipientId: contactPublicKey ?? fallbackRecipientId,
          messageId: message.id.value,
          recipientName: displayContactName,
        );

        success = routeResult.isSentDirectly;

        if (routeResult.isQueued) {
          onInfoMessage?.call(
            'Message queued - will send when peer comes online',
          );
        }
      }
    } catch (e) {
      _logger.fine('MessageRouter send failed; falling back: $e');
    }

    final connectionInfo = connectionService.currentConnectionInfo;
    final isConnected = connectionInfo.isConnected;
    final isReady = connectionInfo.isReady;

    if (!success && isConnected && isReady) {
      try {
        if (connectionService.isPeripheralMode) {
          success = await connectionService.sendPeripheralMessage(
            message.content,
            messageId: message.id.value,
          );
        } else {
          success = await connectionService.sendMessage(
            message.content,
            messageId: message.id.value,
          );
        }
      } catch (_) {}
    }

    if (!success && contactPublicKey != null && contactPublicKey.isNotEmpty) {
      try {
        final meshResult = await meshService.sendMeshMessage(
          content: message.content,
          recipientPublicKey: contactPublicKey,
        );
        success = meshResult.isSuccess;
      } catch (_) {}
    }

    return success;
  }

  void handleConnectionChange({
    required ConnectionInfo? previous,
    required ConnectionInfo? current,
    required bool Function() disposed,
    required Future<void> Function() onIdentityReceived,
    required void Function(String message) onSuccessMessage,
    required void Function(String message) onErrorMessage,
    required String? contactPublicKey,
    void Function(String message)? onInfoMessage,
  }) {
    if (disposed()) return;

    final wasConnected = previous?.isConnected ?? false;
    final isConnected = current?.isConnected ?? false;
    final wasReady = previous?.isReady ?? false;
    final isReady = current?.isReady ?? false;

    if (!wasConnected && isConnected) {
      onSuccessMessage('Connected to device!');
    } else if (wasConnected && !isConnected) {
      onErrorMessage('Device disconnected');
    } else if (isConnected && !wasReady && isReady) {
      onSuccessMessage('Identity exchange complete!');
      scheduleAutoRetry(
        delay: const Duration(milliseconds: 1000),
        disposed: disposed,
        onRetry: autoRetryFailedMessages,
      );
    }

    if (current?.otherUserName != null &&
        current!.otherUserName!.isNotEmpty &&
        previous?.otherUserName != current.otherUserName) {
      unawaited(onIdentityReceived());
    }

    if (isConnected) {
      scheduleAutoRetry(
        delay: const Duration(milliseconds: 2500),
        disposed: disposed,
        onRetry: autoRetryFailedMessages,
      );
    } else {
      if (!connectionService.isPeripheralMode) {
        if (hasMessagesQueuedForRelay(contactPublicKey)) {
          (onInfoMessage ?? onSuccessMessage)(
            'Messages queued for relay - maintaining connection',
          );
        } else {
          connectionService.startConnectionMonitoring();
        }
      }
    }
  }

  Future<void> manualReconnection({
    required bool Function() disposed,
    required void Function(String message) onSuccessMessage,
    required void Function(String message) onErrorMessage,
  }) async {
    if (disposed()) return;
    if (connectionService.isConnected) {
      onSuccessMessage('Already connected');
      return;
    }

    onSuccessMessage('Manually searching for device...');

    try {
      final foundDevice = await connectionService.scanForSpecificDevice(
        timeout: const Duration(seconds: 10),
      );

      if (foundDevice != null) {
        if (connectionService.connectedDevice?.uuid == foundDevice.uuid) {
          onSuccessMessage('Already connected to this device');
          return;
        }

        await connectionService.connectToDevice(foundDevice);
        onSuccessMessage('Manual reconnection successful!');
      } else {
        onErrorMessage(
          'Device not found - ensure other device is in discoverable mode',
        );
      }
    } catch (e) {
      final errorMsg = e.toString();
      if (errorMsg.contains('1049')) {
        onSuccessMessage('Already connected to device');
      } else {
        onErrorMessage(
          'Manual reconnection failed: ${errorMsg.split(':').last}',
        );
      }
    }
  }

  Future<void> requestPairing({
    required ConnectionInfo? connectionInfo,
    required void Function(String message) onErrorMessage,
  }) async {
    if (connectionInfo == null || !connectionInfo.isConnected) {
      onErrorMessage('Not connected - cannot pair');
      return;
    }

    if (pairingController == null) {
      onErrorMessage('Pairing unavailable - controller not attached');
      return;
    }

    await pairingController!.userRequestedPairing();
  }

  Future<void> handleAsymmetricContact(
    String publicKey,
    String displayName,
  ) async {
    if (pairingController == null) return;
    await pairingController!.handleAsymmetricContact(publicKey, displayName);
  }

  Future<void> addAsVerifiedContact(
    String publicKey,
    String displayName,
  ) async {
    if (pairingController == null) return;
    await pairingController!.addAsVerifiedContact(publicKey, displayName);
  }

  /// Register contact-request listeners and dialog flow in one place.
  void setupContactRequestHandling({
    required BuildContext context,
    required VoidCallback onSecurityStateInvalidate,
    required bool Function() mounted,
  }) {
    connectionService.setContactRequestCompletedListener((success) {
      if (success) {
        onSecurityStateInvalidate();
      }
    });

    connectionService.setContactRequestReceivedListener((
      publicKey,
      displayName,
    ) {
      if (!mounted()) return;

      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) => ContactRequestDialog(
          senderName: displayName,
          senderPublicKey: publicKey,
          onAccept: () async {
            Navigator.of(dialogContext).pop();
            await connectionService.acceptContactRequest();
            onSecurityStateInvalidate();
          },
          onReject: () {
            Navigator.of(dialogContext).pop();
            connectionService.rejectContactRequest();
          },
        ),
      );
    });

    connectionService.setAsymmetricContactListener((publicKey, displayName) {
      unawaited(handleAsymmetricContact(publicKey, displayName));
    });
  }

  /// Register persistent chat listener when available.
  void registerPersistentListener({
    required ChatId chatId,
    required Stream<String> Function() incomingStream,
    required Future<void> Function(String content) onMessage,
  }) {
    persistentChatManager ??= PersistentChatStateManager();
    persistentChatManager?.registerChatScreen(chatId.value, (content) {
      unawaited(onMessage(content));
    });
    persistentChatManager?.setupPersistentListener(
      chatId.value,
      incomingStream(),
    );
  }

  void unregisterPersistentListener(ChatId chatId) {
    persistentChatManager ??= PersistentChatStateManager();
    persistentChatManager?.unregisterChatScreen(chatId.value);
  }
}
