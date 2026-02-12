import 'dart:typed_data';
import 'package:logging/logging.dart';
import 'package:pak_connect/domain/interfaces/i_ble_message_handler_facade.dart';
import 'package:pak_connect/domain/interfaces/i_security_service.dart';
import 'package:pak_connect/domain/interfaces/i_seen_message_store.dart';
import '../../domain/models/protocol_message.dart';
import 'package:pak_connect/domain/models/mesh_relay_models.dart';
import 'package:pak_connect/domain/constants/binary_payload_types.dart';
import '../../domain/messaging/offline_message_queue_contract.dart';
import 'package:pak_connect/domain/messaging/queue_sync_manager.dart';
import 'package:pak_connect/domain/services/spam_prevention_manager.dart';
import '../../domain/models/protocol_message.dart' as domain_models;
import 'message_fragmentation_handler.dart';
import 'package:pak_connect/domain/interfaces/i_message_fragmentation_handler.dart';
import 'protocol_message_handler.dart';
import 'relay_coordinator.dart';
import '../../domain/values/id_types.dart';
import 'package:pak_connect/domain/services/security_service_locator.dart';
import '../../data/repositories/contact_repository.dart';
import 'package:pak_connect/domain/interfaces/i_ble_handshake_service.dart';

/// Public API facade for BLE message handling
///
/// Provides 100% backward compatibility with BLEMessageHandler while delegating to:
/// - MessageFragmentationHandler (fragment reassembly)
/// - ProtocolMessageHandler (protocol message parsing)
/// - RelayCoordinator (mesh relay decisions)
///
/// All consumers of BLEMessageHandler should use this interface
class BLEMessageHandlerFacade implements IBLEMessageHandlerFacade {
  static IBLEHandshakeService? Function()? _handshakeServiceResolver;
  static ISeenMessageStore? Function()? _seenMessageStoreResolver;

  static void configureDependencyResolvers({
    IBLEHandshakeService? Function()? handshakeServiceResolver,
    ISeenMessageStore? Function()? seenMessageStoreResolver,
  }) {
    if (handshakeServiceResolver != null) {
      _handshakeServiceResolver = handshakeServiceResolver;
    }
    if (seenMessageStoreResolver != null) {
      _seenMessageStoreResolver = seenMessageStoreResolver;
    }
  }

  static void clearDependencyResolvers() {
    _handshakeServiceResolver = null;
    _seenMessageStoreResolver = null;
  }

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
  OfflineMessageQueueContract? _messageQueue;
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
  final ISecurityService _securityService;

  BLEMessageHandlerFacade({
    bool enableCleanupTimer = false,
    ISecurityService? securityService,
  }) : _enableCleanupTimer = enableCleanupTimer,
       _securityService =
           securityService ?? SecurityServiceLocator.resolveService();

  /// Initializes the facade (lazy - called on first access)
  void _ensureInitialized() {
    if (_initialized) return;

    _fragmentationHandler = MessageFragmentationHandler(
      enableCleanupTimer: _enableCleanupTimer,
    );
    _protocolHandler = ProtocolMessageHandler(
      securityService: _securityService,
    );
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
    final resolver = _handshakeServiceResolver;
    if (resolver != null) {
      try {
        _handshakeService = resolver();
      } catch (_) {
        // Ignore resolver issues; will remain null.
      }
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

    // Auto-inject SeenMessageStore from composition resolver for duplicate detection.
    final seenResolver = _seenMessageStoreResolver;
    if (seenResolver != null) {
      try {
        final seenMessageStore = seenResolver();
        if (seenMessageStore != null) {
          setSeenMessageStore(seenMessageStore);
          _logger.fine(
            '✅ SeenMessageStore auto-injected via resolver for duplicate detection',
          );
        }
      } catch (e) {
        _logger.warning('⚠️ SeenMessageStore resolver failed: $e');
      }
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
  void setMessageQueue(OfflineMessageQueueContract queue) {
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
            transportMessageId:
                protocolMessage.textMessageId ??
                protocolMessage.queueSyncMessage?.queueHash,
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
            transportMessageId: messageId,
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
                transportMessageId: msgId,
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
            String? decryptKeyUsed = await _resolveBinarySenderKey(fromNodeId);
            if ((decryptKeyUsed == null || decryptKeyUsed.isEmpty) &&
                fromNodeId.isNotEmpty) {
              decryptKeyUsed = fromNodeId;
            }

            if (decryptKeyUsed != null && decryptKeyUsed.isNotEmpty) {
              try {
                decrypted = await _securityService.decryptBinaryPayload(
                  payload.bytes,
                  decryptKeyUsed,
                  _contactRepository,
                );
              } catch (e) {
                final canFallbackToTransportSender =
                    fromNodeId.isNotEmpty && fromNodeId != decryptKeyUsed;
                if (canFallbackToTransportSender) {
                  try {
                    decrypted = await _securityService.decryptBinaryPayload(
                      payload.bytes,
                      fromNodeId,
                      _contactRepository,
                    );
                    decryptKeyUsed = fromNodeId;
                    _logger.fine(
                      '🔒 Binary decrypt fallback succeeded using transport sender',
                    );
                  } catch (fallbackError) {
                    _logger.warning(
                      '⚠️ Binary payload decrypt failed for resolved sender ($decryptKeyUsed) '
                      'and transport sender ($fromNodeId): $fallbackError',
                    );
                    decrypted = payload.bytes;
                  }
                } else {
                  _logger.warning(
                    '⚠️ Binary payload decrypt failed for $decryptKeyUsed: $e',
                  );
                  decrypted = payload.bytes;
                }
              }
            } else if (fromNodeId.isNotEmpty) {
              _logger.fine(
                'ℹ️ Binary payload decrypt skipped: sender key could not be resolved from transport node id',
              );
            } else {
              _logger.fine(
                'ℹ️ Binary payload decrypt skipped: missing sender identity',
              );
            }

            if (decrypted == payload.bytes) {
              _logger.fine(
                'ℹ️ Binary payload delivered without successful decrypt; downstream handlers may retry/inspect metadata',
              );
            }

            _onBinaryPayloadReceived!(
              decrypted,
              payload.originalType!,
              msgId,
              payload.ttl ?? 0,
              payload.recipient,
              decryptKeyUsed,
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

  Future<String?> _resolveBinarySenderKey(String? candidateKey) async {
    if (candidateKey == null || candidateKey.isEmpty) {
      return candidateKey;
    }
    try {
      final contact = await _contactRepository.getContactByAnyId(candidateKey);
      if (contact != null) {
        final sessionId = contact.currentEphemeralId;
        final persistentKey = contact.persistentPublicKey;
        if (persistentKey != null &&
            persistentKey.isNotEmpty &&
            sessionId != null &&
            sessionId.isNotEmpty) {
          _securityService.registerIdentityMapping(
            persistentPublicKey: persistentKey,
            ephemeralID: sessionId,
          );
        }
        if (sessionId != null && sessionId.isNotEmpty) {
          return sessionId;
        }
        if (persistentKey != null && persistentKey.isNotEmpty) {
          return persistentKey;
        }
        return contact.publicKey;
      }
    } catch (e) {
      _logger.fine('Binary sender resolution failed for $candidateKey: $e');
    }
    return candidateKey;
  }

  /// Retrieves reassembled message bytes produced during fragment processing.
  Uint8List? takeReassembledMessageBytes(String messageId) {
    _ensureInitialized();
    return _fragmentationHandler.takeReassembledPayload(messageId)?.bytes;
  }

  /// Retrieve fully reassembled binary payload for forwarding (MTU adaptation).
  @override
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
  set onSendAckMessage(
    Function(domain_models.ProtocolMessage message)? callback,
  ) {
    _ensureInitialized();
    if (callback != null) {
      _relayCoordinator.onSendAckMessage((message) => callback(message));
      _protocolHandler.onSendAckMessage((message) => callback(message));
    }
  }

  @override
  set onSendRelayMessage(
    Function(domain_models.ProtocolMessage relayMessage, String nextHopId)?
    callback,
  ) {
    _ensureInitialized();
    if (callback != null) {
      _relayCoordinator.onSendRelayMessage(
        (relayMessage, nextHopId) => callback(relayMessage, nextHopId),
      );
    }
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
    _ensureInitialized();
    if (callback != null) {
      _protocolHandler.onTextMessageReceived(callback);
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
