import 'dart:typed_data';
import 'package:logging/logging.dart';
import '../../core/interfaces/i_ble_message_handler_facade.dart';
import '../../core/interfaces/i_seen_message_store.dart';
import '../../core/models/protocol_message.dart';
import '../../core/models/mesh_relay_models.dart';
import '../../core/messaging/offline_message_queue.dart' show QueuedMessage;
import '../../core/messaging/queue_sync_manager.dart';
import '../../core/messaging/mesh_relay_engine.dart'
    show RelayDecision, RelayStatistics;
import '../../core/app_core.dart';
import 'ble_message_handler.dart';

/// Concrete implementation of IBLEMessageHandlerFacade
///
/// Wraps BLEMessageHandler with a simplified interface that matches
/// the requirements of MeshNetworkingService.
///
/// **Architecture Note**: This facade bridges the gap between IBLEMessageHandlerFacade
/// (simplified interface) and BLEMessageHandler (complex BLE implementation).
/// MeshNetworkingService only requires initialization and callback management.
/// Methods with incompatible BLE-specific signatures are stubbed (Phase 3B work).
class BLEMessageHandlerFacadeImpl implements IBLEMessageHandlerFacade {
  final _logger = Logger('BLEMessageHandlerFacadeImpl');

  final BLEMessageHandler _handler;
  late ISeenMessageStore _seenMessageStore;
  String? _currentNodeId;
  bool _initialized = false;

  BLEMessageHandlerFacadeImpl(this._handler, this._seenMessageStore) {
    _logger.info('🎯 BLEMessageHandlerFacadeImpl created');
  }

  @override
  void setCurrentNodeId(String nodeId) {
    _currentNodeId = nodeId;
    _handler.setCurrentNodeId(nodeId);
    _logger.fine('✅ Current node ID set');
  }

  @override
  Future<void> initializeRelaySystem({
    required String currentNodeId,
    Function(String originalMessageId, String content, String originalSender)?
    onRelayMessageReceived,
    Function(RelayDecision decision)? onRelayDecisionMade,
    Function(RelayStatistics stats)? onRelayStatsUpdated,
  }) async {
    try {
      _logger.info('🚀 Initializing relay system...');
      _currentNodeId = currentNodeId;

      if (!AppCore.instance.isInitialized) {
        _logger.warning('AppCore not initialized, initializing now...');
        await AppCore.instance.initialize();
      }

      final messageQueue = AppCore.instance.messageQueue;
      _logger.fine('📦 Using AppCore message queue');

      await _handler.initializeRelaySystem(
        currentNodeId: currentNodeId,
        messageQueue: messageQueue,
        onRelayMessageReceived: onRelayMessageReceived,
        onRelayDecisionMade: onRelayDecisionMade,
        onRelayStatsUpdated: onRelayStatsUpdated,
      );

      _initialized = true;
      _logger.info('✅ Relay system initialized');
    } catch (e) {
      _logger.severe('❌ Failed to initialize: $e');
      rethrow;
    }
  }

  @override
  void setSeenMessageStore(ISeenMessageStore seenMessageStore) {
    _seenMessageStore = seenMessageStore;
    _logger.fine('🎯 SeenMessageStore configured');
  }

  @override
  List<String> getAvailableNextHops() => _handler.getAvailableNextHops();

  @override
  Future<bool> sendMessage({
    required String recipientKey,
    required String content,
    required Duration timeout,
  }) async {
    _logger.warning('⚠️ sendMessage not integrated (BLE signature mismatch)');
    return false;
  }

  @override
  Future<bool> sendPeripheralMessage({
    required String senderKey,
    required String content,
  }) async {
    _logger.warning(
      '⚠️ sendPeripheralMessage not integrated (BLE signature mismatch)',
    );
    return false;
  }

  @override
  Future<String?> processReceivedData({
    required Uint8List data,
    required String fromDeviceId,
    required String fromNodeId,
  }) async {
    _logger.warning(
      '⚠️ processReceivedData not integrated (BLE signature mismatch)',
    );
    return null;
  }

  @override
  Future<void> handleQRIntroductionClaim({
    required String claimJson,
    required String fromDeviceId,
  }) async {
    _logger.warning('⚠️ handleQRIntroductionClaim not integrated');
  }

  @override
  Future<bool> checkQRIntroductionMatch({
    required String receivedHash,
    required String expectedHash,
  }) async {
    _logger.warning('⚠️ checkQRIntroductionMatch not integrated');
    return false;
  }

  @override
  Future<bool> sendQueueSyncMessage({
    required String toNodeId,
    required List<String> messageIds,
  }) async {
    _logger.warning('⚠️ sendQueueSyncMessage not integrated');
    return false;
  }

  @override
  Future<RelayStatistics> getRelayStatistics() async {
    try {
      final stats = _handler.getRelayStatistics();
      return stats ??
          RelayStatistics(
            totalRelayed: 0,
            totalDropped: 0,
            totalDeliveredToSelf: 0,
            totalBlocked: 0,
            totalProbabilisticSkip: 0,
            spamScore: 0,
            relayEfficiency: 0,
            activeRelayMessages: 0,
            networkSize: 0,
            currentRelayProbability: 0,
          );
    } catch (e) {
      _logger.severe('Failed to get relay statistics: $e');
      return RelayStatistics(
        totalRelayed: 0,
        totalDropped: 0,
        totalDeliveredToSelf: 0,
        totalBlocked: 0,
        totalProbabilisticSkip: 0,
        spamScore: 0,
        relayEfficiency: 0,
        activeRelayMessages: 0,
        networkSize: 0,
        currentRelayProbability: 0,
      );
    }
  }

  // Callback setters
  @override
  set onContactRequestReceived(
    Function(String contactKey, String displayName)? callback,
  ) => _handler.onContactRequestReceived = callback;

  @override
  set onContactAcceptReceived(
    Function(String contactKey, String displayName)? callback,
  ) => _handler.onContactAcceptReceived = callback;

  @override
  set onContactRejectReceived(Function()? callback) =>
      _handler.onContactRejectReceived = callback;

  @override
  set onCryptoVerificationReceived(
    Function(String verificationId, String contactKey)? callback,
  ) => _handler.onCryptoVerificationReceived = callback;

  @override
  set onCryptoVerificationResponseReceived(
    Function(
      String verificationId,
      String contactKey,
      bool isVerified,
      Map<String, dynamic>? data,
    )?
    callback,
  ) => _handler.onCryptoVerificationResponseReceived = callback;

  @override
  set onQueueSyncReceived(
    Function(QueueSyncMessage syncMessage, String fromNodeId)? callback,
  ) => _handler.onQueueSyncReceived = callback;

  @override
  set onSendQueueMessages(
    Function(List<QueuedMessage> messages, String toNodeId)? callback,
  ) => _handler.onSendQueueMessages = callback;

  @override
  set onQueueSyncCompleted(
    Function(String nodeId, QueueSyncResult result)? callback,
  ) => _handler.onQueueSyncCompleted = callback;

  @override
  set onRelayMessageReceived(
    Function(String originalMessageId, String content, String originalSender)?
    callback,
  ) => _handler.onRelayMessageReceived = callback;

  @override
  set onRelayDecisionMade(Function(RelayDecision decision)? callback) =>
      _handler.onRelayDecisionMade = callback;

  @override
  set onRelayStatsUpdated(Function(RelayStatistics stats)? callback) =>
      _handler.onRelayStatsUpdated = callback;

  @override
  set onSendAckMessage(Function(ProtocolMessage message)? callback) =>
      _handler.onSendAckMessage = callback;

  @override
  set onSendRelayMessage(
    Function(ProtocolMessage relayMessage, String nextHopId)? callback,
  ) => _handler.onSendRelayMessage = callback;

  @override
  set onIdentityRevealed(Function(String contactName)? callback) =>
      _handler.onIdentityRevealed = callback;

  @override
  void dispose() {
    _handler.dispose();
    _logger.info('♻️ BLEMessageHandlerFacadeImpl disposed');
  }
}
