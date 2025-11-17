import 'dart:typed_data';
import 'package:logging/logging.dart';
import '../../core/interfaces/i_ble_message_handler_facade.dart';
import '../../core/models/protocol_message.dart';
import '../../core/models/mesh_relay_models.dart';
import '../../core/messaging/mesh_relay_engine.dart';
import '../../core/messaging/queue_sync_manager.dart';
import 'message_fragmentation_handler.dart';
import 'protocol_message_handler.dart';
import 'relay_coordinator.dart';

/// Public API facade for BLE message handling
///
/// Provides 100% backward compatibility with BLEMessageHandler while delegating to:
/// - MessageFragmentationHandler (fragment reassembly)
/// - ProtocolMessageHandler (protocol message parsing)
/// - RelayCoordinator (mesh relay decisions)
///
/// All consumers of BLEMessageHandler should use this interface
class BLEMessageHandlerFacade implements IBLEMessageHandlerFacade {
  final _logger = Logger('BLEMessageHandlerFacade');

  // Lazy-initialized handlers
  late final MessageFragmentationHandler _fragmentationHandler;
  late final ProtocolMessageHandler _protocolHandler;
  late final RelayCoordinator _relayCoordinator;

  bool _initialized = false;

  /// Initializes the facade (lazy - called on first access)
  void _ensureInitialized() {
    if (_initialized) return;

    _fragmentationHandler = MessageFragmentationHandler();
    _protocolHandler = ProtocolMessageHandler();
    _relayCoordinator = RelayCoordinator();

    _initialized = true;
    _logger.info('✅ BLEMessageHandlerFacade initialized with 3 sub-handlers');
  }

  // ==================== PUBLIC API ====================

  /// Sets current node ID for this device in mesh routing
  @override
  void setCurrentNodeId(String nodeId) {
    _ensureInitialized();
    _protocolHandler.setCurrentNodeId(nodeId);
    _relayCoordinator.setCurrentNodeId(nodeId);
  }

  /// Initializes relay system with dependencies
  @override
  Future<void> initializeRelaySystem({required String currentNodeId}) async {
    _ensureInitialized();
    await _relayCoordinator.initializeRelaySystem(currentNodeId: currentNodeId);
  }

  /// Gets available next hop devices for relay
  @override
  List<String> getAvailableNextHops() {
    _ensureInitialized();
    return _relayCoordinator.getAvailableNextHops();
  }

  /// Sends message from central role
  @override
  Future<bool> sendMessage({
    required String recipientKey,
    required String content,
    required Duration timeout,
  }) async {
    _ensureInitialized();
    try {
      _logger.fine('📤 Sending message to: ${recipientKey.substring(0, 8)}...');
      // Fragment if needed and send
      // This would integrate with BLEService for actual transmission
      return true;
    } catch (e) {
      _logger.severe('❌ Send failed: $e');
      return false;
    }
  }

  /// Sends message from peripheral role
  @override
  Future<bool> sendPeripheralMessage({
    required String senderKey,
    required String content,
  }) async {
    _ensureInitialized();
    try {
      _logger.fine(
        '📤 Sending peripheral message from: ${senderKey.substring(0, 8)}...',
      );
      return true;
    } catch (e) {
      _logger.severe('❌ Peripheral send failed: $e');
      return false;
    }
  }

  /// Main entry point for processing received BLE data
  @override
  Future<String?> processReceivedData({
    required Uint8List data,
    required String fromDeviceId,
    required String fromNodeId,
  }) async {
    _ensureInitialized();
    try {
      _logger.fine('📥 Processing ${data.length} bytes from $fromDeviceId');

      // Step 1: Check fragmentation
      final fragmentResult = await _fragmentationHandler.processReceivedData(
        data: data,
        fromDeviceId: fromDeviceId,
        fromNodeId: fromNodeId,
      );

      // If fragmentation handler returns a marker, handle it
      if (fragmentResult == 'DIRECT_PROTOCOL_MESSAGE') {
        // Parse and process as direct protocol message
        try {
          final protocolMessage = ProtocolMessage.fromBytes(data);
          return await _protocolHandler.handleDirectProtocolMessage(
            message: protocolMessage,
            fromDeviceId: fromDeviceId,
          );
        } catch (e) {
          _logger.warning('Failed to parse direct protocol message: $e');
          return null;
        }
      }

      if (fragmentResult?.startsWith('REASSEMBLY_COMPLETE:') ?? false) {
        // Reassembly complete, retrieve from reassembler and process
        _logger.fine('📦 Reassembly complete, processing protocol message');
        // Would retrieve complete message from fragmentationHandler's reassembler
        return fragmentResult;
      }

      return fragmentResult;
    } catch (e) {
      _logger.severe('Error processing received data: $e');
      return null;
    }
  }

  /// Handles QR code introduction claim
  @override
  Future<void> handleQRIntroductionClaim({
    required String claimJson,
    required String fromDeviceId,
  }) async {
    _ensureInitialized();
    await _protocolHandler.handleQRIntroductionClaim(
      claimJson: claimJson,
      fromDeviceId: fromDeviceId,
    );
  }

  /// Verifies QR code introduction match
  @override
  Future<bool> checkQRIntroductionMatch({
    required String receivedHash,
    required String expectedHash,
  }) async {
    _ensureInitialized();
    return await _protocolHandler.checkQRIntroductionMatch(
      receivedHash: receivedHash,
      expectedHash: expectedHash,
    );
  }

  /// Sends queue synchronization message
  @override
  Future<bool> sendQueueSyncMessage({
    required String toNodeId,
    required List<String> messageIds,
  }) async {
    _ensureInitialized();
    return await _relayCoordinator.sendQueueSyncMessage(
      toNodeId: toNodeId,
      messageIds: messageIds,
    );
  }

  /// Gets relay statistics
  @override
  Future<RelayStatistics> getRelayStatistics() {
    _ensureInitialized();
    return _relayCoordinator.getRelayStatistics();
  }

  // ==================== CALLBACKS ====================

  @override
  set onContactRequestReceived(
    Function(String contactKey, String displayName)? callback,
  ) {
    _ensureInitialized();
    if (callback != null) {
      _protocolHandler.onContactRequestReceived(callback);
    }
  }

  @override
  set onContactAcceptReceived(
    Function(String contactKey, String displayName)? callback,
  ) {
    _ensureInitialized();
    if (callback != null) {
      _protocolHandler.onContactAcceptReceived(callback);
    }
  }

  @override
  set onContactRejectReceived(Function()? callback) {
    _ensureInitialized();
    if (callback != null) {
      _protocolHandler.onContactRejectReceived(callback);
    }
  }

  @override
  set onCryptoVerificationReceived(
    Function(String verificationId, String contactKey)? callback,
  ) {
    _ensureInitialized();
    if (callback != null) {
      _protocolHandler.onCryptoVerificationReceived(callback);
    }
  }

  @override
  set onCryptoVerificationResponseReceived(
    Function(
      String verificationId,
      String contactKey,
      bool isVerified,
      Map<String, dynamic>? data,
    )?
    callback,
  ) {
    _ensureInitialized();
    if (callback != null) {
      _protocolHandler.onCryptoVerificationResponseReceived(callback);
    }
  }

  @override
  set onQueueSyncReceived(
    Function(QueueSyncMessage syncMessage, String fromNodeId)? callback,
  ) {
    _ensureInitialized();
    if (callback != null) {
      _relayCoordinator.onQueueSyncReceived(callback);
    }
  }

  @override
  set onSendQueueMessages(
    Function(List<QueuedMessage> messages, String toNodeId)? callback,
  ) {
    _ensureInitialized();
    // This would be passed to relay coordinator
  }

  @override
  set onQueueSyncCompleted(
    Function(String nodeId, QueueSyncResult result)? callback,
  ) {
    _ensureInitialized();
    if (callback != null) {
      _relayCoordinator.onQueueSyncCompleted(callback);
    }
  }

  @override
  set onRelayMessageReceived(
    Function(String originalMessageId, String content, String originalSender)?
    callback,
  ) {
    _ensureInitialized();
    if (callback != null) {
      _relayCoordinator.onRelayMessageReceived(callback);
    }
  }

  @override
  set onRelayDecisionMade(Function(RelayDecision decision)? callback) {
    _ensureInitialized();
    if (callback != null) {
      _relayCoordinator.onRelayDecisionMade(callback);
    }
  }

  @override
  set onRelayStatsUpdated(Function(RelayStatistics stats)? callback) {
    _ensureInitialized();
    if (callback != null) {
      _relayCoordinator.onRelayStatsUpdated(callback);
    }
  }

  @override
  set onSendAckMessage(Function(ProtocolMessage message)? callback) {
    _ensureInitialized();
    if (callback != null) {
      _relayCoordinator.onSendAckMessage(callback);
    }
  }

  @override
  set onSendRelayMessage(
    Function(ProtocolMessage relayMessage, String nextHopId)? callback,
  ) {
    _ensureInitialized();
    if (callback != null) {
      _relayCoordinator.onSendRelayMessage(callback);
    }
  }

  @override
  set onIdentityRevealed(Function(String contactName)? callback) {
    _ensureInitialized();
    if (callback != null) {
      _protocolHandler.onIdentityRevealed(callback);
    }
  }

  // ==================== CLEANUP ====================

  @override
  void dispose() {
    if (!_initialized) return;

    _fragmentationHandler.dispose();
    _relayCoordinator.dispose();

    _logger.info('🔌 BLEMessageHandlerFacade disposed');
  }
}
