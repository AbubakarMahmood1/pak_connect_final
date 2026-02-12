// Main orchestrator service for mesh networking functionality
// Integrates MeshRelayEngine, QueueSyncManager, SpamPreventionManager with BLE services
// Provides clean APIs and integration points for mesh-enabled messaging

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:get_it/get_it.dart';
import 'package:logging/logging.dart';
import 'package:pak_connect/domain/utils/string_extensions.dart';
import 'package:path_provider/path_provider.dart';
import 'package:meta/meta.dart';

import '../interfaces/i_ble_message_handler_facade.dart';
import '../interfaces/i_mesh_networking_service.dart';
import '../messaging/queue_sync_manager.dart'
    show QueueSyncManagerStats, QueueSyncResult;
import '../messaging/media_transfer_store.dart';
import '../messaging/gossip_sync_manager.dart';
import 'spam_prevention_manager.dart';
import '../../domain/entities/enhanced_message.dart';
import '../../domain/entities/message.dart';
import '../../domain/services/chat_management_service.dart';
import '../models/connection_info.dart';
import '../models/mesh_network_models.dart';
import '../models/bluetooth_state_models.dart';
import '../constants/binary_payload_types.dart';
import '../interfaces/i_shared_message_queue_provider.dart';
import 'mesh/mesh_network_health_monitor.dart';
import 'mesh/mesh_queue_sync_coordinator.dart';
import 'mesh/mesh_relay_coordinator.dart';
import '../utils/chat_utils.dart';
import '../interfaces/i_message_repository.dart';
import '../interfaces/i_connection_service.dart';
import '../interfaces/i_repository_provider.dart';
import '../models/binary_payload.dart';
import '../models/mesh_relay_models.dart' show RelayDecision, RelayStatistics;

import 'package:pak_connect/domain/values/id_types.dart';
import 'package:pak_connect/domain/entities/queued_message.dart';

part 'mesh_networking_binary_helper.dart';
part 'mesh_networking_runtime_helper.dart';

/// Main orchestrator service for mesh networking functionality
/// Coordinates all mesh components behind a clean application-facing API
class MeshNetworkingService implements IMeshNetworkingService {
  static final _logger = Logger('MeshNetworkingService');

  // Core mesh components
  SpamPreventionManager? _spamPrevention;
  late final MeshRelayCoordinator _relayCoordinator;
  late final MeshQueueSyncCoordinator _queueCoordinator;
  GossipSyncManager? _gossipSyncManager;
  final MeshNetworkHealthMonitor _healthMonitor;
  bool _integrationCancelled = false;
  StreamSubscription<BinaryPayload>? _binarySub;
  StreamSubscription<String>? _identitySub;
  final StreamController<ReceivedBinaryEvent> _binaryController =
      StreamController.broadcast();
  void Function(ReceivedBinaryEvent event)? _binaryEventHandler;
  final List<_PendingBinarySend> _pendingBinarySends = [];
  Directory? _docsDir;

  // Integration services
  // 🎯 NOTE: MeshNetworkingService depends on the connection abstraction
  // (IConnectionService) implemented by BLEServiceFacade to stay decoupled
  // from concrete data-layer implementations.
  final IConnectionService _bleService;
  final IBLEMessageHandlerFacade _messageHandler;
  // Note: _chatManagementService kept for API compatibility but not currently used
  // May be needed for future chat-related mesh operations (group chats, etc.)
  final IMessageRepository _messageRepository;
  final ISharedMessageQueueProvider _sharedQueueProvider;

  // State management
  String? _currentNodeId;
  bool _isInitialized = false;
  StreamSubscription<ConnectionInfo>? _connectionSub;
  final Set<String> _initialSyncPeers = {};

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

  /// Stream of received binary/media payloads saved to disk.
  @override
  Stream<ReceivedBinaryEvent> get binaryPayloadStream =>
      _binaryController.stream;

  /// Optional direct handler for binary payload routing (UI/media).
  void setBinaryPayloadHandler(
    void Function(ReceivedBinaryEvent event)? handler,
  ) {
    _binaryEventHandler = handler;
  }

  /// Send a binary/media payload and return transferId for retry tracking.
  /// The BLE layer will attempt Noise encryption if a session is available.
  @override
  Future<String> sendBinaryMedia({
    required Uint8List data,
    required String recipientId,
    int originalType = BinaryPayloadType.media,
    Map<String, dynamic>? metadata,
  }) => _sendOrQueueBinaryMedia(
    data: data,
    recipientId: recipientId,
    originalType: originalType,
    metadata: metadata,
  );

  /// Retry a previously persisted binary/media payload.
  @override
  Future<bool> retryBinaryMedia({
    required String transferId,
    String? recipientId,
    int? originalType,
  }) => _bleService.retryBinaryMedia(
    transferId: transferId,
    recipientId: recipientId,
    originalType: originalType,
  );

  Future<String> _sendOrQueueBinaryMedia({
    required Uint8List data,
    required String recipientId,
    required int originalType,
    Map<String, dynamic>? metadata,
  }) => _binaryHelper.sendOrQueueBinaryMedia(
    data: data,
    recipientId: recipientId,
    originalType: originalType,
    metadata: metadata,
  );

  Future<void> _loadPendingBinarySends() =>
      _binaryHelper.loadPendingBinarySends();

  Future<void> _persistPendingBinarySends() =>
      _binaryHelper.persistPendingBinarySends();

  Future<Directory> _getDocsDir() async {
    if (_docsDir != null) return _docsDir!;
    _docsDir = await getApplicationDocumentsDirectory();
    return _docsDir!;
  }

  MeshRelayCoordinator get relayCoordinator => _relayCoordinator;

  MeshQueueSyncCoordinator get queueCoordinator => _queueCoordinator;

  MeshNetworkHealthMonitor get healthMonitor => _healthMonitor;
  final MediaTransferStore _mediaStore = MediaTransferStore(
    subDirectory: 'binary_payloads',
  );
  late final _MeshNetworkingBinaryHelper _binaryHelper;
  late final _MeshNetworkingRuntimeHelper _runtimeHelper;
  @visibleForTesting
  int get pendingBinarySendCount => _pendingBinarySends.length;
  @visibleForTesting
  bool debugHasInitialSyncScheduled(String peerId) =>
      _initialSyncPeers.contains(peerId);

  @override
  List<PendingBinaryTransfer> getPendingBinaryTransfers() => _pendingBinarySends
      .map(
        (p) => PendingBinaryTransfer(
          transferId: p.transferId,
          recipientId: p.recipientId,
          originalType: p.originalType,
        ),
      )
      .toList(growable: false);

  MeshNetworkingService({
    required IConnectionService bleService,
    required IBLEMessageHandlerFacade messageHandler,
    // ✅ Phase 3A: Now properly typed via BLEMessageHandlerFacadeImpl adapter
    required ChatManagementService
    chatManagementService, // Kept for API compatibility
    IRepositoryProvider? repositoryProvider,
    ISharedMessageQueueProvider? sharedQueueProvider,
    MeshRelayCoordinator? relayCoordinator,
    MeshNetworkHealthMonitor? healthMonitor,
    MeshQueueSyncCoordinator? queueCoordinator,
    MeshRelayEngineFactory? relayEngineFactory,
  }) : _bleService = bleService,
       _messageHandler = messageHandler,
       _messageRepository =
           (repositoryProvider ?? GetIt.instance<IRepositoryProvider>())
               .messageRepository,
       _sharedQueueProvider = _resolveSharedQueueProvider(sharedQueueProvider),
       _healthMonitor = healthMonitor ?? MeshNetworkHealthMonitor() {
    _relayCoordinator =
        relayCoordinator ??
        MeshRelayCoordinator(
          bleService: _bleService,
          onRelayDecision: _handleRelayDecision,
          onRelayStatsUpdated: _handleRelayStatsUpdated,
          onDeliverToSelf: _handleDeliverToSelf,
          relayEngineFactory: relayEngineFactory,
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

    _binaryHelper = _MeshNetworkingBinaryHelper(this);
    _runtimeHelper = _MeshNetworkingRuntimeHelper(this);

    _healthMonitor.broadcastInitialStatus();
    _healthMonitor.schedulePostFrameStatusUpdate(
      isInitialized: () => _isInitialized,
      nodeIdProvider: () => _currentNodeId,
      queueSnapshotProvider: () => _queueCoordinator.getActiveQueueMessages(),
      statisticsProvider: () => getNetworkStatistics(),
      isConnectedProvider: () => _bleService.isConnected,
    );
  }

  static ISharedMessageQueueProvider _resolveSharedQueueProvider(
    ISharedMessageQueueProvider? sharedQueueProvider,
  ) {
    if (sharedQueueProvider != null) {
      return sharedQueueProvider;
    }
    if (GetIt.instance.isRegistered<ISharedMessageQueueProvider>()) {
      return GetIt.instance<ISharedMessageQueueProvider>();
    }
    throw StateError(
      'ISharedMessageQueueProvider is not registered. '
      'Pass sharedQueueProvider explicitly or register it in DI.',
    );
  }

  /// Initialize the mesh networking service
  @override
  Future<void> initialize({String? nodeId}) =>
      _runtimeHelper.initialize(nodeId: nodeId);

  /// Initialize core mesh networking components
  Future<void> _initializeCoreComponents() =>
      _runtimeHelper.initializeCoreComponents();

  /// Set up integration with BLE layer
  Future<void> _setupBLEIntegration() => _runtimeHelper.setupBleIntegration();

  void _handleConnectionUpdateForGossip(ConnectionInfo info) =>
      _runtimeHelper.handleConnectionUpdateForGossip(info);

  void _handleIdentityRevealedForGossip(String peerId) =>
      _runtimeHelper.handleIdentityRevealedForGossip(peerId);

  void _scheduleInitialSyncForPeer(
    String peerId, {
    Duration delay = const Duration(seconds: 1),
  }) => _runtimeHelper.scheduleInitialSyncForPeer(peerId, delay: delay);

  Future<void> _handleBinaryPayload(BinaryPayload payload) =>
      _binaryHelper.handleBinaryPayload(payload);

  Future<void> _flushPendingBinarySends() =>
      _binaryHelper.flushPendingBinarySends();

  @visibleForTesting
  Future<void> debugHandleBinaryPayload(BinaryPayload payload) =>
      _handleBinaryPayload(payload);

  @visibleForTesting
  Future<void> debugFlushPendingBinarySends() => _flushPendingBinarySends();

  @visibleForTesting
  void debugHandleIdentityForSync(String peerId) =>
      _handleIdentityRevealedForGossip(peerId);

  @visibleForTesting
  void debugHandleAnnounceForSync(String peerId) =>
      _scheduleInitialSyncForPeer(peerId, delay: Duration(seconds: 1));

  Future<void> _storeBinaryMessage({
    required String transferId,
    required String filePath,
    required int size,
    required int originalType,
    required bool isFromMe,
    required MessageStatus status,
    String? peerNodeId,
    String? recipientId,
  }) => _binaryHelper.storeBinaryMessage(
    transferId: transferId,
    filePath: filePath,
    size: size,
    originalType: originalType,
    isFromMe: isFromMe,
    status: status,
    peerNodeId: peerNodeId,
    recipientId: recipientId,
  );

  Future<void> _updateBinaryMessageStatus(
    String transferId,
    MessageStatus status,
  ) => _binaryHelper.updateBinaryMessageStatus(transferId, status);

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
  Future<String> _getNodeIdWithFallback() =>
      _runtimeHelper.getNodeIdWithFallback();

  /// Generate a fallback node ID when BLE service is unavailable
  String _generateFallbackNodeId() => _runtimeHelper.generateFallbackNodeId();

  Future<void> _waitForBluetoothReady({
    Duration timeout = const Duration(seconds: 25),
  }) => _runtimeHelper.waitForBluetoothReady(timeout: timeout);

  /// Set up BLE integration with fallback handling
  Future<void> _setupBLEIntegrationWithFallback() =>
      _runtimeHelper.setupBleIntegrationWithFallback();

  /// Set up minimal BLE integration when full integration fails
  void _setupMinimalBLEIntegration() =>
      _runtimeHelper.setupMinimalBleIntegration();

  /// Broadcast fallback status when initialization fails
  void _broadcastFallbackStatus() => _runtimeHelper.broadcastFallbackStatus();

  /// Send message through mesh network (main API for UI)
  @override
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
    if (!connectionInfo.isConnected || !connectionInfo.isReady) {
      return false;
    }

    final connectedNodeId = _bleService.currentSessionId;
    return connectedNodeId == recipientPublicKey;
  }

  /// Get comprehensive network statistics
  @override
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
  @override
  void refreshMeshStatus() {
    _broadcastMeshStatus();
  }

  /// Sync queues with connected nodes
  @override
  Future<Map<String, QueueSyncResult>> syncQueuesWithPeers() async {
    final availableNodes = await _relayCoordinator.getAvailableNextHops();
    return _queueCoordinator.syncWithPeers(availableNodes);
  }

  /// Retry a specific message in the queue
  @override
  Future<bool> retryMessage(String messageId) async {
    return _queueCoordinator.retryMessage(messageId);
  }

  /// Remove a specific message from the queue
  @override
  Future<bool> removeMessage(String messageId) async {
    return _queueCoordinator.removeMessage(messageId);
  }

  /// Set high priority for a specific message
  @override
  Future<bool> setPriority(String messageId, MessagePriority priority) async {
    return _queueCoordinator.setPriority(messageId, priority);
  }

  /// Retry all failed messages
  @override
  Future<int> retryAllMessages() async {
    return _queueCoordinator.retryAllMessages();
  }

  /// Get queued messages for a specific chat (for UI display)
  /// Returns only in-flight messages (pending, sending, retrying)
  /// Excludes delivered messages (those have moved to MessageRepository)
  @override
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
        id: MessageId(originalMessageId),
        chatId: ChatId(chatId),
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

  void _broadcastMeshStatus() => _runtimeHelper.broadcastMeshStatus();

  /// Dispose of all resources
  @override
  void dispose() => _runtimeHelper.dispose();
}

class ReceivedBinaryEvent {
  ReceivedBinaryEvent({
    required this.fragmentId,
    required this.originalType,
    required this.filePath,
    required this.size,
    required this.transferId,
    required this.ttl,
    this.recipient,
    this.senderNodeId,
  });

  final String fragmentId;
  final int originalType;
  final String filePath;
  final int size;
  final String transferId;
  final int ttl;
  final String? recipient;
  final String? senderNodeId;
}

class _PendingBinarySend {
  _PendingBinarySend({
    required this.transferId,
    required this.recipientId,
    required this.originalType,
  });

  final String transferId;
  final String recipientId;
  final int originalType;
}

class PendingBinaryTransfer {
  PendingBinaryTransfer({
    required this.transferId,
    required this.recipientId,
    required this.originalType,
  });

  final String transferId;
  final String recipientId;
  final int originalType;
}
