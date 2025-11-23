import 'dart:io';
import 'dart:typed_data';
import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:logging/logging.dart';
import '../../core/interfaces/i_ble_message_handler_facade.dart';
import '../../core/interfaces/i_seen_message_store.dart';
import '../../core/models/protocol_message.dart';
import '../../core/models/mesh_relay_models.dart';
import '../../core/messaging/offline_message_queue.dart'
    show QueuedMessage, OfflineMessageQueue;
import '../../core/messaging/queue_sync_manager.dart';
import '../../core/messaging/mesh_relay_engine.dart'
    show RelayDecision, RelayStatistics;
import '../../core/security/spam_prevention_manager.dart';
import '../../core/app_core.dart';
import '../../data/repositories/contact_repository.dart';
import '../../core/interfaces/i_ble_state_manager_facade.dart';
import '../services/ble_state_manager_facade.dart';
import '../services/ble_state_manager.dart';
import 'ble_message_handler.dart';
import 'ble_message_handler_facade.dart';
import 'ble_connection_manager.dart';
import 'ble_write_adapter.dart';

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
  late final BLEMessageHandlerFacade _splitFacade;
  final ContactRepository _contactRepository = ContactRepository();
  late ISeenMessageStore _seenMessageStore;
  final BLEConnectionManager? _connectionManager;
  final IBLEStateManagerFacade? _stateManager;
  late final BleWriteAdapter _writeAdapter;
  final CentralManager Function()? _getCentralManager;
  final PeripheralManager Function()? _getPeripheralManager;
  final Central? Function()? _getConnectedCentral;
  final GATTCharacteristic? Function()? _getMessageCharacteristic;
  final GATTCharacteristic? Function()? _getPeripheralMessageCharacteristic;
  final bool Function()? _getPeripheralMtuReady;
  final int? Function()? _getPeripheralNegotiatedMtu;
  final void Function(bool)? _onMessageOperationChanged;
  String? _currentNodeId;
  bool _initialized = false;

  BLEMessageHandlerFacadeImpl(
    this._handler,
    this._seenMessageStore, {
    BLEConnectionManager? connectionManager,
    IBLEStateManagerFacade? stateManager,
    CentralManager Function()? getCentralManager,
    PeripheralManager Function()? getPeripheralManager,
    Central? Function()? getConnectedCentral,
    GATTCharacteristic? Function()? getMessageCharacteristic,
    GATTCharacteristic? Function()? getPeripheralMessageCharacteristic,
    bool Function()? getPeripheralMtuReady,
    int? Function()? getPeripheralNegotiatedMtu,
    void Function(bool)? onMessageOperationChanged,
    bool enableFragmentCleanupTimer = false,
  }) : _connectionManager = connectionManager,
       _stateManager = stateManager,
       _getCentralManager = getCentralManager,
       _getPeripheralManager = getPeripheralManager,
       _getConnectedCentral = getConnectedCentral,
       _getMessageCharacteristic = getMessageCharacteristic,
       _getPeripheralMessageCharacteristic = getPeripheralMessageCharacteristic,
       _getPeripheralMtuReady = getPeripheralMtuReady,
       _getPeripheralNegotiatedMtu = getPeripheralNegotiatedMtu,
       _onMessageOperationChanged = onMessageOperationChanged {
    final cleanupEnabled =
        enableFragmentCleanupTimer &&
        !Platform.environment.containsKey('FLUTTER_TEST');
    _splitFacade = BLEMessageHandlerFacade(enableCleanupTimer: cleanupEnabled);
    _logger.info('🎯 BLEMessageHandlerFacadeImpl created');
    _splitFacade.setSeenMessageStore(_seenMessageStore);
    _splitFacade.configureSenders(
      sendCentral: _sendCentralViaAdapter,
      sendPeripheral: _sendPeripheralViaAdapter,
    );
    _splitFacade.setNextHopsProvider(_handler.getAvailableNextHops);
    try {
      if (AppCore.instance.isInitialized) {
        _splitFacade.setMessageQueue(AppCore.instance.messageQueue);
      }
    } catch (_) {}
    _writeAdapter = BleWriteAdapter(
      contactRepository: _contactRepository,
      stateManagerProvider: _inferLegacyStateManager,
      onMessageOperationChanged: _onMessageOperationChanged,
      logger: Logger('BleWriteAdapter'),
    );
  }

  @override
  void setCurrentNodeId(String nodeId) {
    _currentNodeId = nodeId;
    _splitFacade.setCurrentNodeId(nodeId);
    _handler.setCurrentNodeId(nodeId);
    _writeAdapter.setCurrentNodeId(nodeId);
    _logger.fine('✅ Current node ID set');
  }

  @override
  Future<void> initializeRelaySystem({
    required String currentNodeId,
    Function(String originalMessageId, String content, String originalSender)?
    onRelayMessageReceived,
    Function(RelayDecision decision)? onRelayDecisionMade,
    Function(RelayStatistics stats)? onRelayStatsUpdated,
    List<String> Function()? nextHopsProvider,
  }) async {
    try {
      _logger.info('🚀 Initializing relay system...');
      _currentNodeId = currentNodeId;

      await _splitFacade.initializeRelaySystem(
        currentNodeId: currentNodeId,
        onRelayMessageReceived: onRelayMessageReceived,
        onRelayDecisionMade: onRelayDecisionMade,
        onRelayStatsUpdated: onRelayStatsUpdated,
        nextHopsProvider: nextHopsProvider,
      );

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
    _splitFacade.setSeenMessageStore(seenMessageStore);
    _logger.fine('🎯 SeenMessageStore configured');
  }

  @override
  void setMessageQueue(OfflineMessageQueue queue) {
    _splitFacade.setMessageQueue(queue);
  }

  @override
  void setSpamPreventionManager(SpamPreventionManager manager) {
    _splitFacade.setSpamPreventionManager(manager);
  }

  @override
  void setNextHopsProvider(List<String> Function() provider) {
    _splitFacade.setNextHopsProvider(provider);
  }

  @override
  List<String> getAvailableNextHops() => _handler.getAvailableNextHops();

  @override
  Future<bool> sendMessage({
    required String recipientKey,
    required String content,
    required Duration timeout,
    String? messageId,
    String? originalIntendedRecipient,
  }) async {
    return _sendCentralViaAdapter(
      recipientKey: recipientKey,
      content: content,
      timeout: timeout,
      messageId: messageId,
      originalIntendedRecipient: originalIntendedRecipient,
    );
  }

  @override
  Future<bool> sendPeripheralMessage({
    required String senderKey,
    required String content,
    String? messageId,
  }) async {
    return _sendPeripheralViaAdapter(
      senderKey: senderKey,
      content: content,
      messageId: messageId,
    );
  }

  @override
  Future<String?> processReceivedData({
    required Uint8List data,
    required String fromDeviceId,
    required String fromNodeId,
  }) async {
    try {
      final splitResult = await _splitFacade.processReceivedData(
        data: data,
        fromDeviceId: fromDeviceId,
        fromNodeId: fromNodeId,
      );

      if (splitResult != null &&
          splitResult != 'DIRECT_PROTOCOL_MESSAGE' &&
          !splitResult.startsWith('REASSEMBLY_COMPLETE:')) {
        return splitResult;
      }

      if (splitResult != null &&
          splitResult.startsWith('REASSEMBLY_COMPLETE:')) {
        final messageId = splitResult.substring('REASSEMBLY_COMPLETE:'.length);
        final reassembledBytes = _splitFacade.takeReassembledMessageBytes(
          messageId,
        );

        if (reassembledBytes != null) {
          return await _handler.processReceivedData(
            reassembledBytes,
            senderPublicKey: fromNodeId,
            contactRepository: _contactRepository,
          );
        }

        _logger.warning(
          '⚠️ Reassembled bytes missing for $messageId, falling back to raw chunk',
        );
      }

      return await _handler.processReceivedData(
        data,
        senderPublicKey: fromNodeId,
        contactRepository: _contactRepository,
      );
    } catch (e) {
      _logger.warning('⚠️ processReceivedData failed: $e');
      return null;
    }
  }

  @override
  Future<void> handleQRIntroductionClaim({
    required String claimJson,
    required String fromDeviceId,
  }) async {
    await _splitFacade.handleQRIntroductionClaim(
      claimJson: claimJson,
      fromDeviceId: fromDeviceId,
    );
  }

  @override
  Future<bool> checkQRIntroductionMatch({
    required String receivedHash,
    required String expectedHash,
  }) async {
    return await _splitFacade.checkQRIntroductionMatch(
      receivedHash: receivedHash,
      expectedHash: expectedHash,
    );
  }

  @override
  Future<bool> sendQueueSyncMessage({
    required String toNodeId,
    required List<String> messageIds,
  }) async {
    return await _splitFacade.sendQueueSyncMessage(
      toNodeId: toNodeId,
      messageIds: messageIds,
    );
  }

  @override
  Future<RelayStatistics> getRelayStatistics() async {
    final fallbackStats = RelayStatistics(
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

    try {
      final splitStats = await _splitFacade.getRelayStatistics();
      return splitStats;
    } catch (e) {
      _logger.fine('Split relay statistics unavailable: $e');
    }

    try {
      final stats = _handler.getRelayStatistics();
      if (stats != null) {
        return stats;
      }
    } catch (e) {
      _logger.severe('Failed to get relay statistics: $e');
    }

    return fallbackStats;
  }

  // Callback setters
  @override
  set onContactRequestReceived(
    Function(String contactKey, String displayName)? callback,
  ) {
    _handler.onContactRequestReceived = callback;
    _splitFacade.onContactRequestReceived = callback;
  }

  @override
  set onContactAcceptReceived(
    Function(String contactKey, String displayName)? callback,
  ) {
    _handler.onContactAcceptReceived = callback;
    _splitFacade.onContactAcceptReceived = callback;
  }

  @override
  set onContactRejectReceived(Function()? callback) {
    _handler.onContactRejectReceived = callback;
    _splitFacade.onContactRejectReceived = callback;
  }

  @override
  set onCryptoVerificationReceived(
    Function(String verificationId, String contactKey)? callback,
  ) {
    _handler.onCryptoVerificationReceived = callback;
    _splitFacade.onCryptoVerificationReceived = callback;
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
    _handler.onCryptoVerificationResponseReceived = callback;
    _splitFacade.onCryptoVerificationResponseReceived = callback;
  }

  @override
  set onQueueSyncReceived(
    Function(QueueSyncMessage syncMessage, String fromNodeId)? callback,
  ) {
    _handler.onQueueSyncReceived = callback;
    _splitFacade.onQueueSyncReceived = callback;
  }

  @override
  set onSendQueueMessages(
    Function(List<QueuedMessage> messages, String toNodeId)? callback,
  ) {
    _handler.onSendQueueMessages = callback;
    _splitFacade.onSendQueueMessages = callback;
  }

  @override
  set onQueueSyncCompleted(
    Function(String nodeId, QueueSyncResult result)? callback,
  ) {
    _handler.onQueueSyncCompleted = callback;
    _splitFacade.onQueueSyncCompleted = callback;
  }

  @override
  set onRelayMessageReceived(
    Function(String originalMessageId, String content, String originalSender)?
    callback,
  ) {
    _handler.onRelayMessageReceived = callback;
    _splitFacade.onRelayMessageReceived = callback;
  }

  @override
  set onRelayDecisionMade(Function(RelayDecision decision)? callback) {
    _handler.onRelayDecisionMade = callback;
    _splitFacade.onRelayDecisionMade = callback;
  }

  @override
  set onRelayStatsUpdated(Function(RelayStatistics stats)? callback) {
    _handler.onRelayStatsUpdated = callback;
    _splitFacade.onRelayStatsUpdated = callback;
  }

  @override
  set onSendAckMessage(Function(ProtocolMessage message)? callback) {
    _handler.onSendAckMessage = callback;
    _splitFacade.onSendAckMessage = callback;
  }

  @override
  set onSendRelayMessage(
    Function(ProtocolMessage relayMessage, String nextHopId)? callback,
  ) {
    _handler.onSendRelayMessage = callback;
    _splitFacade.onSendRelayMessage = callback;
  }

  @override
  set onIdentityRevealed(Function(String contactName)? callback) {
    _handler.onIdentityRevealed = callback;
    _splitFacade.onIdentityRevealed = callback;
  }

  @override
  void dispose() {
    _splitFacade.dispose();
    _handler.dispose();
    _logger.info('♻️ BLEMessageHandlerFacadeImpl disposed');
  }

  BLEStateManager _inferLegacyStateManager() {
    if (_stateManager is BLEStateManagerFacade) {
      return (_stateManager as BLEStateManagerFacade).legacyStateManager;
    }
    if (_stateManager is BLEStateManager) {
      return _stateManager as BLEStateManager;
    }
    throw StateError(
      'Legacy BLEStateManager not available for send operations',
    );
  }

  Future<bool> _sendCentralViaAdapter({
    required String recipientKey,
    required String content,
    required Duration timeout,
    String? messageId,
    String? originalIntendedRecipient,
  }) async {
    try {
      if (_connectionManager == null ||
          _getCentralManager == null ||
          _connectionManager!.connectedDevice == null) {
        _logger.warning(
          '⚠️ sendMessage skipped - missing BLE connection context',
        );
        return false;
      }

      final characteristic =
          _connectionManager!.messageCharacteristic ??
          _getMessageCharacteristic?.call();
      if (characteristic == null) {
        _logger.warning(
          '⚠️ sendMessage skipped - missing message characteristic',
        );
        return false;
      }

      final mtuSize = _connectionManager!.mtuSize ?? 20;

      return await _writeAdapter.sendCentralMessage(
        centralManager: _getCentralManager!(),
        connectedDevice: _connectionManager!.connectedDevice!,
        messageCharacteristic: characteristic,
        recipientKey: recipientKey,
        content: content,
        mtuSize: mtuSize,
        messageId: messageId,
        originalIntendedRecipient: originalIntendedRecipient,
      );
    } catch (e) {
      _logger.warning('⚠️ sendMessage failed via facade: $e');
      return false;
    }
  }

  Future<bool> _sendPeripheralViaAdapter({
    required String senderKey,
    required String content,
    String? messageId,
  }) async {
    try {
      if (_getPeripheralManager == null ||
          _stateManager == null ||
          !_stateManager!.isPeripheralMode) {
        _logger.warning(
          '⚠️ Peripheral send skipped - not in peripheral mode or missing managers',
        );
        return false;
      }

      final connectedCentral = _getConnectedCentral?.call();
      final messageCharacteristic = _getPeripheralMessageCharacteristic?.call();

      if (connectedCentral == null || messageCharacteristic == null) {
        _logger.warning(
          '⚠️ Peripheral send skipped - no central or characteristic',
        );
        return false;
      }

      if ((_getPeripheralMtuReady?.call() ?? false) == false &&
          _getPeripheralNegotiatedMtu?.call() == null) {
        for (int i = 0; i < 40; i++) {
          await Future.delayed(Duration(milliseconds: 50));
          if ((_getPeripheralMtuReady?.call() ?? false) ||
              _getPeripheralNegotiatedMtu?.call() != null) {
            break;
          }
        }
      }

      final mtuSize = _getPeripheralNegotiatedMtu?.call() ?? 20;
      final isPaired = _stateManager!.isPaired;
      final idType = _stateManager!.getIdType();

      final truncatedId = senderKey.length > 16
          ? senderKey.substring(0, 16)
          : senderKey;
      _logger.fine(
        '📤 Peripheral sending via adapter using $idType ID: $truncatedId...',
      );

      return await _writeAdapter.sendPeripheralMessage(
        peripheralManager: _getPeripheralManager!(),
        connectedCentral: connectedCentral,
        messageCharacteristic: messageCharacteristic,
        senderKey: senderKey,
        content: content,
        mtuSize: mtuSize,
        messageId: messageId,
      );
    } catch (e) {
      _logger.warning('⚠️ sendPeripheralMessage failed via facade: $e');
      return false;
    }
  }
}
