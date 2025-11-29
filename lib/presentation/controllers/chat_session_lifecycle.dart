import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logging/logging.dart';

import '../../core/app_core.dart';
import '../../core/interfaces/i_connection_service.dart';
import '../../core/interfaces/i_mesh_networking_service.dart';
import '../../core/messaging/message_router.dart';
import '../../core/messaging/offline_message_queue.dart';
import '../../core/models/connection_info.dart';
import '../../core/security/message_security.dart';
import '../../core/services/message_retry_coordinator.dart';
import '../../core/services/persistent_chat_state_manager.dart';
import '../../data/repositories/message_repository.dart';
import '../../domain/entities/message.dart';
import '../../domain/services/notification_service.dart';
import '../../domain/models/mesh_network_models.dart';
import '../controllers/chat_retry_helper.dart';
import '../controllers/chat_pairing_dialog_controller.dart';
import '../models/chat_ui_state.dart';
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
    this.messageRouter,
    required this.messageSecurity,
    required this.messageRepository,
    this.retryCoordinator,
    this.offlineQueue,
    this.notificationService,
    Logger? logger,
  }) : _logger = logger ?? Logger('ChatSessionLifecycle') {
    if (messageRouter == null) {
      _logger.warning(
        'MessageRouter unavailable; lifecycle routing hooks will be disabled',
      );
    }
  }

  final ChatSessionViewModel viewModel;
  final IConnectionService connectionService;
  final IMeshNetworkingService meshService;
  final MessageRouter? messageRouter;
  final MessageSecurity messageSecurity;
  final MessageRepository messageRepository;
  final MessageRetryCoordinator? retryCoordinator;
  final OfflineMessageQueue? offlineQueue;
  final NotificationService? notificationService;
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
    required void Function(String messageId) onDelivered,
  }) {
    try {
      _deliverySubscription = meshService.messageDeliveryStream.listen(
        onDelivered,
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
      final queue =
          offlineQueue ??
          (AppCore.instance.isInitialized
              ? AppCore.instance.messageQueue
              : null);
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
    required String chatId,
    required Stream<String> Function() incomingStream,
    required Future<void> Function(String content) onMessage,
  }) {
    persistentChatManager ??= PersistentChatStateManager();
    persistentChatManager?.registerChatScreen(chatId, (content) {
      unawaited(onMessage(content));
    });
    persistentChatManager?.setupPersistentListener(chatId, incomingStream());
  }

  void unregisterPersistentListener(String chatId) {
    persistentChatManager ??= PersistentChatStateManager();
    persistentChatManager?.unregisterChatScreen(chatId);
  }
}
