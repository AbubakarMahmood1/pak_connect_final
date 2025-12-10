import 'dart:typed_data';
import 'package:logging/logging.dart';
import 'package:get_it/get_it.dart';
import '../../core/interfaces/i_ble_message_handler_facade.dart';
import '../../core/interfaces/i_seen_message_store.dart';
import '../../core/models/protocol_message.dart';
import '../../core/models/mesh_relay_models.dart';
import '../../core/constants/binary_payload_types.dart';
import '../../core/messaging/mesh_relay_engine.dart';
import '../../core/messaging/offline_message_queue.dart';
import '../../core/messaging/queue_sync_manager.dart';
import '../../core/security/spam_prevention_manager.dart';
import 'message_fragmentation_handler.dart';
import '../../core/interfaces/i_message_fragmentation_handler.dart';
import 'protocol_message_handler.dart';
import 'relay_coordinator.dart';
import '../../domain/values/id_types.dart';
import '../../core/services/security_manager.dart';
import '../../data/repositories/contact_repository.dart';
import '../../core/interfaces/i_ble_handshake_service.dart';

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
  final bool _enableCleanupTimer;

  // Lazy-initialized handlers
  late final MessageFragmentationHandler _fragmentationHandler;
  late final ProtocolMessageHandler _protocolHandler;
  late final RelayCoordinator _relayCoordinator;
  Future<bool> Function({
    required String recipientKey,
    required String content,
    required Duration timeout,
    String? messageId,
    String? originalIntendedRecipient,
  })?
  _sendCentralCallback;
  Future<bool> Function({
    required String senderKey,
    required String content,
    String? messageId,
  })?
  _sendPeripheralCallback;
  OfflineMessageQueue? _messageQueue;
  SpamPreventionManager? _spamPreventionManager;
  List<String> Function()? _nextHopsProvider;
  Function(
    Uint8List data,
    int originalType,
    String fragmentId,
    int ttl,
    String? recipient,
    String? senderNodeId,
  )?
  _onBinaryPayloadReceived;
  IBLEHandshakeService? _handshakeService;
  Function(
    Uint8List data,
    String fragmentId,
    int index,
    String fromDeviceId,
    String fromNodeId,
  )?
  _onForwardBinaryFragment;

  bool _initialized = false;
  final ContactRepository _contactRepository = ContactRepository();

  BLEMessageHandlerFacade({bool enableCleanupTimer = false})
    : _enableCleanupTimer = enableCleanupTimer;

  /// Initializes the facade (lazy - called on first access)
  void _ensureInitialized() {
    if (_initialized) return;

    _fragmentationHandler = MessageFragmentationHandler(
      enableCleanupTimer: _enableCleanupTimer,
    );
    _protocolHandler = ProtocolMessageHandler();
    _relayCoordinator = RelayCoordinator();
    if (_messageQueue != null) {
      _relayCoordinator.setMessageQueue(_messageQueue!);
    }
    if (_spamPreventionManager != null) {
      _relayCoordinator.setSpamPrevention(_spamPreventionManager!);
    }
    if (_nextHopsProvider != null) {
      _relayCoordinator.setNextHopsProvider(_nextHopsProvider!);
    }

    _initialized = true;
    _logger.info('✅ BLEMessageHandlerFacade initialized with 3 sub-handlers');
  }

  /// Lazy resolve handshake service from DI when first needed.
  IBLEHandshakeService? _resolveHandshakeService() {
    if (_handshakeService != null) return _handshakeService;
    try {
      if (GetIt.instance.isRegistered<IBLEHandshakeService>()) {
        _handshakeService = GetIt.instance<IBLEHandshakeService>();
      }
    } catch (_) {
      // Ignore DI lookup issues; will remain null.
    }
    return _handshakeService;
  }

  Future<bool> _routeHandshakeIfNeeded(
    ProtocolMessage protocolMessage,
    Uint8List rawBytes,
  ) async {
    if (!_isHandshakeMessage(protocolMessage.type)) return false;

    final hs = _resolveHandshakeService();
    if (hs == null) {
      _logger.fine(
        '🤝 Handshake message received but no handshake service registered',
      );
      return false;
    }

    try {
      final handled = await hs.handleIncomingHandshakeMessage(
        rawBytes,
        isFromPeripheral: false,
      );
      if (handled) {
        _logger.fine(
          '🤝 Handshake message routed to handshake service: ${protocolMessage.type}',
        );
      }
      return handled;
    } catch (e) {
      _logger.warning('⚠️ Failed to route handshake message: $e');
      return false;
    }
  }

  // ==================== PUBLIC API ====================

  /// Sets current node ID for this device in mesh routing
  @override
  void setCurrentNodeId(String nodeId) {
    _ensureInitialized();
    _protocolHandler.setCurrentNodeId(nodeId);
    _relayCoordinator.setCurrentNodeId(nodeId);
    _fragmentationHandler.setLocalNodeId(nodeId);
  }

  /// Configure sending callbacks supplied by the production adapter.
  void configureSenders({
    required Future<bool> Function({
      required String recipientKey,
      required String content,
      required Duration timeout,
      String? messageId,
      String? originalIntendedRecipient,
    })
    sendCentral,
    required Future<bool> Function({
      required String senderKey,
      required String content,
      String? messageId,
    })
    sendPeripheral,
  }) {
    _sendCentralCallback = sendCentral;
    _sendPeripheralCallback = sendPeripheral;
  }

  /// Initializes relay system with dependencies
  @override
  Future<void> initializeRelaySystem({
    required String currentNodeId,
    Function(String originalMessageId, String content, String originalSender)?
    onRelayMessageReceived,
    Function(RelayDecision decision)? onRelayDecisionMade,
    Function(RelayStatistics stats)? onRelayStatsUpdated,
    List<String> Function()? nextHopsProvider,
  }) async {
    _ensureInitialized();
    if (nextHopsProvider != null) {
      _relayCoordinator.setNextHopsProvider(nextHopsProvider);
    }
    await _relayCoordinator.initializeRelaySystem(currentNodeId: currentNodeId);
    if (onRelayMessageReceived != null) {
      _relayCoordinator.onRelayMessageReceived(onRelayMessageReceived);
    }
    if (onRelayDecisionMade != null) {
      _relayCoordinator.onRelayDecisionMade(onRelayDecisionMade);
    }
    if (onRelayStatsUpdated != null) {
      _relayCoordinator.onRelayStatsUpdated(onRelayStatsUpdated);
    }

    // Auto-inject SeenMessageStore from DI for duplicate detection
    // This ensures production code automatically gets the dependency
    try {
      if (GetIt.instance.isRegistered<ISeenMessageStore>()) {
        final seenMessageStore = GetIt.instance<ISeenMessageStore>();
        setSeenMessageStore(seenMessageStore);
        _logger.fine(
          '✅ SeenMessageStore auto-injected from DI for duplicate detection',
        );
      }
    } catch (e) {
      _logger.warning('⚠️ SeenMessageStore not available in DI: $e');
    }
  }

  /// Sets the SeenMessageStore for relay deduplication
  @override
  void setSeenMessageStore(ISeenMessageStore seenMessageStore) {
    _ensureInitialized();
    _relayCoordinator.setSeenMessageStore(seenMessageStore);
    _logger.fine('🔐 SeenMessageStore injected into RelayCoordinator');
  }

  @override
  void setMessageQueue(OfflineMessageQueue queue) {
    _messageQueue = queue;
    if (_initialized) {
      _relayCoordinator.setMessageQueue(queue);
    }
  }

  @override
  void setSpamPreventionManager(SpamPreventionManager manager) {
    _spamPreventionManager = manager;
    if (_initialized) {
      _relayCoordinator.setSpamPrevention(manager);
    }
  }

  @override
  void setNextHopsProvider(List<String> Function() provider) {
    _nextHopsProvider = provider;
    if (_initialized) {
      _relayCoordinator.setNextHopsProvider(provider);
    }
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
    _onBinaryPayloadReceived = callback;
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
    _onForwardBinaryFragment = callback;
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
    String? messageId,
    String? originalIntendedRecipient,
  }) async {
    _ensureInitialized();
    try {
      if (_sendCentralCallback == null) {
        _logger.warning(
          '⚠️ sendMessage skipped - no central sender configured in facade',
        );
        return false;
      }
      _logger.fine('📤 Sending message to: ${recipientKey.substring(0, 8)}...');
      return await _sendCentralCallback!(
        recipientKey: recipientKey,
        content: content,
        timeout: timeout,
        messageId: messageId,
        originalIntendedRecipient: originalIntendedRecipient,
      );
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
    String? messageId,
  }) async {
    _ensureInitialized();
    try {
      if (_sendPeripheralCallback == null) {
        _logger.warning(
          '⚠️ Peripheral send skipped - no peripheral sender configured in facade',
        );
        return false;
      }
      _logger.fine(
        '📤 Sending peripheral message from: ${senderKey.substring(0, 8)}...',
      );
      return await _sendPeripheralCallback!(
        senderKey: senderKey,
        content: content,
        messageId: messageId,
      );
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

          // Handshake messages should be routed to the handshake service.
          if (await _routeHandshakeIfNeeded(protocolMessage, data)) {
            return null;
          }

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
        final messageId = fragmentResult!.substring(
          'REASSEMBLY_COMPLETE:'.length,
        );
        final payload = _fragmentationHandler.takeReassembledPayload(messageId);

        if (payload == null) {
          _logger.warning(
            '⚠️ Reassembly marker present but bytes missing for $messageId',
          );
          return null;
        }

        try {
          final protocolMessage = ProtocolMessage.fromBytes(payload.bytes);

          if (await _routeHandshakeIfNeeded(protocolMessage, payload.bytes)) {
            return null;
          }

          // Mesh relay still routed through legacy handler (RelayCoordinator)
          if (protocolMessage.type == ProtocolMessageType.meshRelay) {
            _logger.fine('🔀 Mesh relay payload - hand off to coordinator');
            return null;
          }

          return await _protocolHandler.processProtocolMessage(
            message: protocolMessage,
            fromDeviceId: fromDeviceId,
            fromNodeId: fromNodeId,
          );
        } catch (e) {
          _logger.warning('Failed to parse reassembled protocol message: $e');
          return null;
        }
      }

      if (fragmentResult?.startsWith('REASSEMBLY_COMPLETE_BIN:') ?? false) {
        final parts = fragmentResult!.split(':');
        if (parts.length >= 3) {
          final msgId = parts[1];
          final payload = _fragmentationHandler.takeReassembledPayload(msgId);
          if (payload == null) {
            _logger.warning(
              '⚠️ Binary reassembly marker present but payload missing for $msgId',
            );
            return null;
          }
          _logger.fine(
            '📦 Binary reassembly complete (type=${payload.originalType ?? -1}, size=${payload.bytes.length})',
          );
          if (payload.originalType == BinaryPayloadType.protocolMessage) {
            try {
              final protocolMessage = ProtocolMessage.fromBytes(payload.bytes);

              if (await _routeHandshakeIfNeeded(
                protocolMessage,
                payload.bytes,
              )) {
                return null;
              }

              if (protocolMessage.type == ProtocolMessageType.meshRelay) {
                _logger.fine(
                  '🔀 Binary mesh relay payload - coordinator handles forwarding',
                );
                return null;
              }

              return await _protocolHandler.processProtocolMessage(
                message: protocolMessage,
                fromDeviceId: fromDeviceId,
                fromNodeId: fromNodeId,
              );
            } catch (e) {
              _logger.warning(
                'Failed to parse binary protocol message (${payload.originalType}): $e',
              );
              return null;
            }
          }

          if (_onBinaryPayloadReceived != null &&
              payload.originalType != null) {
            Uint8List decrypted = payload.bytes;
            if (fromNodeId.isNotEmpty) {
              try {
                decrypted = await SecurityManager.instance.decryptBinaryPayload(
                  payload.bytes,
                  fromNodeId,
                  _contactRepository,
                );
              } catch (e) {
                _logger.warning(
                  '⚠️ Binary payload decrypt failed from $fromNodeId: $e',
                );
                decrypted = payload.bytes;
              }
            }
            _onBinaryPayloadReceived!(
              decrypted,
              payload.originalType!,
              msgId,
              payload.ttl ?? 0,
              payload.recipient,
              fromNodeId.isNotEmpty ? fromNodeId : null,
            );
          }
          return null;
        }
      }

      if (fragmentResult?.startsWith('FORWARD_BIN:') ?? false) {
        final parts = fragmentResult!.split(':');
        if (parts.length >= 5) {
          final fragmentId = parts[1];
          final index = int.tryParse(parts[2]) ?? 0;
          final fromDeviceId = parts[3];
          final fromNodeId = parts[4];
          final forwardBytes = _fragmentationHandler.takeForwardFragment(
            fragmentId,
            index,
          );
          if (forwardBytes != null && _onForwardBinaryFragment != null) {
            _onForwardBinaryFragment!(
              forwardBytes,
              fragmentId,
              index,
              fromDeviceId,
              fromNodeId,
            );
          }
        }
        return null;
      }

      return fragmentResult;
    } catch (e) {
      _logger.severe('Error processing received data: $e');
      return null;
    }
  }

  /// Retrieves reassembled message bytes produced during fragment processing.
  Uint8List? takeReassembledMessageBytes(String messageId) {
    _ensureInitialized();
    return _fragmentationHandler.takeReassembledPayload(messageId)?.bytes;
  }

  /// Retrieve fully reassembled binary payload for forwarding (MTU adaptation).
  ForwardReassembledPayload? takeForwardReassembledPayload(String fragmentId) {
    _ensureInitialized();
    return _fragmentationHandler.takeForwardReassembledPayload(fragmentId);
  }

  bool _isHandshakeMessage(ProtocolMessageType type) {
    return type == ProtocolMessageType.connectionReady ||
        type == ProtocolMessageType.identity ||
        type == ProtocolMessageType.noiseHandshake1 ||
        type == ProtocolMessageType.noiseHandshake2 ||
        type == ProtocolMessageType.noiseHandshake3 ||
        type == ProtocolMessageType.noiseHandshakeRejected ||
        type == ProtocolMessageType.contactStatus;
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
  set onRelayMessageReceivedIds(
    Function(
      MessageId originalMessageId,
      String content,
      String originalSender,
    )?
    callback,
  ) {
    _ensureInitialized();
    if (callback != null) {
      _relayCoordinator.onRelayMessageReceivedIds(callback);
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
