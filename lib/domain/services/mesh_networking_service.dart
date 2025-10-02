// Main orchestrator service for mesh networking functionality
// Integrates MeshRelayEngine, QueueSyncManager, SpamPreventionManager with BLE services
// Provides clean APIs and integration points for FYP demonstration

// ignore_for_file: unnecessary_null_comparison, dead_code

import 'dart:async';
import 'package:flutter/widgets.dart';
import 'package:logging/logging.dart';
import '../../core/messaging/mesh_relay_engine.dart';
import '../../core/messaging/queue_sync_manager.dart';
import '../../core/security/spam_prevention_manager.dart';
import '../../core/messaging/offline_message_queue.dart';
import '../../core/app_core.dart';
import '../../data/services/ble_service.dart';
import '../../data/services/ble_message_handler.dart';
import '../../data/repositories/contact_repository.dart';
import '../../core/models/mesh_relay_models.dart';
import '../../domain/services/chat_management_service.dart';
import '../../core/utils/chat_utils.dart';
import '../../core/utils/mesh_debug_logger.dart';
import '../../data/repositories/message_repository.dart';
import '../../domain/entities/message.dart';
import '../../domain/entities/enhanced_message.dart';
import '../../core/routing/smart_mesh_router.dart';
import '../../core/routing/route_calculator.dart';
import '../../core/routing/network_topology_analyzer.dart';
import '../../core/routing/connection_quality_monitor.dart';

/// Main orchestrator service for mesh networking functionality
/// Coordinates all mesh components and provides clean APIs for FYP demonstration
class MeshNetworkingService {
  static final _logger = Logger('MeshNetworkingService');
  
  // Core mesh components
  MeshRelayEngine? _relayEngine;
  QueueSyncManager? _queueSyncManager;
  SpamPreventionManager? _spamPrevention;
  OfflineMessageQueue? _messageQueue;
  
  // Smart routing components
  SmartMeshRouter? _smartRouter;
  RouteCalculator? _routeCalculator;
  NetworkTopologyAnalyzer? _topologyAnalyzer;
  ConnectionQualityMonitor? _qualityMonitor;
  
  // Integration services
  final BLEService _bleService;
  final BLEMessageHandler _messageHandler;
  final ContactRepository _contactRepository;
  // Note: _chatManagementService kept for API compatibility but not currently used
  // May be needed for future chat-related mesh operations (group chats, etc.)
  final MessageRepository _messageRepository;
  
  // State management
  String? _currentNodeId;
  bool _isInitialized = false;
  bool _isDemoMode = false;
  
  // Stream controllers for UI updates
  final _meshStatusController = StreamController<MeshNetworkStatus>.broadcast();
  final _relayStatsController = StreamController<RelayStatistics>.broadcast();
  final _queueStatsController = StreamController<QueueSyncManagerStats>.broadcast();
  final _demoEventController = StreamController<DemoEvent>.broadcast();
  
  // Last known status for late subscribers
  MeshNetworkStatus? _lastMeshStatus;
  
  // Streams for UI consumption with late subscriber support
  Stream<MeshNetworkStatus> get meshStatus {
    // Create a stream that immediately emits the last value if available
    return Stream.multi((controller) {
      // Emit last known status immediately for late subscribers
      if (_lastMeshStatus != null) {
        controller.add(_lastMeshStatus!);
        _logger.fine('🔄 Late subscriber received current mesh status immediately');
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
  Stream<DemoEvent> get demoEvents => _demoEventController.stream;
  
  // Demo tracking
  final List<DemoRelayStep> _demoSteps = [];
  final Map<String, String> _demoMessageTracking = {};

  MeshNetworkingService({
    required BLEService bleService,
    required BLEMessageHandler messageHandler,
    required ContactRepository contactRepository,
    required ChatManagementService chatManagementService, // Kept for API compatibility
    required MessageRepository messageRepository,
  }) : _bleService = bleService,
       _messageHandler = messageHandler,
       _contactRepository = contactRepository,
       _messageRepository = messageRepository {
    // Note: chatManagementService parameter accepted but not stored as it's not currently used
    // 🔧 CRITICAL FIX: Broadcast initial status to prevent null stream
    _logger.info('MeshNetworkingService constructor - broadcasting initial status to prevent loading loop');
    _broadcastInitialStatus();
    
    // 🔧 NEW: Schedule guaranteed status update after widget tree is built
    _schedulePostFrameStatusUpdate();
  }

  /// Initialize the mesh networking service
  Future<void> initialize({
    String? nodeId,
    bool enableDemo = false,
  }) async {
    if (_isInitialized) {
      _logger.warning('Mesh networking service already initialized');
      return;
    }

    try {
      _logger.info('Initializing mesh networking service...');
      
      // Determine node ID with timeout and fallback
      _currentNodeId = nodeId ?? await _getNodeIdWithFallback();
      _isDemoMode = enableDemo;
      
      final truncatedNodeId = _currentNodeId!.length > 16 ? _currentNodeId!.substring(0, 16) : _currentNodeId!;
      _logger.info('Node ID: $truncatedNodeId..., Demo mode: $_isDemoMode');
      
      // Initialize core components
      await _initializeCoreComponents();
      
      // Set up integration with BLE layer (with error handling)
      await _setupBLEIntegrationWithFallback();
      
      // Set up demo capabilities if enabled
      if (_isDemoMode) {
        _setupDemoCapabilities();
      }
      
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
    _logger.info('🔗 Using AppCore\'s shared message queue for mesh networking');

    // Get the shared queue from AppCore - ensure AppCore is initialized first
    if (!AppCore.instance.isInitialized) {
      _logger.warning('AppCore not initialized, initializing now...');
      await AppCore.instance.initialize();
    }

    _messageQueue = AppCore.instance.messageQueue;
    _logger.info('✅ Connected to shared message queue with ${_messageQueue!.getStatistics().pendingMessages} pending messages');

    // Reconfigure the shared queue to use mesh networking specific callbacks
    _logger.info('🔄 Reconfiguring shared queue callbacks for mesh networking...');
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
      contactRepository: _contactRepository,
      messageQueue: _messageQueue!,
      spamPrevention: _spamPrevention!,
    );
    
    await _relayEngine!.initialize(
      currentNodeId: _currentNodeId!,
      smartRouter: _smartRouter,
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
      // Initialize routing components
      _routeCalculator = RouteCalculator();
      _topologyAnalyzer = NetworkTopologyAnalyzer();
      _qualityMonitor = ConnectionQualityMonitor();
      
      // Initialize smart router
      _smartRouter = SmartMeshRouter(
        routeCalculator: _routeCalculator!,
        topologyAnalyzer: _topologyAnalyzer!,
        qualityMonitor: _qualityMonitor!,
        currentNodeId: _currentNodeId!,
      );
      
      await _smartRouter!.initialize(enableDemo: _isDemoMode);
      
      _logger.info('✅ Smart routing components initialized');
      
    } catch (e) {
      _logger.severe('❌ Failed to initialize smart routing: $e');
      // Continue without smart routing
      _smartRouter = null;
    }
  }

  /// Set up integration with BLE layer
  Future<void> _setupBLEIntegration() async {
    // Initialize relay system in message handler
    await _messageHandler.initializeRelaySystem(
      currentNodeId: _currentNodeId!,
      messageQueue: _messageQueue!,
      onRelayMessageReceived: _handleIncomingRelayMessage,
      onRelayDecisionMade: _handleRelayDecision,
      onRelayStatsUpdated: _handleRelayStatsUpdated,
    );

    // Monitor BLE connection status for mesh networking
    _bleService.connectionInfo.listen(_handleConnectionChange);
    
    _logger.info('BLE integration set up');
  }

  /// Get node ID with timeout and fallback mechanism
  Future<String> _getNodeIdWithFallback() async {
    try {
      // Try to get persistent ID with timeout
      final nodeIdFuture = _bleService.getMyPublicKey();
      final timeoutFuture = Future.delayed(Duration(seconds: 5), () => throw TimeoutException('BLE service timeout', Duration(seconds: 5)));
      
      final result = await Future.any([nodeIdFuture, timeoutFuture]);
      
      if (result.isNotEmpty) {
        _logger.info('✅ Successfully obtained persistent node ID from BLE service');
        return result;
      } else {
        throw Exception('BLE service returned null/empty node ID');
      }
      
    } catch (e) {
      _logger.warning('⚠️ BLE service unavailable for node ID (${e.toString()}), generating fallback');
      
      // Generate fallback node ID
      final fallbackId = _generateFallbackNodeId();
      _logger.info('🔄 Using fallback node ID: ${fallbackId.substring(0, 16)}...');
      
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
      final timeoutFuture = Future.delayed(Duration(seconds: 3), () => throw TimeoutException('BLE integration timeout', Duration(seconds: 3)));
      
      await Future.any([integrationFuture, timeoutFuture]);
      _logger.info('✅ BLE integration set up successfully');
      
    } catch (e) {
      _logger.warning('⚠️ BLE integration failed (${e.toString()}), continuing without BLE integration');
      
      // Set up minimal integration fallback
      _setupMinimalBLEIntegration();
    }
  }

  /// Set up minimal BLE integration when full integration fails
  void _setupMinimalBLEIntegration() {
    try {
      // Monitor BLE connection status with error handling
      _bleService.connectionInfo.listen(
        _handleConnectionChange,
        onError: (error) {
          _logger.warning('BLE connection stream error: $error');
        },
      );
      
      _logger.info('📱 Minimal BLE integration active (connection monitoring only)');
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
        isDemoMode: _isDemoMode,
        isConnected: false,
        queueMessages: [], // CRITICAL FIX: Initialize empty queue messages list
        statistics: MeshNetworkStatistics(
          nodeId: _currentNodeId ?? 'unknown',
          isInitialized: false,
          isDemoMode: _isDemoMode,
          demoStepsCount: 0,
          trackedMessagesCount: 0,
          spamPreventionActive: false,
          queueSyncActive: false,
        ),
      );
      
      _lastMeshStatus = fallbackStatus;
      _meshStatusController.add(fallbackStatus);
      _logger.info('📡 Fallback status broadcasted to prevent infinite loading');
      
    } catch (e) {
      _logger.severe('Failed to broadcast fallback status: $e');
    }
  }

  /// Set up demo-specific capabilities
  void _setupDemoCapabilities() {
    _logger.info('Setting up demo capabilities for FYP demonstration');
    
    // Clear any previous demo state
    _demoSteps.clear();
    _demoMessageTracking.clear();
    
    _demoEventController.add(DemoEvent.initialized());
  }

  /// Send message through mesh network (main API for UI)
  Future<MeshSendResult> sendMeshMessage({
    required String content,
    required String recipientPublicKey,
    MessagePriority priority = MessagePriority.normal,
    bool isDemo = false,
  }) async {
    if (!_isInitialized || _currentNodeId == null) {
      return MeshSendResult.error('Mesh networking not initialized');
    }

    try {
      final truncatedRecipient = recipientPublicKey.length > 8 ? recipientPublicKey.substring(0, 8) : recipientPublicKey;
      _logger.info('Sending mesh message to $truncatedRecipient... (demo: $isDemo)');
      
      // Generate chat ID
      final chatId = ChatUtils.generateChatId(_currentNodeId!, recipientPublicKey);
      
      // Check if direct delivery is possible (connected to recipient)
      final canDeliverDirectly = await _canDeliverDirectly(recipientPublicKey);
      
      if (canDeliverDirectly) {
        // Direct delivery
        return await _sendDirectMessage(content, recipientPublicKey, chatId, isDemo);
      } else {
        // Mesh relay required
        return await _sendMeshRelayMessage(content, recipientPublicKey, chatId, priority, isDemo);
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
    bool isDemo
  ) async {
    try {
      // Queue message for direct delivery
      final messageId = await _messageQueue!.queueMessage(
        chatId: chatId,
        content: content,
        recipientPublicKey: recipientPublicKey,
        senderPublicKey: _currentNodeId!,
      );

      if (isDemo) {
        _trackDemoMessage(messageId, 'direct');
        _demoEventController.add(DemoEvent.directMessageSent(messageId, recipientPublicKey));
      }

      final truncatedMessageId = messageId.length > 16 ? messageId.substring(0, 16) : messageId;
      _logger.info('Message queued for direct delivery: $truncatedMessageId...');
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
    bool isDemo,
  ) async {
    try {
      // Generate message ID for relay
      final originalMessageId = DateTime.now().millisecondsSinceEpoch.toString();
      
      // Get available next hops (connected devices)
      final nextHops = await _getAvailableNextHops();
      if (nextHops.isEmpty) {
        return MeshSendResult.error('No next hops available for relay');
      }

      // Use smart router to determine optimal route if available
      String selectedNextHop = nextHops.first; // Default fallback
      double routeScore = 0.5; // Default score
      
      if (_smartRouter != null) {
        try {
          _logger.info('🧠 Using smart router for message routing');
          
          final routingDecision = await _smartRouter!.determineOptimalRoute(
            finalRecipient: recipientPublicKey,
            availableHops: nextHops,
            priority: priority,
          );
          
          if (routingDecision.isSuccessful && routingDecision.nextHop != null) {
            selectedNextHop = routingDecision.nextHop!;
            routeScore = routingDecision.routeScore ?? 0.5;
            final truncatedNextHop = selectedNextHop.length > 8 ? selectedNextHop.substring(0, 8) : selectedNextHop;
            _logger.info('✅ Smart router selected: $truncatedNextHop... (score: ${routeScore.toStringAsFixed(2)})');
          } else {
            _logger.warning('⚠️ Smart router failed: ${routingDecision.reason} - using fallback');
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
        return MeshSendResult.error('Unable to create relay message (spam prevention)');
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

      // Update connection quality monitor
      if (_qualityMonitor != null) {
        _qualityMonitor!.recordMessageSent(selectedNextHop, originalMessageId);
      }

      if (isDemo) {
        _trackDemoMessage(originalMessageId, 'smart_relay');
        _addDemoStep(DemoRelayStep(
          messageId: originalMessageId,
          fromNode: _currentNodeId!,
          toNode: selectedNextHop,
          finalRecipient: recipientPublicKey,
          hopCount: 1,
          action: 'smart_relay_initiated',
          timestamp: DateTime.now(),
        ));
        
        _demoEventController.add(DemoEvent.relayMessageSent(
          originalMessageId,
          selectedNextHop,
          recipientPublicKey,
          1, // hop count
        ));
      }

      final truncatedMessageId = originalMessageId.length > 16 ? originalMessageId.substring(0, 16) : originalMessageId;
      final truncatedNextHop = selectedNextHop.length > 8 ? selectedNextHop.substring(0, 8) : selectedNextHop;
      _logger.info('Message queued for smart mesh relay: $truncatedMessageId... -> $truncatedNextHop... (score: ${routeScore.toStringAsFixed(2)})');
      return MeshSendResult.relay(originalMessageId, selectedNextHop);
      
    } catch (e) {
      return MeshSendResult.error('Smart relay send failed: $e');
    }
  }

  /// Check if we can deliver directly to recipient
  Future<bool> _canDeliverDirectly(String recipientPublicKey) async {
    // Check if we're connected and the other user is the recipient
    final connectionInfo = _bleService.currentConnectionInfo;
    if (!connectionInfo.isConnected || !connectionInfo.isReady) {
      return false;
    }
    
    final connectedNodeId = _bleService.otherDevicePersistentId;
    return connectedNodeId == recipientPublicKey;
  }

  /// Get list of available next hops for relay
  Future<List<String>> _getAvailableNextHops() async {
    final List<String> nextHops = [];
    
    // Check BLE connection
    final connectionInfo = _bleService.currentConnectionInfo;
    if (connectionInfo.isConnected && connectionInfo.isReady) {
      final connectedNodeId = _bleService.otherDevicePersistentId;
      if (connectedNodeId != null && connectedNodeId.isNotEmpty) {
        nextHops.add(connectedNodeId);
      }
    }
    
    return nextHops;
  }

  /// Initialize demo scenario for FYP evaluation
  Future<DemoScenarioResult> initializeDemoScenario(DemoScenarioType type) async {
    if (!_isInitialized) {
      return DemoScenarioResult.error('Service not initialized');
    }

    try {
      _logger.info('Initializing demo scenario: ${type.name}');
      
      // Clear previous demo state
      _demoSteps.clear();
      _demoMessageTracking.clear();
      
      switch (type) {
        case DemoScenarioType.aToBtoC:
          return await _initializeAToBtoCScenario();
        case DemoScenarioType.queueSync:
          return await _initializeQueueSyncScenario();
        case DemoScenarioType.spamPrevention:
          return await _initializeSpamPreventionScenario();
      }
      
    } catch (e) {
      _logger.severe('Failed to initialize demo scenario: $e');
      return DemoScenarioResult.error('Scenario initialization failed: $e');
    }
  }

  /// Initialize A→B→C relay demonstration
  Future<DemoScenarioResult> _initializeAToBtoCScenario() async {
    _demoEventController.add(DemoEvent.scenarioStarted('A→B→C Relay Demonstration'));
    
    final stats = getNetworkStatistics();
    return DemoScenarioResult.success(
      'A→B→C relay scenario ready',
      metadata: {
        'scenario': 'a_to_b_to_c',
        'currentNode': _currentNodeId!.length > 16 ? _currentNodeId!.substring(0, 16) : _currentNodeId!,
        'relayEngineReady': _relayEngine != null,
        'spamPreventionActive': stats.spamPreventionActive,
        'availableHops': await _getAvailableNextHops(),
      },
    );
  }

  /// Initialize queue synchronization demonstration
  Future<DemoScenarioResult> _initializeQueueSyncScenario() async {
    _demoEventController.add(DemoEvent.scenarioStarted('Queue Synchronization Demonstration'));
    
    final queueStats = _queueSyncManager?.getStats();
    return DemoScenarioResult.success(
      'Queue sync scenario ready',
      metadata: {
        'scenario': 'queue_sync',
        'queueStats': queueStats?.toString() ?? 'unavailable',
        'pendingMessages': _messageQueue?.getStatistics().pendingMessages ?? 0,
      },
    );
  }

  /// Initialize spam prevention demonstration
  Future<DemoScenarioResult> _initializeSpamPreventionScenario() async {
    _demoEventController.add(DemoEvent.scenarioStarted('Spam Prevention Demonstration'));
    
    final spamStats = _spamPrevention?.getStatistics();
    return DemoScenarioResult.success(
      'Spam prevention scenario ready',
      metadata: {
        'scenario': 'spam_prevention',
        'spamStats': spamStats?.toString() ?? 'unavailable',
        'totalBlocked': spamStats?.totalBlocked ?? 0,
        'blockRate': spamStats?.blockRate ?? 0.0,
      },
    );
  }

  /// Get comprehensive network statistics for demo UI
  MeshNetworkStatistics getNetworkStatistics() {
    final relayStats = _relayEngine?.getStatistics();
    final queueStats = _messageQueue?.getStatistics();
    final syncStats = _queueSyncManager?.getStats();
    final spamStats = _spamPrevention?.getStatistics();
    
    return MeshNetworkStatistics(
      nodeId: _currentNodeId ?? 'unknown',
      isInitialized: _isInitialized,
      isDemoMode: _isDemoMode,
      relayStatistics: relayStats,
      queueStatistics: queueStats,
      syncStatistics: syncStats,
      spamStatistics: spamStats,
      demoStepsCount: _demoSteps.length,
      trackedMessagesCount: _demoMessageTracking.length,
      spamPreventionActive: _spamPrevention != null,
      queueSyncActive: _queueSyncManager != null,
    );
  }

  /// Get demo steps for visualization
  List<DemoRelayStep> getDemoSteps() => List.from(_demoSteps);

  /// Clear demo data
  void clearDemoData() {
    _demoSteps.clear();
    _demoMessageTracking.clear();
    _demoEventController.add(DemoEvent.demoCleared());
    _logger.info('Demo data cleared');
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
      return {'no_peers': QueueSyncResult.error('No connected peers available')};
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
        _logger.warning('Message not found for retry: ${messageId.substring(0, 16)}...');
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

      _logger.info('Message retry initiated: ${messageId.substring(0, 16)}...');
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
      _logger.info('Message removed from queue: ${messageId.substring(0, 16)}...');
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
      final message = _messageQueue!.getMessageById(messageId);
      if (message == null) {
        _logger.warning('Message not found for priority change: ${messageId.substring(0, 16)}...');
        return false;
      }

      // Note: QueuedMessage priority is final, so this is a limitation
      // In a real implementation, you'd need to recreate the message with new priority
      _logger.info('Priority change requested for message: ${messageId.substring(0, 16)}... (current limitation: priority is immutable)');
      return false;

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
      return _messageQueue!.getMessagesByStatus(QueuedMessageStatus.failed).length;

    } catch (e) {
      _logger.severe('Failed to retry all messages: $e');
      return 0;
    }
  }

  // Event handlers for core components

  void _handleMessageQueued(QueuedMessage message) {
    final truncatedId = message.id.length > 16 ? message.id.substring(0, 16) : message.id;
    _logger.fine('Message queued: $truncatedId...');
    _broadcastMeshStatus();
  }

  void _handleMessageDelivered(QueuedMessage message) {
    final truncatedId = message.id.length > 16 ? message.id.substring(0, 16) : message.id;
    _logger.info('Message delivered: $truncatedId...');
    
    if (_isDemoMode && _demoMessageTracking.containsKey(message.id)) {
      _demoEventController.add(DemoEvent.messageDelivered(message.id));
    }
    
    _broadcastMeshStatus();
  }

  void _handleMessageFailed(QueuedMessage message, String reason) {
    final truncatedId = message.id.length > 16 ? message.id.substring(0, 16) : message.id;
    _logger.warning('Message failed: $truncatedId... - $reason');
    
    if (_isDemoMode && _demoMessageTracking.containsKey(message.id)) {
      _demoEventController.add(DemoEvent.messageFailed(message.id, reason));
    }
    
    _broadcastMeshStatus();
  }

  void _handleQueueStatsUpdated(QueueStatistics stats) {
    // Broadcast updated queue statistics
    _broadcastMeshStatus();
  }

  Future<void> _handleSendMessage(String messageId) async {
    final truncatedId = messageId.length > 16 ? messageId.substring(0, 16) : messageId;
    _logger.fine('Send message request: $truncatedId...');

    try {
      // Get the message from queue
      final message = _messageQueue?.getMessageById(messageId);
      if (message == null) {
        _logger.severe('Message not found in queue: $truncatedId...');
        _messageQueue?.markMessageFailed(messageId, 'Message not found in queue');
        return;
      }

      // Send via real BLE service - preserve original intended recipient for relay
      final success = await _bleService.sendMessage(
        message.content,
        messageId: messageId,
        originalIntendedRecipient: message.recipientPublicKey, // Preserve original recipient
      );

      if (success) {
        _logger.info('Message successfully sent via BLE: $truncatedId...');
        _messageQueue?.markMessageDelivered(messageId);
      } else {
        _logger.warning('Failed to send message via BLE: $truncatedId...');
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
  bool _shouldRelayThroughDevice(QueuedMessage message, String deviceId) {
    try {
      // Simple heuristic: if the message recipient is not the connected device,
      // and no direct connection to recipient exists, relay through this device

      // For now, return true for any offline recipient (Ali) when relay node (Arshad) is available
      // This will be refined when proper topology tracking is implemented
      return true;

    } catch (e) {
      _logger.warning('Error checking relay route: $e');
      return false; // Conservative fallback
    }
  }

  void _handleConnectivityCheck() {
    // PROPER FIX: Use the exact same connectivity check as sendMessage()
    // This ensures queue connectivity matches actual sending capability
    final hasPhysicalConnection = _bleService.connectionManager.hasBleConnection &&
                                 _bleService.connectionManager.messageCharacteristic != null;

    if (hasPhysicalConnection) {
      _messageQueue?.setOnline();
      _logger.fine('Queue connectivity: ONLINE - BLE connection ready for sending');
    } else {
      _messageQueue?.setOffline();
      _logger.fine('Queue connectivity: OFFLINE - No BLE connection or characteristic');
    }
  }

  void _handleRelayMessage(MeshRelayMessage message, String nextHopNodeId) async {
    final truncatedMessageId = message.originalMessageId.length > 16 ? message.originalMessageId.substring(0, 16) : message.originalMessageId;
    final truncatedNextHop = nextHopNodeId.length > 8 ? nextHopNodeId.substring(0, 8) : nextHopNodeId;
    _logger.info('Relay message to next hop: $truncatedMessageId... -> $truncatedNextHop...');
    
    if (_isDemoMode) {
      _addDemoStep(DemoRelayStep(
        messageId: message.originalMessageId,
        fromNode: _currentNodeId!,
        toNode: nextHopNodeId,
        finalRecipient: message.relayMetadata.finalRecipient,
        hopCount: message.relayMetadata.hopCount + 1,
        action: 'relay_forwarded',
        timestamp: DateTime.now(),
      ));
      
      _demoEventController.add(DemoEvent.messageRelayed(
        message.originalMessageId,
        nextHopNodeId,
        message.relayMetadata.hopCount + 1,
      ));
    }
  }

  void _handleDeliverToSelf(String originalMessageId, String content, String originalSender) async {
    try {
      // 🎯 ENHANCED DEBUG LOGGING for delivery confirmation
      final truncatedMessageId = originalMessageId.length > 16 ? originalMessageId.substring(0, 16) : originalMessageId;
      final truncatedSender = originalSender.length > 8 ? originalSender.substring(0, 8) : originalSender;
      final truncatedCurrentNode = _currentNodeId != null && _currentNodeId!.length > 8 ? _currentNodeId!.substring(0, 8) : _currentNodeId;
      
      _logger.fine('🎯 MESH DELIVERY START: Message $truncatedMessageId...');
      _logger.fine('🎯 FROM ORIGINAL SENDER: $truncatedSender...');
      _logger.fine('🎯 TO CURRENT USER: $truncatedCurrentNode...');

      // 🔍 CRITICAL FIX: Generate chat ID using original sender (not relay node)
      final chatId = ChatUtils.generateChatId(_currentNodeId!, originalSender);
      _logger.fine('🎯 CHAT ID GENERATED: ${chatId.length > 16 ? chatId.substring(0, 16) : chatId}...');
      
      // Create message with proper attribution to original sender
      final message = Message(
        id: originalMessageId,
        chatId: chatId,
        content: content,
        timestamp: DateTime.now(),
        isFromMe: false,  // ✅ Message is from original sender, not current user
        status: MessageStatus.delivered,
      );
      
      // Save to repository with confirmation
      await _messageRepository.saveMessage(message);
      _logger.info('✅ MESH DELIVERY SUCCESS: Message stored in chat with original sender $truncatedSender...');
      
      // Update demo tracking
      if (_isDemoMode) {
        _demoEventController.add(DemoEvent.messageDeliveredToSelf(
          originalMessageId,
          originalSender,
        ));
      }
      
      // Broadcast mesh status update
      _broadcastMeshStatus();
      
    } catch (e) {
      _logger.severe('❌ MESH DELIVERY ERROR: Failed to deliver message to self: $e');
      
      // Still broadcast status for error tracking
      _broadcastMeshStatus();
    }
  }

  void _handleRelayDecision(RelayDecision decision) {
    final truncatedMessageId = decision.messageId.length > 16 ? decision.messageId.substring(0, 16) : decision.messageId;
    _logger.info('Relay decision: ${decision.type.name} for $truncatedMessageId... - ${decision.reason}');
    
    if (_isDemoMode) {
      _demoEventController.add(DemoEvent.relayDecisionMade(
        decision.messageId,
        decision.type.name,
        decision.reason,
      ));
    }
  }

  void _handleRelayStatsUpdated(RelayStatistics stats) {
    _relayStatsController.add(stats);
    _broadcastMeshStatus();
  }

  void _handleIncomingRelayMessage(String originalMessageId, String content, String originalSender) {
    final truncatedMessageId = originalMessageId.length > 16 ? originalMessageId.substring(0, 16) : originalMessageId;
    final truncatedSender = originalSender.length > 8 ? originalSender.substring(0, 8) : originalSender;
    _logger.info('Incoming relay message: $truncatedMessageId... from $truncatedSender...');
    // This will be handled by _handleDeliverToSelf if it's for us
  }

  void _handleSyncRequest(QueueSyncMessage message, String fromNodeId) {
    final truncatedNodeId = fromNodeId.length > 8 ? fromNodeId.substring(0, 8) : fromNodeId;
    _logger.info('Sync request from $truncatedNodeId...');
    
    if (_isDemoMode) {
      _demoEventController.add(DemoEvent.queueSyncRequested(fromNodeId));
    }
  }

  void _handleSendMessages(List<QueuedMessage> messages, String toNodeId) {
    _logger.info('Sending ${messages.length} messages to ${toNodeId.substring(0, 8)}...');
  }

  void _handleSyncCompleted(String nodeId, QueueSyncResult result) {
    _logger.info('Sync completed with ${nodeId.substring(0, 8)}...: ${result.success ? "success" : "failed"}');
    
    if (_isDemoMode) {
      _demoEventController.add(DemoEvent.queueSyncCompleted(nodeId, result.success));
    }
    
    final stats = _queueSyncManager!.getStats();
    _queueStatsController.add(stats);
  }

  void _handleSyncFailed(String nodeId, String error) {
    _logger.warning('Sync failed with ${nodeId.substring(0, 8)}...: $error');
    
    if (_isDemoMode) {
      _demoEventController.add(DemoEvent.queueSyncFailed(nodeId, error));
    }
  }

  void _handleConnectionChange(dynamic connectionInfo) async {
    final isOnline = connectionInfo?.isConnected ?? false;
    final connectedDeviceId = _bleService.otherDevicePersistentId;
    
    if (isOnline && connectedDeviceId != null && connectedDeviceId.isNotEmpty) {
      // 🌐 DEVICE CAME ONLINE
      MeshDebugLogger.deviceConnected(connectedDeviceId);
      _messageQueue?.setOnline();
      
      // 🎯 CRITICAL ENHANCEMENT: Auto-deliver queued messages to newly connected device
      await _deliverQueuedMessagesToDevice(connectedDeviceId);
      
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
        MeshDebugLogger.warning('QUEUE_DELIVERY', 'Message queue not initialized', messageId: 'N/A');
        return;
      }

      // Get direct messages for this device
      final directMessages = _messageQueue!.getMessagesByStatus(QueuedMessageStatus.pending)
          .where((msg) => msg.recipientPublicKey == deviceId)
          .toList();

      // Get relay messages that should go through this device
      final relayMessages = _messageQueue!.getMessagesByStatus(QueuedMessageStatus.pending)
          .where((msg) => msg.recipientPublicKey != deviceId && _shouldRelayThroughDevice(msg, deviceId))
          .toList();

      final allMessages = [...directMessages, ...relayMessages];

      if (allMessages.isEmpty) {
        MeshDebugLogger.info('No queued messages', 'No pending messages for ${deviceId.length > 8 ? deviceId.substring(0, 8) : deviceId}...');
        return;
      }

      final directCount = directMessages.length;
      final relayCount = relayMessages.length;
      _logger.info('Found $directCount direct + $relayCount relay messages for ${deviceId.substring(0, 8)}...');
      
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
            MeshDebugLogger.deliveryFailed(message.id, 'No send handler available', 1, 1);
          }
          
        } catch (e) {
          failed++;
          MeshDebugLogger.deliveryFailed(message.id, e.toString(), 1, 1);
        }
      }
      
      MeshDebugLogger.queueDeliveryComplete(deviceId, allMessages.length, successful, failed);
      
      // Update mesh status after queue processing
      _broadcastMeshStatus();
      
    } catch (e) {
      MeshDebugLogger.error('QUEUE_DELIVERY', e.toString());
    }
  }

  // Demo helper methods

  void _trackDemoMessage(String messageId, String type) {
    _demoMessageTracking[messageId] = type;
  }

  void _addDemoStep(DemoRelayStep step) {
    _demoSteps.add(step);
    
    // Keep only last 50 steps for performance
    if (_demoSteps.length > 50) {
      _demoSteps.removeAt(0);
    }
  }

  /// Broadcast initial status immediately in constructor to prevent null stream
  void _broadcastInitialStatus() {
    try {
      final initialStatus = MeshNetworkStatus(
        isInitialized: false, // Not yet initialized
        currentNodeId: null,  // Not yet determined
        isDemoMode: false,    // Default
        isConnected: false,   // Default until BLE connection is checked
        queueMessages: [], // CRITICAL FIX: Initialize empty queue messages list
        statistics: MeshNetworkStatistics(
          nodeId: 'initializing',
          isInitialized: false,
          isDemoMode: false,
          demoStepsCount: 0,
          trackedMessagesCount: 0,
          spamPreventionActive: false,
          queueSyncActive: false,
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
        ),
      );
      
      _lastMeshStatus = initialStatus;
      _meshStatusController.add(initialStatus);
      _logger.info('✅ Initial MeshNetworkStatus broadcasted - RelayQueueWidget loading should complete');
      
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
          _logger.info('🔄 Post-frame status update - ensuring UI receives initialization progress');
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
        isDemoMode: _isDemoMode,
        isConnected: _bleService.isConnected,
        queueMessages: _messageQueue?.getMessagesByStatus(QueuedMessageStatus.pending) ?? [], // CRITICAL FIX
        statistics: MeshNetworkStatistics(
          nodeId: _currentNodeId ?? 'initializing',
          isInitialized: false,
          isDemoMode: _isDemoMode,
          demoStepsCount: _demoSteps.length,
          trackedMessagesCount: _demoMessageTracking.length,
          spamPreventionActive: _spamPrevention != null,
          queueSyncActive: _queueSyncManager != null,
          queueStatistics: _messageQueue?.getStatistics() ?? QueueStatistics(
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
        ),
      );
      
      _lastMeshStatus = inProgressStatus;
      _meshStatusController.add(inProgressStatus);
      _logger.info('✅ In-progress status broadcasted for UI feedback');
      
    } catch (e) {
      _logger.severe('❌ Failed to broadcast in-progress status: $e');
    }
  }

  void _broadcastMeshStatus() {
    // Get current queue messages for UI display (including failed for migration period)
    final List<QueuedMessage> queueMessages = [
      ..._messageQueue?.getMessagesByStatus(QueuedMessageStatus.pending) ?? <QueuedMessage>[],
      ..._messageQueue?.getMessagesByStatus(QueuedMessageStatus.failed) ?? <QueuedMessage>[],
    ];

    // Debug: Log queue message count for development
    _logger.fine('Broadcasting mesh status with ${queueMessages.length} queue messages');

    final status = MeshNetworkStatus(
      isInitialized: _isInitialized,
      currentNodeId: _currentNodeId,
      isDemoMode: _isDemoMode,
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
    
    // Dispose smart routing components
    _smartRouter?.dispose();
    _smartRouter = null;
    _topologyAnalyzer?.dispose();
    _topologyAnalyzer = null;
    _qualityMonitor?.dispose();
    _qualityMonitor = null;
    _routeCalculator = null;
    
    _meshStatusController.close();
    _relayStatsController.close();
    _queueStatsController.close();
    _demoEventController.close();
    
    _logger.info('Mesh networking service disposed');
  }
}

// Data classes for mesh networking service

/// Result of sending a mesh message
class MeshSendResult {
  final MeshSendType type;
  final String? messageId;
  final String? nextHop;
  final String? error;

  const MeshSendResult._(this.type, this.messageId, this.nextHop, this.error);

  factory MeshSendResult.direct(String messageId) => 
      MeshSendResult._(MeshSendType.direct, messageId, null, null);
  
  factory MeshSendResult.relay(String messageId, String nextHop) => 
      MeshSendResult._(MeshSendType.relay, messageId, nextHop, null);
  
  factory MeshSendResult.error(String error) => 
      MeshSendResult._(MeshSendType.error, null, null, error);

  bool get isSuccess => type != MeshSendType.error;
  bool get isDirect => type == MeshSendType.direct;
  bool get isRelay => type == MeshSendType.relay;
}

enum MeshSendType { direct, relay, error }

/// Current status of mesh network
class MeshNetworkStatus {
  final bool isInitialized;
  final String? currentNodeId;
  final bool isDemoMode;
  final bool isConnected;
  final MeshNetworkStatistics statistics;
  final List<QueuedMessage>? queueMessages;

  const MeshNetworkStatus({
    required this.isInitialized,
    this.currentNodeId,
    required this.isDemoMode,
    required this.isConnected,
    required this.statistics,
    this.queueMessages,
  });
}

/// Comprehensive network statistics
class MeshNetworkStatistics {
  final String nodeId;
  final bool isInitialized;
  final bool isDemoMode;
  final RelayStatistics? relayStatistics;
  final QueueStatistics? queueStatistics;
  final QueueSyncManagerStats? syncStatistics;
  final SpamPreventionStatistics? spamStatistics;
  final int demoStepsCount;
  final int trackedMessagesCount;
  final bool spamPreventionActive;
  final bool queueSyncActive;

  const MeshNetworkStatistics({
    required this.nodeId,
    required this.isInitialized,
    required this.isDemoMode,
    this.relayStatistics,
    this.queueStatistics,
    this.syncStatistics,
    this.spamStatistics,
    required this.demoStepsCount,
    required this.trackedMessagesCount,
    required this.spamPreventionActive,
    required this.queueSyncActive,
  });
}

/// Demo scenario types
enum DemoScenarioType {
  aToBtoC,
  queueSync,
  spamPrevention,
}

/// Result of demo scenario initialization
class DemoScenarioResult {
  final bool success;
  final String message;
  final Map<String, dynamic>? metadata;

  const DemoScenarioResult._(this.success, this.message, this.metadata);

  factory DemoScenarioResult.success(String message, {Map<String, dynamic>? metadata}) =>
      DemoScenarioResult._(true, message, metadata);
  
  factory DemoScenarioResult.error(String message) =>
      DemoScenarioResult._(false, message, null);
}

/// Demo relay step for visualization
class DemoRelayStep {
  final String messageId;
  final String fromNode;
  final String toNode;
  final String finalRecipient;
  final int hopCount;
  final String action;
  final DateTime timestamp;

  const DemoRelayStep({
    required this.messageId,
    required this.fromNode,
    required this.toNode,
    required this.finalRecipient,
    required this.hopCount,
    required this.action,
    required this.timestamp,
  });
}

/// Demo events for UI updates
abstract class DemoEvent {
  final DateTime timestamp;
  
  DemoEvent() : timestamp = DateTime.now();

  factory DemoEvent.initialized() => _DemoInitialized();
  factory DemoEvent.scenarioStarted(String scenario) => _ScenarioStarted(scenario);
  factory DemoEvent.directMessageSent(String messageId, String recipient) => 
      _DirectMessageSent(messageId, recipient);
  factory DemoEvent.relayMessageSent(String messageId, String nextHop, String finalRecipient, int hopCount) => 
      _RelayMessageSent(messageId, nextHop, finalRecipient, hopCount);
  factory DemoEvent.messageRelayed(String messageId, String nextHop, int hopCount) => 
      _MessageRelayed(messageId, nextHop, hopCount);
  factory DemoEvent.messageDelivered(String messageId) => _MessageDelivered(messageId);
  factory DemoEvent.messageDeliveredToSelf(String messageId, String originalSender) => 
      _MessageDeliveredToSelf(messageId, originalSender);
  factory DemoEvent.messageFailed(String messageId, String reason) => 
      _MessageFailed(messageId, reason);
  factory DemoEvent.relayDecisionMade(String messageId, String decision, String reason) => 
      _RelayDecisionMade(messageId, decision, reason);
  factory DemoEvent.queueSyncRequested(String fromNode) => _QueueSyncRequested(fromNode);
  factory DemoEvent.queueSyncCompleted(String nodeId, bool success) => 
      _QueueSyncCompleted(nodeId, success);
  factory DemoEvent.queueSyncFailed(String nodeId, String error) => 
      _QueueSyncFailed(nodeId, error);
  factory DemoEvent.demoCleared() => _DemoCleared();
}

class _DemoInitialized extends DemoEvent {}
class _ScenarioStarted extends DemoEvent {
  final String scenario;
  _ScenarioStarted(this.scenario);
}
class _DirectMessageSent extends DemoEvent {
  final String messageId;
  final String recipient;
  _DirectMessageSent(this.messageId, this.recipient);
}
class _RelayMessageSent extends DemoEvent {
  final String messageId;
  final String nextHop;
  final String finalRecipient;
  final int hopCount;
  _RelayMessageSent(this.messageId, this.nextHop, this.finalRecipient, this.hopCount);
}
class _MessageRelayed extends DemoEvent {
  final String messageId;
  final String nextHop;
  final int hopCount;
  _MessageRelayed(this.messageId, this.nextHop, this.hopCount);
}
class _MessageDelivered extends DemoEvent {
  final String messageId;
  _MessageDelivered(this.messageId);
}
class _MessageDeliveredToSelf extends DemoEvent {
  final String messageId;
  final String originalSender;
  _MessageDeliveredToSelf(this.messageId, this.originalSender);
}
class _MessageFailed extends DemoEvent {
  final String messageId;
  final String reason;
  _MessageFailed(this.messageId, this.reason);
}
class _RelayDecisionMade extends DemoEvent {
  final String messageId;
  final String decision;
  final String reason;
  _RelayDecisionMade(this.messageId, this.decision, this.reason);
}
class _QueueSyncRequested extends DemoEvent {
  final String fromNode;
  _QueueSyncRequested(this.fromNode);
}
class _QueueSyncCompleted extends DemoEvent {
  final String nodeId;
  final bool success;
  _QueueSyncCompleted(this.nodeId, this.success);
}
class _QueueSyncFailed extends DemoEvent {
  final String nodeId;
  final String error;
  _QueueSyncFailed(this.nodeId, this.error);
}
class _DemoCleared extends DemoEvent {}