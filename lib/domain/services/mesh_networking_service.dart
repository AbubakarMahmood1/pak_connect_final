// Main orchestrator service for mesh networking functionality
// Integrates MeshRelayEngine, QueueSyncManager, SpamPreventionManager with BLE services
// Provides clean APIs and integration points for mesh-enabled messaging

// ignore_for_file: unnecessary_null_comparison, dead_code

import 'dart:async';
import 'package:flutter/widgets.dart';
import 'package:logging/logging.dart';
import 'package:get_it/get_it.dart';
import '../../core/messaging/mesh_relay_engine.dart';
import '../../core/interfaces/i_repository_provider.dart';
import '../../core/interfaces/i_contact_repository.dart';
import '../../core/interfaces/i_message_repository.dart';
import '../../core/messaging/queue_sync_manager.dart';
import '../../core/security/spam_prevention_manager.dart';
import '../../core/messaging/offline_message_queue.dart';
import '../../core/app_core.dart';
import '../../core/interfaces/i_ble_message_handler_facade.dart';
import '../../core/interfaces/i_mesh_ble_service.dart';
import '../../core/interfaces/i_mesh_networking_service.dart';
import '../../core/models/mesh_relay_models.dart';
import '../../domain/services/chat_management_service.dart';
import '../../core/utils/chat_utils.dart';
import '../../core/utils/mesh_debug_logger.dart';
import '../../domain/entities/message.dart';
import '../../domain/entities/enhanced_message.dart';
import '../models/mesh_network_models.dart';
import '../../core/routing/network_topology_analyzer.dart';
import '../../core/interfaces/i_mesh_routing_service.dart';
import 'package:pak_connect/core/utils/string_extensions.dart';

/// Main orchestrator service for mesh networking functionality
/// Coordinates all mesh components behind a clean application-facing API
class MeshNetworkingService implements IMeshNetworkingService {
  static final _logger = Logger('MeshNetworkingService');

  // Core mesh components
  MeshRelayEngine? _relayEngine;
  QueueSyncManager? _queueSyncManager;
  SpamPreventionManager? _spamPrevention;
  OfflineMessageQueue? _messageQueue;

  // Smart routing service (replaces individual routing components)
  IMeshRoutingService? _routingService;
  NetworkTopologyAnalyzer? _topologyAnalyzer;

  // Integration services
  // 🎯 NOTE: MeshNetworkingService now depends on IMeshBleService abstraction which
  // is implemented by BLEService. This preserves access to the complex BLE
  // lifecycle while keeping the domain layer decoupled from data implementations.
  final IMeshBleService _bleService;
  final IBLEMessageHandlerFacade _messageHandler;
  final IContactRepository _contactRepository;
  // Note: _chatManagementService kept for API compatibility but not currently used
  // May be needed for future chat-related mesh operations (group chats, etc.)
  final IMessageRepository _messageRepository;

  // State management
  String? _currentNodeId;
  bool _isInitialized = false;

  // Stream controllers for UI updates
  final _meshStatusController = StreamController<MeshNetworkStatus>.broadcast();
  final _relayStatsController = StreamController<RelayStatistics>.broadcast();
  final _queueStatsController =
      StreamController<QueueSyncManagerStats>.broadcast();
  final _messageDeliveryController =
      StreamController<String>.broadcast(); // Message ID stream

  // Last known status for late subscribers
  MeshNetworkStatus? _lastMeshStatus;

  // Streams for UI consumption with late subscriber support
  Stream<MeshNetworkStatus> get meshStatus {
    // Create a stream that immediately emits the last value if available
    return Stream.multi((controller) {
      // Emit last known status immediately for late subscribers
      if (_lastMeshStatus != null) {
        controller.add(_lastMeshStatus!);
        _logger.fine(
          '🔄 Late subscriber received current mesh status immediately',
        );
      }

      // Then listen to future updates
      final subscription = _meshStatusController.stream.listen(
        (status) => controller.add(status),
        onError: (error) => controller.addError(error),
        onDone: () => controller.close(),
      );

      controller.onCancel = () => subscription.cancel();
    });
  }

  Stream<RelayStatistics> get relayStats => _relayStatsController.stream;
  Stream<QueueSyncManagerStats> get queueStats => _queueStatsController.stream;

  /// Stream that emits message IDs when they are successfully delivered
  /// Use this for real-time UI updates without full message list refresh
  Stream<String> get messageDeliveryStream => _messageDeliveryController.stream;

  MeshNetworkingService({
    required IMeshBleService bleService,
    required IBLEMessageHandlerFacade messageHandler,
    // ✅ Phase 3A: Now properly typed via BLEMessageHandlerFacadeImpl adapter
    required ChatManagementService
    chatManagementService, // Kept for API compatibility
    IRepositoryProvider? repositoryProvider,
  }) : _bleService = bleService,
       _messageHandler = messageHandler,
       _contactRepository =
           (repositoryProvider ?? GetIt.instance<IRepositoryProvider>())
               .contactRepository,
       _messageRepository =
           (repositoryProvider ?? GetIt.instance<IRepositoryProvider>())
               .messageRepository {
    // Note: chatManagementService parameter accepted but not stored as it's not currently used
    // 🔧 CRITICAL FIX: Broadcast initial status to prevent null stream
    _logger.info(
      'MeshNetworkingService constructor - broadcasting initial status to prevent loading loop',
    );
    _broadcastInitialStatus();

    // 🔧 NEW: Schedule guaranteed status update after widget tree is built
    _schedulePostFrameStatusUpdate();
  }

  /// Initialize the mesh networking service
  Future<void> initialize({String? nodeId}) async {
    if (_isInitialized) {
      _logger.warning('Mesh networking service already initialized');
      return;
    }

    try {
      _logger.info('Initializing mesh networking service...');

      // Determine node ID with timeout and fallback
      _currentNodeId = nodeId ?? await _getNodeIdWithFallback();
      final truncatedNodeId = _currentNodeId!.length > 16
          ? _currentNodeId!.shortId()
          : _currentNodeId!;
      _logger.info('Node ID: $truncatedNodeId...');

      // Initialize core components
      await _initializeCoreComponents();

      // Set up integration with BLE layer (with error handling)
      await _setupBLEIntegrationWithFallback();

      _isInitialized = true;

      // Broadcast initial status
      _broadcastMeshStatus();

      _logger.info('✅ Mesh networking service initialized successfully');
    } catch (e) {
      _logger.severe('❌ Failed to initialize mesh networking service: $e');
      // Always broadcast status even when initialization fails
      _broadcastFallbackStatus();
      rethrow;
    }
  }

  /// Initialize core mesh networking components
  Future<void> _initializeCoreComponents() async {
    // Use AppCore's shared message queue instead of creating a separate instance
    _logger.info(
      '🔗 Using AppCore\'s shared message queue for mesh networking',
    );

    // Get the shared queue from AppCore - ensure AppCore is initialized first
    if (!AppCore.instance.isInitialized) {
      _logger.warning('AppCore not initialized, initializing now...');
      await AppCore.instance.initialize();
    }

    _messageQueue = AppCore.instance.messageQueue;
    _logger.info(
      '✅ Connected to shared message queue with ${_messageQueue!.getStatistics().pendingMessages} pending messages',
    );

    // Reconfigure the shared queue to use mesh networking specific callbacks
    _logger.info(
      '🔄 Reconfiguring shared queue callbacks for mesh networking...',
    );
    _messageQueue!.onMessageQueued = _handleMessageQueued;
    _messageQueue!.onMessageDelivered = _handleMessageDelivered;
    _messageQueue!.onMessageFailed = _handleMessageFailed;
    _messageQueue!.onStatsUpdated = _handleQueueStatsUpdated;
    _messageQueue!.onSendMessage = (messageId) => _handleSendMessage(messageId);
    _messageQueue!.onConnectivityCheck = _handleConnectivityCheck;
    _logger.info('✅ Queue callbacks reconfigured for mesh networking');

    // Initialize spam prevention
    _spamPrevention = SpamPreventionManager();
    await _spamPrevention!.initialize();

    // Initialize smart routing components
    await _initializeSmartRouting();

    // Initialize relay engine with smart router
    _relayEngine = MeshRelayEngine(
      messageQueue: _messageQueue!,
      spamPrevention: _spamPrevention!,
    );

    await _relayEngine!.initialize(
      currentNodeId: _currentNodeId!,
      routingService: _routingService,
      topologyAnalyzer: _topologyAnalyzer,
      onRelayMessage: _handleRelayMessage,
      onDeliverToSelf: _handleDeliverToSelf,
      onRelayDecision: _handleRelayDecision,
      onStatsUpdated: _handleRelayStatsUpdated,
    );

    // Initialize queue sync manager
    _queueSyncManager = QueueSyncManager(
      messageQueue: _messageQueue!,
      nodeId: _currentNodeId!,
    );

    await _queueSyncManager!.initialize(
      onSyncRequest: _handleSyncRequest,
      onSendMessages: _handleSendMessages,
      onSyncCompleted: _handleSyncCompleted,
      onSyncFailed: _handleSyncFailed,
    );

    _logger.info('Core mesh components initialized with smart routing');
  }

  /// Initialize smart routing components
  Future<void> _initializeSmartRouting() async {
    try {
      // Initialize topology analyzer
      _topologyAnalyzer = NetworkTopologyAnalyzer();

      // Resolve and initialize mesh routing service via DI
      _routingService ??= GetIt.instance<IMeshRoutingService>();

      await _routingService!.initialize(
        currentNodeId: _currentNodeId!,
        topologyAnalyzer: _topologyAnalyzer!,
      );

      _logger.info('✅ Smart routing components initialized');
    } catch (e) {
      _logger.severe('❌ Failed to initialize smart routing: $e');
      // Continue without smart routing
      _routingService = null;
      _topologyAnalyzer = null;
    }
  }

  /// Set up integration with BLE layer
  Future<void> _setupBLEIntegration() async {
    // Initialize relay system in message handler
    await _messageHandler.initializeRelaySystem(
      currentNodeId: _currentNodeId!,
      onRelayMessageReceived: _handleIncomingRelayMessage,
      onRelayDecisionMade: _handleRelayDecision,
      onRelayStatsUpdated: _handleRelayStatsUpdated,
    );

    // Set relay callbacks after initialization
    _messageHandler.onRelayMessageReceived = _handleIncomingRelayMessage;
    _messageHandler.onRelayDecisionMade = _handleRelayDecision;
    _messageHandler.onRelayStatsUpdated = _handleRelayStatsUpdated;

    // Monitor BLE connection status for mesh networking
    final connectionInfoStream = _bleService.connectionInfo;
    connectionInfoStream.listen(_handleConnectionChange);

    // Intercept queue sync messages before GossipSyncManager processes them
    _bleService.registerQueueSyncHandler(_handleIncomingQueueSync);

    _logger.info('BLE integration set up');
  }

  /// Get node ID with timeout and fallback mechanism
  ///
  /// 🔧 CRITICAL FIX (2025-10-20): Changed from persistent to EPHEMERAL key
  ///
  /// IDENTITY ARCHITECTURE:
  /// - Mesh routing MUST use ephemeral session keys (privacy-preserving, rotates per session)
  /// - Persistent keys ONLY for: Contact.persistentPublicKey, Noise KK pattern, database PKs
  ///
  /// WHY THIS MATTERS:
  /// - RelayMetadata.routingPath[] broadcasts nodeId - MUST NOT expose long-term identity
  /// - NetworkTopology.nodeId visible in gossip - MUST be session-specific
  /// - Ephemeral keys rotate per app session, preventing long-term tracking
  Future<String> _getNodeIdWithFallback() async {
    try {
      // Try to get EPHEMERAL ID with timeout (NOT persistent key!)
      final ephemeralId = await Future.any([
        _bleService.getMyEphemeralId(), // Changed from getMyPublicKey()
        Future.delayed(
          Duration(seconds: 5),
          () => throw TimeoutException(
            'BLE service timeout',
            Duration(seconds: 5),
          ),
        ),
      ]);

      if (ephemeralId.isNotEmpty) {
        _logger.info(
          '✅ Successfully obtained EPHEMERAL node ID from BLE service (session-specific)',
        );
        _logger.info(
          '🔐 Privacy: Using ephemeral key for mesh routing (NOT persistent identity)',
        );
        return ephemeralId;
      } else {
        throw Exception('BLE service returned null/empty ephemeral ID');
      }
    } catch (e) {
      _logger.warning(
        '⚠️ BLE service unavailable for ephemeral ID (${e.toString()}), generating fallback',
      );

      // Generate fallback ephemeral node ID
      final fallbackId = _generateFallbackNodeId();
      _logger.info(
        '🔄 Using fallback ephemeral node ID: ${fallbackId.length > 16 ? '${fallbackId.shortId()}...' : fallbackId}',
      );

      return fallbackId;
    }
  }

  /// Generate a fallback node ID when BLE service is unavailable
  String _generateFallbackNodeId() {
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final random = DateTime.now().microsecond;
    return 'fallback_${timestamp}_$random';
  }

  /// Set up BLE integration with fallback handling
  Future<void> _setupBLEIntegrationWithFallback() async {
    try {
      // Try to set up BLE integration with timeout
      final integrationFuture = _setupBLEIntegration();
      final timeoutFuture = Future.delayed(
        Duration(seconds: 3),
        () => throw TimeoutException(
          'BLE integration timeout',
          Duration(seconds: 3),
        ),
      );

      await Future.any([integrationFuture, timeoutFuture]);
      _logger.info('✅ BLE integration set up successfully');
    } catch (e) {
      _logger.warning(
        '⚠️ BLE integration failed (${e.toString()}), continuing without BLE integration',
      );

      // Set up minimal integration fallback
      _setupMinimalBLEIntegration();
    }
  }

  /// Set up minimal BLE integration when full integration fails
  void _setupMinimalBLEIntegration() {
    try {
      // Monitor BLE connection status with error handling
      final connectionStream = _bleService.connectionInfo;
      connectionStream.listen(
        _handleConnectionChange,
        onError: (error) {
          _logger.warning('BLE connection stream error: $error');
        },
      );

      _logger.info(
        '📱 Minimal BLE integration active (connection monitoring only)',
      );
    } catch (e) {
      _logger.warning('Even minimal BLE integration failed: $e');
    }
  }

  /// Broadcast fallback status when initialization fails
  void _broadcastFallbackStatus() {
    try {
      final fallbackStatus = MeshNetworkStatus(
        isInitialized: false,
        currentNodeId: _currentNodeId,
        isConnected: false,
        queueMessages: [], // CRITICAL FIX: Initialize empty queue messages list
        statistics: MeshNetworkStatistics(
          nodeId: _currentNodeId ?? 'unknown',
          isInitialized: false,
          relayStatistics: null,
          queueStatistics: QueueStatistics(
            totalQueued: 0,
            totalDelivered: 0,
            totalFailed: 0,
            pendingMessages: 0,
            sendingMessages: 0,
            retryingMessages: 0,
            failedMessages: 0,
            isOnline: false,
            averageDeliveryTime: Duration.zero,
          ),
          syncStatistics: null,
          spamStatistics: null,
          spamPreventionActive: false,
          queueSyncActive: false,
        ),
      );

      _lastMeshStatus = fallbackStatus;
      _meshStatusController.add(fallbackStatus);
      _logger.info(
        '📡 Fallback status broadcasted to prevent infinite loading',
      );
    } catch (e) {
      _logger.severe('Failed to broadcast fallback status: $e');
    }
  }

  /// Send message through mesh network (main API for UI)
  Future<MeshSendResult> sendMeshMessage({
    required String content,
    required String recipientPublicKey,
    MessagePriority priority = MessagePriority.normal,
  }) async {
    if (!_isInitialized || _currentNodeId == null) {
      return MeshSendResult.error('Mesh networking not initialized');
    }

    try {
      final truncatedRecipient = recipientPublicKey.length > 8
          ? recipientPublicKey.shortId(8)
          : recipientPublicKey;
      _logger.info('Sending mesh message to $truncatedRecipient...');

      // Generate chat ID (using recipient's ID)
      final chatId = ChatUtils.generateChatId(recipientPublicKey);

      // Check if direct delivery is possible (connected to recipient)
      final canDeliverDirectly = await _canDeliverDirectly(recipientPublicKey);

      if (canDeliverDirectly) {
        // Direct delivery
        return await _sendDirectMessage(content, recipientPublicKey, chatId);
      } else {
        // Mesh relay required
        return await _sendMeshRelayMessage(
          content,
          recipientPublicKey,
          chatId,
          priority,
        );
      }
    } catch (e) {
      _logger.severe('Failed to send mesh message: $e');
      return MeshSendResult.error('Failed to send: $e');
    }
  }

  /// Send message directly (no relay needed)
  Future<MeshSendResult> _sendDirectMessage(
    String content,
    String recipientPublicKey,
    String chatId,
  ) async {
    try {
      // Queue message for direct delivery
      final messageId = await _messageQueue!.queueMessage(
        chatId: chatId,
        content: content,
        recipientPublicKey: recipientPublicKey,
        senderPublicKey: _currentNodeId!,
      );

      final truncatedMessageId = messageId.length > 16
          ? messageId.shortId()
          : messageId;
      _logger.info(
        'Message queued for direct delivery: $truncatedMessageId...',
      );
      return MeshSendResult.direct(messageId);
    } catch (e) {
      return MeshSendResult.error('Direct send failed: $e');
    }
  }

  /// Send message through mesh relay with smart routing
  Future<MeshSendResult> _sendMeshRelayMessage(
    String content,
    String recipientPublicKey,
    String chatId,
    MessagePriority priority,
  ) async {
    try {
      // Generate message ID for relay
      final originalMessageId = DateTime.now().millisecondsSinceEpoch
          .toString();

      // Get available next hops (connected devices)
      final nextHops = await _getAvailableNextHops();
      if (nextHops.isEmpty) {
        return MeshSendResult.error('No next hops available for relay');
      }

      // Use smart router to determine optimal route if available
      String selectedNextHop = nextHops.first; // Default fallback
      double routeScore = 0.5; // Default score

      if (_routingService != null) {
        try {
          _logger.info('🧠 Using routing service for message routing');

          final routingDecision = await _routingService!.determineOptimalRoute(
            finalRecipient: recipientPublicKey,
            availableHops: nextHops,
            priority: priority,
          );

          if (routingDecision.isSuccessful && routingDecision.nextHop != null) {
            selectedNextHop = routingDecision.nextHop!;
            routeScore = routingDecision.routeScore ?? 0.5;
            final truncatedNextHop = selectedNextHop.length > 8
                ? selectedNextHop.shortId(8)
                : selectedNextHop;
            _logger.info(
              '✅ Smart router selected: $truncatedNextHop... (score: ${routeScore.toStringAsFixed(2)})',
            );
          } else {
            _logger.warning(
              '⚠️ Smart router failed: ${routingDecision.reason} - using fallback',
            );
          }
        } catch (e) {
          _logger.warning('Smart router error: $e - using fallback selection');
        }
      }

      // Create relay message
      final relayMessage = await _relayEngine!.createOutgoingRelay(
        originalMessageId: originalMessageId,
        originalContent: content,
        finalRecipientPublicKey: recipientPublicKey,
        priority: priority,
      );

      if (relayMessage == null) {
        return MeshSendResult.error(
          'Unable to create relay message (spam prevention)',
        );
      }

      // Queue the relay message to selected next hop
      final queuedMessage = QueuedMessage.fromRelayMessage(
        relayMessage: relayMessage,
        chatId: 'mesh_relay_$selectedNextHop',
        maxRetries: 3,
      );

      await _messageQueue!.queueMessage(
        chatId: queuedMessage.chatId,
        content: queuedMessage.content,
        recipientPublicKey: queuedMessage.recipientPublicKey,
        senderPublicKey: queuedMessage.senderPublicKey,
        priority: priority,
      );

      // Note: Connection quality monitoring is now handled by MeshRoutingService
      // This was previously done via _qualityMonitor but is now integrated in routing service

      final truncatedMessageId = originalMessageId.length > 16
          ? originalMessageId.shortId()
          : originalMessageId;
      final truncatedNextHop = selectedNextHop.length > 8
          ? selectedNextHop.shortId(8)
          : selectedNextHop;
      _logger.info(
        'Message queued for smart mesh relay: $truncatedMessageId... -> $truncatedNextHop... (score: ${routeScore.toStringAsFixed(2)})',
      );
      return MeshSendResult.relay(originalMessageId, selectedNextHop);
    } catch (e) {
      return MeshSendResult.error('Smart relay send failed: $e');
    }
  }

  /// Check if we can deliver directly to recipient
  Future<bool> _canDeliverDirectly(String recipientPublicKey) async {
    // Check if we're connected and the other user is the recipient
    final connectionInfo = _bleService.currentConnectionInfo;
    if (connectionInfo == null ||
        !connectionInfo.isConnected ||
        !connectionInfo.isReady) {
      return false;
    }

    final connectedNodeId = _bleService.currentSessionId;
    return connectedNodeId == recipientPublicKey;
  }

  /// Get list of available next hops for relay
  Future<List<String>> _getAvailableNextHops() async {
    final List<String> nextHops = [];

    // Check BLE connection
    final connectionInfo = _bleService.currentConnectionInfo;
    if (connectionInfo != null &&
        connectionInfo.isConnected &&
        connectionInfo.isReady) {
      final connectedNodeId = _bleService.currentSessionId;
      if (connectedNodeId != null && connectedNodeId.isNotEmpty) {
        nextHops.add(connectedNodeId);
      }
    }

    return nextHops;
  }

  /// Get comprehensive network statistics
  MeshNetworkStatistics getNetworkStatistics() {
    final relayStats = _relayEngine?.getStatistics();
    final queueStats = _messageQueue?.getStatistics();
    final syncStats = _queueSyncManager?.getStats();
    final spamStats = _spamPrevention?.getStatistics();

    return MeshNetworkStatistics(
      nodeId: _currentNodeId ?? 'unknown',
      isInitialized: _isInitialized,
      relayStatistics: relayStats,
      queueStatistics: queueStats,
      syncStatistics: syncStats,
      spamStatistics: spamStats,
      spamPreventionActive: _spamPrevention != null,
      queueSyncActive: _queueSyncManager != null,
    );
  }

  /// Force refresh mesh status broadcast (for provider initialization)
  void refreshMeshStatus() {
    _broadcastMeshStatus();
  }

  /// Sync queues with connected nodes
  Future<Map<String, QueueSyncResult>> syncQueuesWithPeers() async {
    if (_queueSyncManager == null) {
      return {'error': QueueSyncResult.error('Queue sync not initialized')};
    }

    final availableNodes = await _getAvailableNextHops();
    if (availableNodes.isEmpty) {
      return {
        'no_peers': QueueSyncResult.error('No connected peers available'),
      };
    }

    return await _queueSyncManager!.forceSyncAll(availableNodes);
  }

  /// Retry a specific message in the queue
  Future<bool> retryMessage(String messageId) async {
    if (_messageQueue == null) {
      _logger.warning('Cannot retry message: queue not initialized');
      return false;
    }

    try {
      final message = _messageQueue!.getMessageById(messageId);
      if (message == null) {
        _logger.warning(
          'Message not found for retry: ${messageId.shortId()}...',
        );
        return false;
      }

      // Reset message status to pending for retry
      message.status = QueuedMessageStatus.pending;
      message.attempts = 0;
      message.nextRetryAt = null;
      message.failureReason = null;

      // Trigger immediate delivery attempt if online
      if (_messageQueue!.getStatistics().isOnline) {
        await _handleSendMessage(messageId);
      }

      _logger.info('Message retry initiated: ${messageId.shortId()}...');
      _broadcastMeshStatus();
      return true;
    } catch (e) {
      _logger.severe('Failed to retry message: $e');
      return false;
    }
  }

  /// Remove a specific message from the queue
  Future<bool> removeMessage(String messageId) async {
    if (_messageQueue == null) {
      _logger.warning('Cannot remove message: queue not initialized');
      return false;
    }

    try {
      await _messageQueue!.removeMessage(messageId);
      _logger.info('Message removed from queue: ${messageId.shortId()}...');
      _broadcastMeshStatus();
      return true;
    } catch (e) {
      _logger.severe('Failed to remove message: $e');
      return false;
    }
  }

  /// Set high priority for a specific message
  Future<bool> setPriority(String messageId, MessagePriority priority) async {
    if (_messageQueue == null) {
      _logger.warning('Cannot set priority: queue not initialized');
      return false;
    }

    try {
      final success = await _messageQueue!.changePriority(messageId, priority);

      if (success) {
        _logger.info(
          'Successfully changed priority for message ${messageId.shortId()}... to ${priority.name}',
        );
      }

      return success;
    } catch (e) {
      _logger.severe('Failed to set message priority: $e');
      return false;
    }
  }

  /// Retry all failed messages
  Future<int> retryAllMessages() async {
    if (_messageQueue == null) {
      return 0;
    }

    try {
      await _messageQueue!.retryFailedMessages();
      _broadcastMeshStatus();
      _logger.info('All failed messages queued for retry');
      return _messageQueue!
          .getMessagesByStatus(QueuedMessageStatus.failed)
          .length;
    } catch (e) {
      _logger.severe('Failed to retry all messages: $e');
      return 0;
    }
  }

  /// Get queued messages for a specific chat (for UI display)
  /// Returns only in-flight messages (pending, sending, retrying)
  /// Excludes delivered messages (those have moved to MessageRepository)
  List<QueuedMessage> getQueuedMessagesForChat(String chatId) {
    if (_messageQueue == null) {
      _logger.warning('Cannot get queued messages: queue not initialized');
      return [];
    }

    try {
      // Get pending, sending, and retrying messages for this chat
      final statuses = [
        QueuedMessageStatus.pending,
        QueuedMessageStatus.sending,
        QueuedMessageStatus.retrying,
        QueuedMessageStatus.failed, // Include failed so user can see them
      ];

      final inFlightMessages = <QueuedMessage>[];

      for (final status in statuses) {
        final messages = _messageQueue!
            .getMessagesByStatus(status)
            .where((m) => m.chatId == chatId)
            .toList();
        inFlightMessages.addAll(messages);
      }

      // Sort by queued time (oldest first)
      inFlightMessages.sort((a, b) => a.queuedAt.compareTo(b.queuedAt));

      _logger.info(
        '📋 Found ${inFlightMessages.length} in-flight messages for chat: $chatId',
      );
      return inFlightMessages;
    } catch (e) {
      _logger.severe('Failed to get queued messages for chat: $e');
      return [];
    }
  }

  // Event handlers for core components

  void _handleMessageQueued(QueuedMessage message) {
    final truncatedId = message.id.length > 16
        ? message.id.shortId()
        : message.id;
    _logger.fine('Message queued: $truncatedId...');
    _broadcastMeshStatus();
  }

  void _handleMessageDelivered(QueuedMessage message) async {
    final truncatedId = message.id.length > 16
        ? message.id.shortId()
        : message.id;
    _logger.info('Message delivered: $truncatedId...');

    // 🎯 OPTION B FIX: Save delivered message to repository (permanent history)
    // Now that the message is delivered, move it from queue to repository
    try {
      final deliveredMessage = Message(
        id: message.id,
        chatId: message.chatId,
        content: message.content,
        timestamp: message.queuedAt,
        isFromMe: true, // Our sent message
        status: MessageStatus.delivered,
      );

      await _messageRepository.saveMessage(deliveredMessage);
      _logger.fine('✅ Delivered message saved to repository: $truncatedId...');
    } catch (e) {
      _logger.severe('❌ Failed to save delivered message to repository: $e');
    }

    // 🎯 Emit message ID for real-time UI updates
    _messageDeliveryController.add(message.id);

    _broadcastMeshStatus();
  }

  void _handleMessageFailed(QueuedMessage message, String reason) {
    final truncatedId = message.id.length > 16
        ? message.id.shortId()
        : message.id;
    _logger.warning('Message failed: $truncatedId... - $reason');

    _broadcastMeshStatus();
  }

  void _handleQueueStatsUpdated(QueueStatistics stats) {
    // Broadcast updated queue statistics
    _broadcastMeshStatus();
  }

  Future<void> _handleSendMessage(String messageId) async {
    final truncatedId = messageId.length > 16 ? messageId.shortId() : messageId;
    _logger.fine('Send message request: $truncatedId...');

    try {
      // Get the message from queue
      final message = _messageQueue?.getMessageById(messageId);
      if (message == null) {
        _logger.severe('Message not found in queue: $truncatedId...');
        _messageQueue?.markMessageFailed(
          messageId,
          'Message not found in queue',
        );
        return;
      }

      // Route to correct send method based on mode (central vs peripheral)
      final intendedRecipient = message.recipientPublicKey;
      final connectedPeerId = _bleService.currentSessionId;

      if (intendedRecipient != null &&
          connectedPeerId != null &&
          intendedRecipient.isNotEmpty &&
          connectedPeerId.isNotEmpty &&
          intendedRecipient != connectedPeerId) {
        final truncatedIntended = intendedRecipient.length > 8
            ? intendedRecipient.shortId(8)
            : intendedRecipient;
        final truncatedConnected = connectedPeerId.length > 8
            ? connectedPeerId.shortId(8)
            : connectedPeerId;
        _logger.warning(
          'Skipping delivery for ${message.id.shortId(8)}... - connected peer $truncatedConnected… != intended $truncatedIntended…',
        );
        await _messageQueue?.markMessageFailed(messageId, 'Peer mismatch');
        return;
      }

      // 🔧 FIX: Check actual connection availability instead of mode flag
      // This handles collision scenarios where mode flag might be stale
      bool success;
      if (!_bleService.canSendMessages) {
        _logger.warning(
          'No active connection available (will retry later): $truncatedId...',
        );
        success = false;
      } else if (_bleService.hasPeripheralConnection) {
        // Have peripheral connection (others connected TO us)
        _logger.fine('Sending via PERIPHERAL connection for $truncatedId...');
        success = await _bleService.sendPeripheralMessage(
          message.content,
          messageId: messageId,
        );
      } else {
        // Have central connection (we connected TO others)
        _logger.fine('Sending via CENTRAL connection for $truncatedId...');
        success = await _bleService.sendMessage(
          message.content,
          messageId: messageId,
          originalIntendedRecipient: message
              .recipientPublicKey, // Preserve original recipient for relay
        );
      }

      if (success) {
        _logger.info(
          'Message successfully sent via BLE (${_bleService.isPeripheralMode ? "PERIPHERAL" : "CENTRAL"} mode): $truncatedId...',
        );
        _messageQueue?.markMessageDelivered(messageId);
      } else {
        _logger.warning(
          'Failed to send message via BLE (${_bleService.isPeripheralMode ? "PERIPHERAL" : "CENTRAL"} mode): $truncatedId...',
        );
        _messageQueue?.markMessageFailed(messageId, 'BLE transmission failed');
      }
    } catch (e) {
      _logger.severe('Error sending message $truncatedId...: $e');
      _messageQueue?.markMessageFailed(messageId, 'Send error: $e');
      // Ensure we return early after handling the exception
      return;
    }
  }

  /// Check if a message should be relayed through the specified device
  /// Uses smart routing and topology analysis to determine optimal relay decisions
  Future<bool> _shouldRelayThroughDevice(
    QueuedMessage message,
    String deviceId,
  ) async {
    try {
      final finalRecipient = message.recipientPublicKey;

      // Don't relay if the message is already for this device (direct delivery)
      if (finalRecipient == deviceId) {
        return false; // This should be sent directly, not relayed
      }

      // If we can deliver directly to final recipient, don't relay through intermediate
      if (_bleService.currentSessionId == finalRecipient) {
        return false; // Direct connection to recipient exists
      }

      // Check if this is a relay message - examine relay metadata
      if (message.isRelayMessage && message.relayMetadata != null) {
        // Don't create loops - if device is already in routing path
        if (message.relayMetadata!.hasNodeInPath(deviceId)) {
          return false;
        }

        // Don't relay if TTL would be exceeded
        if (!message.relayMetadata!.canRelay) {
          return false;
        }
      }

      // Use routing service if available for intelligent routing decisions
      if (_routingService != null) {
        try {
          // Use routing service to determine if this device should be used as relay
          final routingDecision = await _routingService!.determineOptimalRoute(
            finalRecipient: finalRecipient,
            availableHops: [deviceId],
            priority: message.priority,
          );

          if (routingDecision.isSuccessful &&
              routingDecision.nextHop == deviceId) {
            return true; // Routing service selected this device as next hop
          }
        } catch (e) {
          _logger.fine('Routing service check failed, using fallback: $e');
          // Continue to fallback heuristic
        }
      }

      // Fallback heuristic: If device is connected and we can't reach recipient directly
      // and the device is not the final recipient, try relaying through it
      final isDeviceConnected = _bleService.currentSessionId == deviceId;
      final cannotReachRecipientDirectly =
          _bleService.currentSessionId != finalRecipient;

      return isDeviceConnected && cannotReachRecipientDirectly;
    } catch (e) {
      _logger.warning('Error checking relay route: $e');
      return false; // Conservative fallback: don't relay on error
    }
  }

  void _handleConnectivityCheck() {
    // PROPER FIX: Check connectivity for both central AND peripheral modes
    // This ensures queue connectivity matches actual sending capability
    final hasPhysicalConnection = _bleService.canSendMessages;

    if (hasPhysicalConnection) {
      _messageQueue?.setOnline();
      _logger.fine(
        'Queue connectivity: ONLINE - BLE connection ready for sending (${_bleService.isPeripheralMode ? "PERIPHERAL" : "CENTRAL"} mode)',
      );
    } else {
      _messageQueue?.setOffline();
      _logger.fine(
        'Queue connectivity: OFFLINE - No BLE connection or characteristic (${_bleService.isPeripheralMode ? "PERIPHERAL" : "CENTRAL"} mode)',
      );
    }
  }

  void _handleRelayMessage(
    MeshRelayMessage message,
    String nextHopNodeId,
  ) async {
    final truncatedMessageId = message.originalMessageId.length > 16
        ? message.originalMessageId.shortId()
        : message.originalMessageId;
    final truncatedNextHop = nextHopNodeId.length > 8
        ? nextHopNodeId.shortId(8)
        : nextHopNodeId;
    _logger.info(
      'Relay message to next hop: $truncatedMessageId... -> $truncatedNextHop...',
    );
  }

  void _handleDeliverToSelf(
    String originalMessageId,
    String content,
    String originalSender,
  ) async {
    try {
      // 🎯 ENHANCED DEBUG LOGGING for delivery confirmation
      final truncatedMessageId = originalMessageId.length > 16
          ? originalMessageId.shortId()
          : originalMessageId;
      final truncatedSender = originalSender.length > 8
          ? originalSender.shortId(8)
          : originalSender;
      final truncatedCurrentNode =
          _currentNodeId != null && _currentNodeId!.length > 8
          ? _currentNodeId!.shortId(8)
          : _currentNodeId;

      _logger.fine('🎯 MESH DELIVERY START: Message $truncatedMessageId...');
      _logger.fine('🎯 FROM ORIGINAL SENDER: $truncatedSender...');
      _logger.fine('🎯 TO CURRENT USER: $truncatedCurrentNode...');

      // 🔍 CRITICAL FIX: Generate chat ID using original sender (not relay node)
      final chatId = ChatUtils.generateChatId(originalSender);
      _logger.fine(
        '🎯 CHAT ID GENERATED: ${chatId.length > 16 ? chatId.shortId() : chatId}...',
      );

      // Create message with proper attribution to original sender
      final message = Message(
        id: originalMessageId,
        chatId: chatId,
        content: content,
        timestamp: DateTime.now(),
        isFromMe: false, // ✅ Message is from original sender, not current user
        status: MessageStatus.delivered,
      );

      // Save to repository with confirmation
      await _messageRepository.saveMessage(message);
      _logger.info(
        '✅ MESH DELIVERY SUCCESS: Message stored in chat with original sender $truncatedSender...',
      );

      // Broadcast mesh status update
      _broadcastMeshStatus();
    } catch (e) {
      _logger.severe(
        '❌ MESH DELIVERY ERROR: Failed to deliver message to self: $e',
      );

      // Still broadcast status for error tracking
      _broadcastMeshStatus();
    }
  }

  void _handleRelayDecision(RelayDecision decision) {
    final truncatedMessageId = decision.messageId.length > 16
        ? decision.messageId.shortId()
        : decision.messageId;
    _logger.info(
      'Relay decision: ${decision.type.name} for $truncatedMessageId... - ${decision.reason}',
    );
  }

  void _handleRelayStatsUpdated(RelayStatistics stats) {
    _relayStatsController.add(stats);
    _broadcastMeshStatus();
  }

  void _handleIncomingRelayMessage(
    String originalMessageId,
    String content,
    String originalSender,
  ) {
    final truncatedMessageId = originalMessageId.length > 16
        ? originalMessageId.shortId()
        : originalMessageId;
    final truncatedSender = originalSender.length > 8
        ? originalSender.shortId(8)
        : originalSender;
    _logger.info(
      'Incoming relay message: $truncatedMessageId... from $truncatedSender...',
    );
    // This will be handled by _handleDeliverToSelf if it's for us
  }

  void _handleSyncRequest(QueueSyncMessage message, String fromNodeId) {
    final truncatedNodeId = fromNodeId.length > 8
        ? fromNodeId.shortId(8)
        : fromNodeId;
    _logger.info(
      '🔄 Sending queue sync to $truncatedNodeId... (${message.messageIds.length} ids)',
    );

    unawaited(_bleService.sendQueueSyncMessage(message));
  }

  void _handleSendMessages(List<QueuedMessage> messages, String toNodeId) {
    if (messages.isEmpty) {
      return;
    }

    final truncated = toNodeId.length > 8 ? toNodeId.shortId(8) : toNodeId;
    _logger.info(
      '📤 Sync delivering ${messages.length} queued message(s) to $truncated...',
    );

    for (final message in messages) {
      _handleSendMessage(message.id).catchError((e) {
        _logger.warning(
          'Queue sync delivery failed for ${message.id.shortId(8)}...: $e',
        );
      });
    }
  }

  void _handleSyncCompleted(String nodeId, QueueSyncResult result) {
    _logger.info(
      'Sync completed with ${nodeId.shortId(8)}...: ${result.success ? "success" : "failed"}',
    );

    final stats = _queueSyncManager!.getStats();
    _queueStatsController.add(stats);
  }

  void _handleSyncFailed(String nodeId, String error) {
    _logger.warning('Sync failed with ${nodeId.shortId(8)}...: $error');
  }

  Future<bool> _handleIncomingQueueSync(
    QueueSyncMessage message,
    String fromNodeId,
  ) async {
    if (_queueSyncManager == null) {
      return false;
    }

    try {
      if (message.syncType == QueueSyncType.request) {
        final response = await _queueSyncManager!.handleSyncRequest(
          message,
          fromNodeId,
        );

        if (response.type == QueueSyncResponseType.success &&
            response.responseMessage != null) {
          await _bleService.sendQueueSyncMessage(response.responseMessage!);
        }

        return true;
      }

      if (message.syncType == QueueSyncType.response) {
        await _queueSyncManager!.processSyncResponse(
          message,
          const <
            QueuedMessage
          >[], // Payload delivery handled separately via onSendMessages
          fromNodeId,
        );
        return true;
      }
    } catch (e) {
      _logger.severe(
        'Queue sync handling failed for ${fromNodeId.shortId(8)}...: $e',
      );
    }

    return false;
  }

  void _handleConnectionChange(dynamic connectionInfo) async {
    final isOnline = connectionInfo?.isConnected ?? false;
    final connectedDeviceId = _bleService.currentSessionId;

    if (isOnline && connectedDeviceId != null && connectedDeviceId.isNotEmpty) {
      // 🌐 DEVICE CAME ONLINE
      MeshDebugLogger.deviceConnected(connectedDeviceId);
      _messageQueue?.setOnline();

      // 🎯 CRITICAL ENHANCEMENT: Auto-deliver queued messages to newly connected device
      await _deliverQueuedMessagesToDevice(connectedDeviceId);

      // 🔄 Auto-trigger queue synchronization with connected device
      await _syncQueueWithDevice(connectedDeviceId);
    } else if (!isOnline) {
      // 🔌 DEVICE WENT OFFLINE
      if (connectedDeviceId != null && connectedDeviceId.isNotEmpty) {
        MeshDebugLogger.deviceDisconnected(connectedDeviceId);
      }
      _messageQueue?.setOffline();
    }

    _broadcastMeshStatus();
  }

  /// 🎯 CRITICAL NEW FEATURE: Deliver all queued messages for a specific device
  Future<void> _deliverQueuedMessagesToDevice(String deviceId) async {
    try {
      if (_messageQueue == null) {
        MeshDebugLogger.warning(
          'QUEUE_DELIVERY',
          'Message queue not initialized',
          messageId: 'N/A',
        );
        return;
      }

      // Get direct messages for this device
      final directMessages = _messageQueue!
          .getMessagesByStatus(QueuedMessageStatus.pending)
          .where((msg) => msg.recipientPublicKey == deviceId)
          .toList();

      // Get relay messages that should go through this device
      final pendingMessages = _messageQueue!
          .getMessagesByStatus(QueuedMessageStatus.pending)
          .where((msg) => msg.recipientPublicKey != deviceId)
          .toList();

      final relayMessages = <QueuedMessage>[];
      for (final msg in pendingMessages) {
        if (await _shouldRelayThroughDevice(msg, deviceId)) {
          relayMessages.add(msg);
        }
      }

      final allMessages = [...directMessages, ...relayMessages];

      if (allMessages.isEmpty) {
        MeshDebugLogger.info(
          'No queued messages',
          'No pending messages for ${deviceId.length > 8 ? deviceId.shortId(8) : deviceId}...',
        );
        return;
      }

      final directCount = directMessages.length;
      final relayCount = relayMessages.length;
      _logger.info(
        'Found $directCount direct + $relayCount relay messages for ${deviceId.shortId(8)}...',
      );

      MeshDebugLogger.queueDeliveryTriggered(deviceId, allMessages.length);

      // Sort by priority and queue time for optimal delivery order
      allMessages.sort((a, b) {
        final priorityCompare = b.priority.index.compareTo(a.priority.index);
        if (priorityCompare != 0) return priorityCompare;
        return a.queuedAt.compareTo(b.queuedAt);
      });

      int successful = 0;
      int failed = 0;

      // Process messages with staggered delays to prevent network congestion
      for (int i = 0; i < allMessages.length; i++) {
        final message = allMessages[i];

        try {
          // Add delay to prevent network congestion (except for first message)
          if (i > 0) {
            await Future.delayed(Duration(milliseconds: 200));
          }

          MeshDebugLogger.messageDequeued(message.id, deviceId);

          // Trigger delivery through the queue's internal system
          if (_handleSendMessage != null) {
            await _handleSendMessage(message.id);
            successful++;

            MeshDebugLogger.deliverySuccess(message.id, deviceId);
          } else {
            failed++;
            MeshDebugLogger.deliveryFailed(
              message.id,
              'No send handler available',
              1,
              1,
            );
          }
        } catch (e) {
          failed++;
          MeshDebugLogger.deliveryFailed(message.id, e.toString(), 1, 1);
        }
      }

      MeshDebugLogger.queueDeliveryComplete(
        deviceId,
        allMessages.length,
        successful,
        failed,
      );

      // Update mesh status after queue processing
      _broadcastMeshStatus();
    } catch (e) {
      MeshDebugLogger.error('QUEUE_DELIVERY', e.toString());
    }
  }

  /// Synchronize message queue with connected device via hash comparison
  Future<void> _syncQueueWithDevice(String deviceId) async {
    try {
      if (_messageQueue == null) {
        _logger.warning('Queue sync skipped - message queue not initialized');
        return;
      }

      if (_currentNodeId == null) {
        _logger.warning('Queue sync skipped - current node ID not set');
        return;
      }

      final truncatedDeviceId = deviceId.length > 8
          ? deviceId.shortId(8)
          : deviceId;
      _logger.info('🔄 Starting queue sync with $truncatedDeviceId...');

      // Calculate our queue hash
      final ourHash = _messageQueue!.calculateQueueHash();
      final ourHashPreview = ourHash.shortId();

      // Create sync request message
      final syncMessage = _messageQueue!.createSyncMessage(_currentNodeId!);

      _logger.info(
        '🔄 Our queue hash: $ourHashPreview... (${syncMessage.messageIds.length} messages)',
      );

      // Send sync message via queue sync manager if available
      if (_queueSyncManager != null) {
        try {
          await _queueSyncManager!.initiateSync(deviceId);
          _logger.info('✅ Queue sync request sent to $truncatedDeviceId...');
        } catch (e) {
          _logger.warning('Queue sync request failed: $e');
        }
      } else {
        _logger.info('Queue sync manager not available - sync request skipped');
      }
    } catch (e) {
      _logger.severe('Failed to sync queue with device: $e');
    }
  }

  /// Broadcast initial status immediately in constructor to prevent null stream
  void _broadcastInitialStatus() {
    try {
      final initialStatus = MeshNetworkStatus(
        isInitialized: false, // Not yet initialized
        currentNodeId: null, // Not yet determined
        isConnected: false, // Default until BLE connection is checked
        queueMessages: [], // CRITICAL FIX: Initialize empty queue messages list
        statistics: MeshNetworkStatistics(
          nodeId: 'initializing',
          isInitialized: false,
          relayStatistics: null,
          queueStatistics: QueueStatistics(
            totalQueued: 0,
            totalDelivered: 0,
            totalFailed: 0,
            pendingMessages: 0,
            sendingMessages: 0,
            retryingMessages: 0,
            failedMessages: 0,
            isOnline: false,
            averageDeliveryTime: Duration.zero,
          ),
          syncStatistics: null,
          spamStatistics: null,
          spamPreventionActive: false,
          queueSyncActive: false,
        ),
      );

      _lastMeshStatus = initialStatus;
      _meshStatusController.add(initialStatus);
      _logger.info(
        '✅ Initial MeshNetworkStatus broadcasted - RelayQueueWidget loading should complete',
      );
    } catch (e) {
      _logger.severe('❌ Failed to broadcast initial status: $e');
    }
  }

  /// Schedule a post-frame status update to ensure UI receives proper status
  void _schedulePostFrameStatusUpdate() {
    try {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        // Only broadcast if initialization hasn't completed yet
        if (!_isInitialized && !_meshStatusController.isClosed) {
          _logger.info(
            '🔄 Post-frame status update - ensuring UI receives initialization progress',
          );
          _broadcastInProgressStatus();
        }
      });
    } catch (e) {
      _logger.warning('Failed to schedule post-frame status update: $e');
    }
  }

  /// Broadcast in-progress status for UI feedback during async initialization
  void _broadcastInProgressStatus() {
    try {
      final inProgressStatus = MeshNetworkStatus(
        isInitialized: false,
        currentNodeId: _currentNodeId,
        isConnected: _bleService.isConnected,
        queueMessages:
            _messageQueue?.getMessagesByStatus(QueuedMessageStatus.pending) ??
            [], // CRITICAL FIX
        statistics: getNetworkStatistics(),
      );

      _lastMeshStatus = inProgressStatus;
      _meshStatusController.add(inProgressStatus);
      _logger.info('✅ In-progress status broadcasted for UI feedback');
    } catch (e) {
      _logger.severe('❌ Failed to broadcast in-progress status: $e');
    }
  }

  void _broadcastMeshStatus() {
    // 🔧 FIX: Include all active queue statuses for UI display
    final List<QueuedMessage> queueMessages = [
      ..._messageQueue?.getMessagesByStatus(QueuedMessageStatus.pending) ??
          <QueuedMessage>[],
      ..._messageQueue?.getMessagesByStatus(QueuedMessageStatus.sending) ??
          <QueuedMessage>[],
      ..._messageQueue?.getMessagesByStatus(QueuedMessageStatus.retrying) ??
          <QueuedMessage>[],
      ..._messageQueue?.getMessagesByStatus(QueuedMessageStatus.awaitingAck) ??
          <QueuedMessage>[],
      ..._messageQueue?.getMessagesByStatus(QueuedMessageStatus.failed) ??
          <QueuedMessage>[],
    ];

    // Debug: Log queue message count for development
    _logger.fine(
      'Broadcasting mesh status with ${queueMessages.length} queue messages',
    );

    final status = MeshNetworkStatus(
      isInitialized: _isInitialized,
      currentNodeId: _currentNodeId,
      isConnected: _bleService.isConnected,
      statistics: getNetworkStatistics(),
      queueMessages: queueMessages,
    );

    _lastMeshStatus = status;
    _meshStatusController.add(status);
  }

  /// Dispose of all resources
  void dispose() {
    _relayEngine = null;
    _queueSyncManager = null;
    _spamPrevention?.dispose();
    _spamPrevention = null;
    _messageQueue?.dispose();
    _messageQueue = null;

    // Dispose routing service and topology analyzer
    _routingService?.dispose();
    _routingService = null;
    _topologyAnalyzer?.dispose();
    _topologyAnalyzer = null;

    _meshStatusController.close();
    _relayStatsController.close();
    _queueStatsController.close();
    _messageDeliveryController.close();

    _logger.info('Mesh networking service disposed');
  }
}
