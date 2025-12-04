// Main orchestrator service for mesh networking functionality
// Integrates MeshRelayEngine, QueueSyncManager, SpamPreventionManager with BLE services
// Provides clean APIs and integration points for mesh-enabled messaging

// ignore_for_file: unnecessary_null_comparison, dead_code

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:get_it/get_it.dart';
import 'package:logging/logging.dart';
import 'package:pak_connect/core/utils/string_extensions.dart';
import 'package:path_provider/path_provider.dart';
import 'package:meta/meta.dart';

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
import '../../core/messaging/media_transfer_store.dart';
import '../../core/constants/binary_payload_types.dart';
import '../../core/interfaces/i_ble_messaging_service.dart' show BinaryPayload;
import '../../core/messaging/mesh_relay_engine.dart'
    show RelayDecision, RelayStatistics;
import '../../core/messaging/gossip_sync_manager.dart';
import '../../core/security/spam_prevention_manager.dart';
import '../../core/models/connection_info.dart';
import '../../domain/entities/enhanced_message.dart';
import '../../domain/entities/message.dart';
import '../../domain/services/chat_management_service.dart';
import '../models/mesh_network_models.dart';
import 'mesh/mesh_network_health_monitor.dart';
import 'mesh/mesh_queue_sync_coordinator.dart';
import 'mesh/mesh_relay_coordinator.dart';
import '../../core/utils/chat_utils.dart';

import 'package:pak_connect/domain/values/id_types.dart';

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
  final IContactRepository _contactRepository;
  // Note: _chatManagementService kept for API compatibility but not currently used
  // May be needed for future chat-related mesh operations (group chats, etc.)
  final IMessageRepository _messageRepository;

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
  }) async {
    final record = await _mediaStore.persist(
      data: data,
      metadata: {
        'recipientId': recipientId,
        'originalType': originalType,
        if (metadata != null) ...metadata,
      },
    );

    await _storeBinaryMessage(
      transferId: record.transferId,
      filePath: record.filePath,
      size: (record.bytes ?? data).length,
      originalType: originalType,
      isFromMe: true,
      status: MessageStatus.sending,
      peerNodeId: recipientId,
      recipientId: recipientId,
    );

    if (!_bleService.isConnected || !_bleService.canSendMessages) {
      _logger.fine(
        '⚠️ Offline for binary send; queued transfer ${record.transferId} for $recipientId',
      );
      // Prime BLE media store so retryBinaryMedia has bytes to send later.
      try {
        await _bleService.sendBinaryMedia(
          data: record.bytes ?? data,
          recipientId: recipientId,
          originalType: originalType,
          metadata: metadata,
          persistOnly: true,
        );
      } catch (e) {
        _logger.fine(
          '⚠️ Priming BLE media store for ${record.transferId} failed: $e',
        );
      }
      _pendingBinarySends.add(
        _PendingBinarySend(
          transferId: record.transferId,
          recipientId: recipientId,
          originalType: originalType,
        ),
      );
      await _persistPendingBinarySends();
      return record.transferId;
    }

    try {
      await _bleService.sendBinaryMedia(
        data: record.bytes ?? data,
        recipientId: recipientId,
        originalType: originalType,
        metadata: metadata,
      );
      await _updateBinaryMessageStatus(record.transferId, MessageStatus.sent);
    } catch (e) {
      _logger.fine(
        '⚠️ Binary send failed, queued for retry: ${record.transferId} ($e)',
      );
      _pendingBinarySends.add(
        _PendingBinarySend(
          transferId: record.transferId,
          recipientId: recipientId,
          originalType: originalType,
        ),
      );
      await _persistPendingBinarySends();
    }

    return record.transferId;
  }

  Future<void> _loadPendingBinarySends() async {
    try {
      final docs = await _getDocsDir();
      final file = File('${docs.path}/pending_binary_sends.json');
      if (!await file.exists()) {
        return;
      }
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is List) {
        _pendingBinarySends
          ..clear()
          ..addAll(
            decoded.whereType<Map<String, dynamic>>().map(
              (m) => _PendingBinarySend(
                transferId: m['transferId'] as String,
                recipientId: m['recipientId'] as String,
                originalType: m['originalType'] as int,
              ),
            ),
          );
        _logger.fine(
          '📂 Loaded ${_pendingBinarySends.length} pending binary sends from disk',
        );
      }
    } catch (e) {
      _logger.fine('⚠️ Failed to load pending binary sends: $e');
    }
  }

  Future<void> _persistPendingBinarySends() async {
    try {
      final docs = await _getDocsDir();
      final file = File('${docs.path}/pending_binary_sends.json');
      final payload = _pendingBinarySends
          .map(
            (p) => {
              'transferId': p.transferId,
              'recipientId': p.recipientId,
              'originalType': p.originalType,
            },
          )
          .toList();
      await file.writeAsString(jsonEncode(payload), flush: true);
    } catch (e) {
      _logger.fine('⚠️ Failed to persist pending binary sends: $e');
    }
  }

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
      await _loadPendingBinarySends();
      unawaited(
        _mediaStore.cleanupStaleTransfers().then((removed) {
          if (removed > 0) {
            _logger.fine(
              '🧹 Cleaned $removed stale binary payload(s) from disk',
            );
          }
        }),
      );

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

    // Get the shared queue from AppCore - ensure AppCore is initialized first.
    // Avoid re-entering AppCore initialization while it is already running,
    // since AppCore->mesh initialization can otherwise deadlock.
    if (!AppCore.instance.isInitialized) {
      if (AppCore.instance.isInitializing) {
        _logger.info(
          'AppCore initialization in progress; reusing shared queue without re-entry',
        );
      } else {
        _logger.warning('AppCore not initialized, initializing now...');
        await AppCore.instance.initialize();
      }
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

    _gossipSyncManager =
        GossipSyncManager(myNodeId: _currentNodeId!, messageQueue: sharedQueue)
          ..onSendSyncToPeer = (peerId, syncMessage) {
            _logger.fine(
              '📡 Gossip: sending sync to ${peerId.shortId(8)}... (${syncMessage.messageIds.length} ids)',
            );
            unawaited(_bleService.sendQueueSyncMessage(syncMessage));
          }
          ..onDirectAnnouncement = (peerId) {
            _scheduleInitialSyncForPeer(peerId, delay: Duration(seconds: 1));
          }
          ..onSendSyncRequest = (syncMessage) {
            final peers = _bleService.activeConnectionDeviceIds;
            if (peers.isEmpty) {
              _logger.fine('📡 Gossip: no peers to broadcast sync request');
              return;
            }
            for (final peer in peers) {
              _logger.fine(
                '📡 Gossip: broadcasting sync request to ${peer.shortId(8)}...',
              );
              unawaited(_bleService.sendQueueSyncMessage(syncMessage));
            }
          };

    // Initialize spam prevention
    _spamPrevention = SpamPreventionManager();
    await _spamPrevention!.initialize();

    await _relayCoordinator.initialize(
      nodeId: _currentNodeId!,
      messageQueue: sharedQueue,
      spamPrevention: _spamPrevention!,
    );

    if (_gossipSyncManager != null) {
      await _gossipSyncManager!.start();
    }

    _logger.info('Core mesh components initialized with dumb flood relay');
  }

  /// Set up integration with BLE layer
  Future<void> _setupBLEIntegration() async {
    // Initialize relay system in message handler
    await _messageHandler.initializeRelaySystem(
      currentNodeId: _currentNodeId!,
      onRelayDecisionMade: _handleRelayDecision,
      onRelayStatsUpdated: _handleRelayStatsUpdated,
    );

    // Set relay callbacks after initialization
    _messageHandler.onRelayDecisionMade = _handleRelayDecision;
    _messageHandler.onRelayStatsUpdated = _handleRelayStatsUpdated;

    _queueCoordinator.enableQueueSyncHandling();
    _queueCoordinator.startConnectionMonitoring();

    _connectionSub ??= _bleService.connectionInfo.listen(
      _handleConnectionUpdateForGossip,
      onError: (e) => _logger.fine('Connection stream error: $e'),
    );

    _identitySub ??= _bleService.identityRevealed.listen(
      _handleIdentityRevealedForGossip,
      onError: (e) => _logger.fine('Identity stream error: $e'),
    );

    _binarySub ??= _bleService.receivedBinaryStream.listen(
      (payload) => _handleBinaryPayload(payload),
      onError: (e) => _logger.fine('Binary stream error: $e'),
    );

    _logger.info('BLE integration set up');
  }

  void _handleConnectionUpdateForGossip(ConnectionInfo info) {
    if (!info.isReady) return;
    final peerId = _bleService.currentSessionId;
    if (peerId == null || peerId.isEmpty) return;
    _scheduleInitialSyncForPeer(peerId, delay: Duration(seconds: 1));
    unawaited(_flushPendingBinarySends());
  }

  void _handleIdentityRevealedForGossip(String peerId) {
    _scheduleInitialSyncForPeer(peerId, delay: Duration(seconds: 1));
  }

  void _scheduleInitialSyncForPeer(
    String peerId, {
    Duration delay = const Duration(seconds: 1),
  }) {
    if (peerId.isEmpty) return;
    if (_initialSyncPeers.contains(peerId)) return;
    _initialSyncPeers.add(peerId);
    _logger.fine(
      '📡 Scheduling initial gossip sync to ${peerId.shortId(8)}...',
    );
    final manager = _gossipSyncManager;
    if (manager != null) {
      unawaited(manager.scheduleInitialSyncToPeer(peerId, delay: delay));
    }
  }

  Future<void> _handleBinaryPayload(BinaryPayload payload) async {
    try {
      final record = await _mediaStore.persist(
        data: payload.data,
        metadata: {
          'fragmentId': payload.fragmentId,
          'originalType': payload.originalType,
          'recipient': payload.recipient,
          'ttl': payload.ttl,
          if (payload.senderNodeId != null)
            'senderNodeId': payload.senderNodeId,
        },
      );
      final event = ReceivedBinaryEvent(
        fragmentId: payload.fragmentId,
        originalType: payload.originalType,
        filePath: record.filePath,
        transferId: record.transferId,
        size: payload.data.length,
        ttl: payload.ttl,
        recipient: payload.recipient,
        senderNodeId: payload.senderNodeId,
      );
      _binaryController.add(event);
      _binaryEventHandler?.call(event);
      _logger.info(
        '💾 Stored binary payload ${payload.fragmentId.shortId(8)}... (${payload.data.length}B) at ${record.filePath}',
      );
      await _storeBinaryMessage(
        transferId: record.transferId,
        filePath: record.filePath,
        size: payload.data.length,
        originalType: payload.originalType,
        isFromMe: false,
        peerNodeId:
            payload.senderNodeId ??
            _bleService.currentSessionId ??
            payload.recipient,
        recipientId: payload.recipient,
        status: MessageStatus.delivered,
      );
    } catch (e) {
      _logger.warning(
        'Failed to persist binary payload ${payload.fragmentId}: $e',
      );
    }
  }

  Future<void> _flushPendingBinarySends() async {
    if (_pendingBinarySends.isEmpty) return;
    if (!_bleService.isConnected || !_bleService.canSendMessages) return;

    final pending = List<_PendingBinarySend>.from(_pendingBinarySends);
    _pendingBinarySends.clear();

    for (final pendingSend in pending) {
      final success = await retryBinaryMedia(
        transferId: pendingSend.transferId,
        recipientId: pendingSend.recipientId,
        originalType: pendingSend.originalType,
      );
      if (!success) {
        _pendingBinarySends.add(pendingSend);
        _logger.fine(
          '⚠️ Re-queued binary transfer ${pendingSend.transferId} for ${pendingSend.recipientId}',
        );
      } else {
        _logger.fine(
          '✅ Retried binary transfer ${pendingSend.transferId} for ${pendingSend.recipientId}',
        );
        await _updateBinaryMessageStatus(
          pendingSend.transferId,
          MessageStatus.sent,
        );
      }
    }
    await _persistPendingBinarySends();
  }

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
  }) async {
    final peerId = (peerNodeId ?? '').isNotEmpty ? peerNodeId! : null;
    if (peerId == null) {
      _logger.fine(
        '⚠️ Skipping binary message persistence for $transferId (no peer id)',
      );
      return;
    }

    final messageId = MessageId(transferId);
    final existing = await _messageRepository.getMessageById(messageId);
    if (existing != null) {
      return;
    }

    final chatId = ChatId(ChatUtils.generateChatId(peerId));
    final name = filePath.split('/').last;
    final attachment = MessageAttachment(
      id: transferId,
      type: originalType == BinaryPayloadType.media ? 'media' : 'binary',
      name: name,
      size: size,
      localPath: filePath,
      metadata: {
        'transferId': transferId,
        'originalType': originalType,
        'peerNodeId': peerId,
        if (recipientId != null) 'recipientId': recipientId,
        'direction': isFromMe ? 'outbound' : 'inbound',
      },
    );

    final message = EnhancedMessage(
      id: messageId,
      chatId: chatId,
      content: name,
      timestamp: DateTime.now(),
      isFromMe: isFromMe,
      status: status,
      attachments: [attachment],
      metadata: {
        'transferId': transferId,
        'filePath': filePath,
        'size': size,
        'originalType': originalType,
        'peerNodeId': peerId,
        if (recipientId != null) 'recipientId': recipientId,
      },
    );

    await _messageRepository.saveMessage(message);
    _logger.fine(
      '💾 Stored binary message ${transferId.shortId(8)}... in chat ${chatId.value.shortId(8)}...',
    );
  }

  Future<void> _updateBinaryMessageStatus(
    String transferId,
    MessageStatus status,
  ) async {
    final existing = await _messageRepository.getMessageById(
      MessageId(transferId),
    );
    if (existing == null || existing.status == status) return;

    final updated = existing.copyWith(status: status);
    await _messageRepository.updateMessage(updated);
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
    _gossipSyncManager?.stop();
    _connectionSub?.cancel();
    _connectionSub = null;
    _identitySub?.cancel();
    _identitySub = null;
    _binarySub?.cancel();
    _binarySub = null;
    _binaryController.close();
    _healthMonitor.dispose();

    _logger.info('Mesh networking service disposed');
  }
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
