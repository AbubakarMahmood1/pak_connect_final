import 'dart:io';
import 'dart:typed_data';
import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:logging/logging.dart';
import 'package:get_it/get_it.dart';
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
import '../../domain/values/id_types.dart';
import 'ble_message_handler.dart';
import 'ble_message_handler_facade.dart';
import 'ble_connection_manager.dart';
import 'ble_write_adapter.dart';
import '../../core/discovery/device_deduplication_manager.dart';
import '../../core/interfaces/i_message_fragmentation_handler.dart';

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
  OfflineMessageQueue? _messageQueueOverride;
  final BLEConnectionManager? _connectionManager;
  final IBLEStateManagerFacade? _stateManager;
  BleWriteAdapter? _writeAdapter;
  final CentralManager Function()? _getCentralManager;
  final PeripheralManager Function()? _getPeripheralManager;
  final Central? Function()? _getConnectedCentral;
  final GATTCharacteristic? Function()? _getMessageCharacteristic;
  final GATTCharacteristic? Function()? _getPeripheralMessageCharacteristic;
  final bool Function()? _getPeripheralMtuReady;
  final int? Function()? _getPeripheralNegotiatedMtu;
  final void Function(bool)? _onMessageOperationChanged;
  List<String> Function()? _nextHopsProviderOverride;
  String? _currentNodeId;

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
    // Default next-hop provider from BLE connections; falls back to handler.
    _splitFacade.setNextHopsProvider(_resolveNextHops);
    _handler.setNextHopsProvider(_resolveNextHops);
    try {
      if (AppCore.instance.isInitialized) {
        _splitFacade.setMessageQueue(AppCore.instance.messageQueue);
      }
    } catch (_) {}
    _writeAdapter = _buildWriteAdapterIfPossible();
    if (_writeAdapter == null) {
      _logger.warning(
        '⚠️ BLEStateManager not provided yet; write adapter will attach when available',
      );
    }
  }

  @override
  void setCurrentNodeId(String nodeId) {
    _currentNodeId = nodeId;
    _splitFacade.setCurrentNodeId(nodeId);
    _handler.setCurrentNodeId(nodeId);
    _ensureWriteAdapter()?.setCurrentNodeId(nodeId);
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

      final messageQueue = await _resolveMessageQueue();
      _splitFacade.setMessageQueue(messageQueue);

      await _splitFacade.initializeRelaySystem(
        currentNodeId: currentNodeId,
        onRelayMessageReceived: onRelayMessageReceived,
        onRelayDecisionMade: onRelayDecisionMade,
        onRelayStatsUpdated: onRelayStatsUpdated,
        nextHopsProvider: nextHopsProvider,
      );

      await _handler.initializeRelaySystem(
        currentNodeId: currentNodeId,
        messageQueue: messageQueue,
        onRelayMessageReceived: onRelayMessageReceived,
        onRelayDecisionMade: onRelayDecisionMade,
        onRelayStatsUpdated: onRelayStatsUpdated,
      );

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
    _messageQueueOverride = queue;
    _splitFacade.setMessageQueue(queue);
  }

  @override
  void setSpamPreventionManager(SpamPreventionManager manager) {
    _splitFacade.setSpamPreventionManager(manager);
  }

  @override
  void setNextHopsProvider(List<String> Function() provider) {
    _nextHopsProviderOverride = provider;
    _handler.setNextHopsProvider(provider);
    _splitFacade.setNextHopsProvider(provider);
  }

  List<String> _resolveNextHops() {
    if (_nextHopsProviderOverride != null) {
      try {
        return _nextHopsProviderOverride!.call();
      } catch (_) {}
    }
    final cm = _connectionManager;
    if (cm != null) {
      try {
        final addresses = cm.connectedAddresses;
        final peers = <String>[];
        for (final addr in addresses) {
          final dedup = DeviceDeduplicationManager.getDevice(addr);
          // Prefer known contact public key (likely persistent), else ephemeral hint, else MAC
          final hasHint =
              dedup?.ephemeralHint != null &&
              dedup!.ephemeralHint != DeviceDeduplicationManager.noHintValue;
          final peerId =
              dedup?.contactInfo?.publicKey ??
              (hasHint ? dedup.ephemeralHint : null);
          if (peerId != null) {
            peers.add(peerId);
          } else {
            // Fallback to MAC only if we truly have no identity; log for visibility.
            peers.add(addr);
            _logger.fine(
              '⚠️ Using MAC as next-hop identifier (no contact/hint mapping yet): ${addr.substring(0, addr.length > 8 ? 8 : addr.length)}...',
            );
          }
        }
        return peers;
      } catch (_) {}
    }
    // Fallback to handler’s view (may be empty)
    return _handler.getAvailableNextHops();
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

  @override
  ForwardReassembledPayload? takeForwardReassembledPayload(String fragmentId) {
    return _splitFacade.takeForwardReassembledPayload(fragmentId);
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
  set onBinaryPayloadReceived(
    Function(
      Uint8List data,
      int originalType,
      String fragmentId,
      int ttl,
      String? recipient,
      String? senderNodeId,
    )?
    callback,
  ) {
    _splitFacade.onBinaryPayloadReceived = callback;
  }

  @override
  set onForwardBinaryFragment(
    Function(
      Uint8List data,
      String fragmentId,
      int index,
      String fromDeviceId,
      String fromNodeId,
    )?
    callback,
  ) {
    _splitFacade.onForwardBinaryFragment = callback;
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
  set onRelayMessageReceivedIds(
    Function(
      MessageId originalMessageId,
      String content,
      String originalSender,
    )?
    callback,
  ) {
    _handler.onRelayMessageReceivedIds = callback;
    _splitFacade.onRelayMessageReceivedIds = callback;
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
  set onTextMessageReceived(
    Future<void> Function(
      String content,
      String? messageId,
      String? senderNodeId,
    )?
    callback,
  ) {
    _handler.onTextMessageReceived = callback;
    _splitFacade.onTextMessageReceived = callback;
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

  BleWriteAdapter? _buildWriteAdapterIfPossible() {
    final legacyStateManager = _resolveLegacyStateManager();
    if (legacyStateManager == null) {
      return null;
    }
    final adapter = BleWriteAdapter(
      contactRepository: _contactRepository,
      stateManagerProvider: () => legacyStateManager,
      onMessageOperationChanged: _onMessageOperationChanged,
      logger: Logger('BleWriteAdapter'),
    );
    if (_currentNodeId != null) {
      adapter.setCurrentNodeId(_currentNodeId!);
    }
    return adapter;
  }

  BleWriteAdapter? _ensureWriteAdapter() {
    _writeAdapter ??= _buildWriteAdapterIfPossible();
    return _writeAdapter;
  }

  BLEStateManager? _resolveLegacyStateManager() {
    if (_stateManager is BLEStateManagerFacade) {
      return _stateManager.legacyStateManager;
    }
    if (_stateManager is BLEStateManager) {
      return _stateManager as BLEStateManager;
    }
    try {
      final di = GetIt.instance;
      if (di.isRegistered<BLEStateManagerFacade>()) {
        return di<BLEStateManagerFacade>().legacyStateManager;
      }
      if (di.isRegistered<IBLEStateManagerFacade>()) {
        final facade = di<IBLEStateManagerFacade>();
        if (facade is BLEStateManagerFacade) {
          return facade.legacyStateManager;
        }
      }
      if (di.isRegistered<BLEStateManager>()) {
        return di<BLEStateManager>();
      }
    } catch (_) {}
    return null;
  }

  bool _isPeripheralMode(Object manager) {
    if (manager is IBLEStateManagerFacade) {
      return manager.isPeripheralMode;
    }
    if (manager is BLEStateManager) {
      return manager.isPeripheralMode;
    }
    return false;
  }

  String _getIdType(Object manager) {
    if (manager is IBLEStateManagerFacade) {
      return manager.getIdType();
    }
    if (manager is BLEStateManager) {
      return manager.getIdType();
    }
    return 'unknown';
  }

  Future<OfflineMessageQueue> _resolveMessageQueue() async {
    if (_messageQueueOverride != null) {
      return _messageQueueOverride!;
    }

    final core = AppCore.instance;
    if (core.isInitialized) {
      return core.messageQueue;
    }

    if (core.isInitializing) {
      _logger.fine('AppCore initialization in progress, using shared queue');
      return core.messageQueue;
    }

    _logger.warning('AppCore not initialized, initializing now...');
    await core.initialize();

    _logger.fine('📦 Using AppCore message queue');
    return core.messageQueue;
  }

  Future<bool> _sendCentralViaAdapter({
    required String recipientKey,
    required String content,
    required Duration timeout,
    String? messageId,
    String? originalIntendedRecipient,
  }) async {
    try {
      final adapter = _ensureWriteAdapter();
      if (adapter == null) {
        _logger.warning(
          '⚠️ sendMessage skipped - missing BLEStateManager / write adapter',
        );
        return false;
      }

      if (_connectionManager == null ||
          _getCentralManager == null ||
          _connectionManager.connectedDevice == null) {
        _logger.warning(
          '⚠️ sendMessage skipped - missing BLE connection context',
        );
        return false;
      }

      final characteristic =
          _connectionManager.messageCharacteristic ??
          _getMessageCharacteristic?.call();
      if (characteristic == null) {
        _logger.warning(
          '⚠️ sendMessage skipped - missing message characteristic',
        );
        return false;
      }

      final mtuSize = _connectionManager.mtuSize ?? 20;

      return await adapter.sendCentralMessage(
        centralManager: _getCentralManager(),
        connectedDevice: _connectionManager.connectedDevice!,
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
      final adapter = _ensureWriteAdapter();
      if (adapter == null) {
        _logger.warning(
          '⚠️ Peripheral send skipped - missing BLEStateManager / write adapter',
        );
        return false;
      }

      final stateManager = _stateManager ?? _resolveLegacyStateManager();

      if (_getPeripheralManager == null ||
          stateManager == null ||
          !_isPeripheralMode(stateManager)) {
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
      final idType = _getIdType(stateManager);

      final truncatedId = senderKey.length > 16
          ? senderKey.substring(0, 16)
          : senderKey;
      _logger.fine(
        '📤 Peripheral sending via adapter using $idType ID: $truncatedId...',
      );

      return await adapter.sendPeripheralMessage(
        peripheralManager: _getPeripheralManager(),
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
