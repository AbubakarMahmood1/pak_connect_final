// Main orchestrator service for mesh networking functionality
// Integrates MeshRelayEngine, QueueSyncManager, SpamPreventionManager with BLE services
// Provides clean APIs and integration points for mesh-enabled messaging

// ignore_for_file: unnecessary_null_comparison, dead_code

import 'dart:async';

import 'package:get_it/get_it.dart';
import 'package:logging/logging.dart';
import 'package:pak_connect/core/utils/string_extensions.dart';

import '../../core/app_core.dart';
import '../../core/interfaces/i_ble_message_handler_facade.dart';
import '../../core/interfaces/i_contact_repository.dart';
import '../../core/interfaces/i_message_repository.dart';
import '../../core/interfaces/i_connection_service.dart';
import '../../core/interfaces/i_mesh_networking_service.dart';
import '../../core/interfaces/i_repository_provider.dart';
import '../../core/messaging/offline_message_queue.dart' show QueuedMessage;
import '../../core/messaging/queue_sync_manager.dart'
    show QueueSyncManagerStats, QueueSyncResult;
import '../../core/messaging/mesh_relay_engine.dart'
    show RelayDecision, RelayStatistics;
import '../../core/security/spam_prevention_manager.dart';
import '../../domain/entities/enhanced_message.dart';
import '../../domain/entities/message.dart';
import '../../domain/services/chat_management_service.dart';
import '../models/mesh_network_models.dart';
import 'mesh/mesh_network_health_monitor.dart';
import 'mesh/mesh_queue_sync_coordinator.dart';
import 'mesh/mesh_relay_coordinator.dart';
import '../../core/utils/chat_utils.dart';

/// Main orchestrator service for mesh networking functionality
/// Coordinates all mesh components behind a clean application-facing API
class MeshNetworkingService implements IMeshNetworkingService {
  static final _logger = Logger('MeshNetworkingService');

  // Core mesh components
  SpamPreventionManager? _spamPrevention;
  late final MeshRelayCoordinator _relayCoordinator;
  late final MeshQueueSyncCoordinator _queueCoordinator;
  final MeshNetworkHealthMonitor _healthMonitor;

  // Integration services
  // 🎯 NOTE: MeshNetworkingService depends on the connection abstraction
  // (IConnectionService) implemented by BLEServiceFacade to stay decoupled
  // from concrete data-layer implementations.
  final IConnectionService _bleService;
  final IBLEMessageHandlerFacade _messageHandler;
  final IContactRepository _contactRepository;
  // Note: _chatManagementService kept for API compatibility but not currently used
  // May be needed for future chat-related mesh operations (group chats, etc.)
  final IMessageRepository _messageRepository;

  // State management
  String? _currentNodeId;
  bool _isInitialized = false;

  // Streams for UI consumption with late subscriber support
  @override
  Stream<MeshNetworkStatus> get meshStatus => _healthMonitor.meshStatus;

  @override
  Stream<RelayStatistics> get relayStats => _healthMonitor.relayStats;

  @override
  Stream<QueueSyncManagerStats> get queueStats => _healthMonitor.queueStats;

  /// Stream that emits message IDs when they are successfully delivered
  /// Use this for real-time UI updates without full message list refresh
  @override
  Stream<String> get messageDeliveryStream =>
      _healthMonitor.messageDeliveryStream;

  MeshRelayCoordinator get relayCoordinator => _relayCoordinator;

  MeshQueueSyncCoordinator get queueCoordinator => _queueCoordinator;

  MeshNetworkHealthMonitor get healthMonitor => _healthMonitor;

  MeshNetworkingService({
    required IConnectionService bleService,
    required IBLEMessageHandlerFacade messageHandler,
    // ✅ Phase 3A: Now properly typed via BLEMessageHandlerFacadeImpl adapter
    required ChatManagementService
    chatManagementService, // Kept for API compatibility
    IRepositoryProvider? repositoryProvider,
    MeshRelayCoordinator? relayCoordinator,
    MeshNetworkHealthMonitor? healthMonitor,
    MeshQueueSyncCoordinator? queueCoordinator,
  }) : _bleService = bleService,
       _messageHandler = messageHandler,
       _contactRepository =
           (repositoryProvider ?? GetIt.instance<IRepositoryProvider>())
               .contactRepository,
       _messageRepository =
           (repositoryProvider ?? GetIt.instance<IRepositoryProvider>())
               .messageRepository,
       _healthMonitor = healthMonitor ?? MeshNetworkHealthMonitor() {
    _relayCoordinator =
        relayCoordinator ??
        MeshRelayCoordinator(
          bleService: _bleService,
          onRelayDecision: _handleRelayDecision,
          onRelayStatsUpdated: _handleRelayStatsUpdated,
          onDeliverToSelf: _handleDeliverToSelf,
        );

    _queueCoordinator =
        queueCoordinator ??
        MeshQueueSyncCoordinator(
          bleService: _bleService,
          messageRepository: _messageRepository,
          healthMonitor: _healthMonitor,
          shouldRelayThroughDevice: (message, deviceId) =>
              _relayCoordinator.shouldRelayThroughDevice(message, deviceId),
        );

    _healthMonitor.broadcastInitialStatus();
    _healthMonitor.schedulePostFrameStatusUpdate(
      isInitialized: () => _isInitialized,
      nodeIdProvider: () => _currentNodeId,
      queueSnapshotProvider: () => _queueCoordinator.getActiveQueueMessages(),
      statisticsProvider: () => getNetworkStatistics(),
      isConnectedProvider: () => _bleService.isConnected,
    );
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

    final sharedQueue = AppCore.instance.messageQueue;
    _logger.info(
      '✅ Connected to shared message queue with ${sharedQueue.getStatistics().pendingMessages} pending messages',
    );

    await _queueCoordinator.initialize(
      nodeId: _currentNodeId!,
      messageQueue: sharedQueue,
      onStatusChanged: _broadcastMeshStatus,
    );

    // Initialize spam prevention
    _spamPrevention = SpamPreventionManager();
    await _spamPrevention!.initialize();

    await _relayCoordinator.initialize(
      nodeId: _currentNodeId!,
      messageQueue: sharedQueue,
      spamPrevention: _spamPrevention!,
    );

    _logger.info('Core mesh components initialized with smart routing');
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

    _queueCoordinator.enableQueueSyncHandling();
    _queueCoordinator.startConnectionMonitoring();

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
      _queueCoordinator.startConnectionMonitoring();

      _logger.info(
        '📱 Minimal BLE integration active (connection monitoring only)',
      );
    } catch (e) {
      _logger.warning('Even minimal BLE integration failed: $e');
    }
  }

  /// Broadcast fallback status when initialization fails
  void _broadcastFallbackStatus() {
    _healthMonitor.broadcastFallbackStatus(currentNodeId: _currentNodeId);
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
        return await _relayCoordinator.sendRelayMessage(
          content: content,
          recipientPublicKey: recipientPublicKey,
          chatId: chatId,
          priority: priority,
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
      final messageId = await _queueCoordinator.queueDirectMessage(
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

  /// Get comprehensive network statistics
  MeshNetworkStatistics getNetworkStatistics() {
    final relayStats = _relayCoordinator.relayStatistics;
    final queueStats = _queueCoordinator.queueStatistics;
    final syncStats = _queueCoordinator.queueSyncStats;
    final spamStats = _spamPrevention?.getStatistics();

    return MeshNetworkStatistics(
      nodeId: _currentNodeId ?? 'unknown',
      isInitialized: _isInitialized,
      relayStatistics: relayStats,
      queueStatistics: queueStats,
      syncStatistics: syncStats,
      spamStatistics: spamStats,
      spamPreventionActive: _spamPrevention != null,
      queueSyncActive: syncStats != null,
    );
  }

  /// Force refresh mesh status broadcast (for provider initialization)
  void refreshMeshStatus() {
    _broadcastMeshStatus();
  }

  /// Sync queues with connected nodes
  Future<Map<String, QueueSyncResult>> syncQueuesWithPeers() async {
    final availableNodes = await _relayCoordinator.getAvailableNextHops();
    return _queueCoordinator.syncWithPeers(availableNodes);
  }

  /// Retry a specific message in the queue
  Future<bool> retryMessage(String messageId) async {
    return _queueCoordinator.retryMessage(messageId);
  }

  /// Remove a specific message from the queue
  Future<bool> removeMessage(String messageId) async {
    return _queueCoordinator.removeMessage(messageId);
  }

  /// Set high priority for a specific message
  Future<bool> setPriority(String messageId, MessagePriority priority) async {
    return _queueCoordinator.setPriority(messageId, priority);
  }

  /// Retry all failed messages
  Future<int> retryAllMessages() async {
    return _queueCoordinator.retryAllMessages();
  }

  /// Get queued messages for a specific chat (for UI display)
  /// Returns only in-flight messages (pending, sending, retrying)
  /// Excludes delivered messages (those have moved to MessageRepository)
  List<QueuedMessage> getQueuedMessagesForChat(String chatId) {
    return _queueCoordinator.getQueuedMessagesForChat(chatId);
  }

  Future<void> _handleDeliverToSelf(
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
    _healthMonitor.emitRelayStats(stats);
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

  void _broadcastMeshStatus() {
    _healthMonitor.broadcastMeshStatus(
      isInitialized: _isInitialized,
      currentNodeId: _currentNodeId,
      isConnected: _bleService.isConnected,
      statistics: getNetworkStatistics(),
      queueMessages: _queueCoordinator.getActiveQueueMessages(),
    );
  }

  /// Dispose of all resources
  void dispose() {
    _relayCoordinator.dispose();
    unawaited(_queueCoordinator.dispose());
    _spamPrevention?.dispose();
    _spamPrevention = null;
    _healthMonitor.dispose();

    _logger.info('Mesh networking service disposed');
  }
}
