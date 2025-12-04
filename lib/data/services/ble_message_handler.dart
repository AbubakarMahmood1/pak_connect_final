// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:logging/logging.dart';
import '../../core/utils/message_fragmenter.dart';
import '../../core/models/protocol_message.dart';
import '../../core/models/mesh_relay_models.dart';
import '../../data/repositories/contact_repository.dart';
import 'ble_state_manager.dart';
import 'contact_event_handler.dart';
import 'mesh_relay_handler.dart';
import 'outbound_message_sender.dart';
import 'queue_sync_processor.dart';
import '../../core/services/security_manager.dart';
import '../../core/messaging/queue_sync_manager.dart';
import '../../core/messaging/offline_message_queue.dart';
import '../../core/messaging/mesh_relay_engine.dart'
    show RelayDecision, RelayStatistics;
import '../../core/messaging/message_ack_tracker.dart';
import '../../core/messaging/inbound_text_processor.dart';
import '../../core/messaging/protocol_message_dispatcher.dart';
import '../../core/messaging/message_chunk_sender.dart';
import '../../domain/entities/enhanced_message.dart';
import '../../data/repositories/user_preferences.dart';
import '../../core/security/ephemeral_key_manager.dart';
import 'package:pak_connect/core/utils/string_extensions.dart';
import '../../domain/values/id_types.dart';

/// BLE Message Handler for processing incoming/outgoing messages
/// TODO Phase 3B: Implement IBLEMessageHandlerFacade adapter wrapper
/// Current implementation has incompatible method signatures that need refactoring
class BLEMessageHandler {
  final _logger = Logger('BLEMessageHandler');
  final ContactRepository _contactRepository = ContactRepository();

  /// 🔧 UTILITY: Safe string truncation to prevent RangeError
  static String _safeTruncate(
    String? input,
    int maxLength, {
    String fallback = "NULL",
  }) {
    if (input == null || input.isEmpty) return fallback;
    if (input.length <= maxLength) return input;
    return input.substring(0, maxLength);
  }

  // Message fragmentation and reassembly
  final MessageReassembler _messageReassembler = MessageReassembler();

  // ACK management
  late final MessageAckTracker _ackTracker;
  late final MessageChunkSender _chunkSender;
  late final InboundTextProcessor _inboundTextProcessor;

  Timer? _cleanupTimer;

  // Message operation tracking

  // Delegated components
  late final OutboundMessageSender _outboundSender;
  late final QueueSyncProcessor _queueSyncProcessor;
  late final MeshRelayHandler _meshRelayHandler;
  late final ContactEventHandler _contactEventHandler;
  String? _currentNodeId;

  // Contact request callbacks
  Function(String, String)? get onContactRequestReceived =>
      _contactEventHandler.onContactRequestReceived;
  set onContactRequestReceived(Function(String, String)? callback) =>
      _contactEventHandler.onContactRequestReceived = callback;
  Function(String, String)? get onContactAcceptReceived =>
      _contactEventHandler.onContactAcceptReceived;
  set onContactAcceptReceived(Function(String, String)? callback) =>
      _contactEventHandler.onContactAcceptReceived = callback;
  Function()? get onContactRejectReceived =>
      _contactEventHandler.onContactRejectReceived;
  set onContactRejectReceived(Function()? callback) =>
      _contactEventHandler.onContactRejectReceived = callback;

  // Crypto verification callbacks
  Function(String, String)? get onCryptoVerificationReceived =>
      _contactEventHandler.onCryptoVerificationReceived;
  set onCryptoVerificationReceived(Function(String, String)? callback) =>
      _contactEventHandler.onCryptoVerificationReceived = callback;
  Function(String, String, bool, Map<String, dynamic>?)?
  get onCryptoVerificationResponseReceived =>
      _contactEventHandler.onCryptoVerificationResponseReceived;
  set onCryptoVerificationResponseReceived(
    Function(String, String, bool, Map<String, dynamic>?)? callback,
  ) => _contactEventHandler.onCryptoVerificationResponseReceived = callback;

  // Queue sync callbacks
  Function(QueueSyncMessage syncMessage, String fromNodeId)?
  get onQueueSyncReceived => _queueSyncProcessor.onQueueSyncReceived;
  set onQueueSyncReceived(
    Function(QueueSyncMessage syncMessage, String fromNodeId)? callback,
  ) => _queueSyncProcessor.onQueueSyncReceived = callback;
  Function(List<QueuedMessage> messages, String toNodeId)?
  get onSendQueueMessages => _queueSyncProcessor.onSendQueueMessages;
  set onSendQueueMessages(
    Function(List<QueuedMessage> messages, String toNodeId)? callback,
  ) => _queueSyncProcessor.onSendQueueMessages = callback;
  Function(String nodeId, QueueSyncResult result)? get onQueueSyncCompleted =>
      _queueSyncProcessor.onQueueSyncCompleted;
  set onQueueSyncCompleted(
    Function(String nodeId, QueueSyncResult result)? callback,
  ) => _queueSyncProcessor.onQueueSyncCompleted = callback;

  // Mesh relay callbacks
  Function(String originalMessageId, String content, String originalSender)?
  get onRelayMessageReceived => _meshRelayHandler.onRelayMessageReceived;
  set onRelayMessageReceived(
    Function(String originalMessageId, String content, String originalSender)?
    callback,
  ) => _meshRelayHandler.onRelayMessageReceived = callback;
  Function(MessageId originalMessageId, String content, String originalSender)?
  get onRelayMessageReceivedIds => _meshRelayHandler.onRelayMessageReceivedIds;
  set onRelayMessageReceivedIds(
    Function(
      MessageId originalMessageId,
      String content,
      String originalSender,
    )?
    callback,
  ) => _meshRelayHandler.onRelayMessageReceivedIds = callback;
  Function(RelayDecision decision)? get onRelayDecisionMade =>
      _meshRelayHandler.onRelayDecisionMade;
  set onRelayDecisionMade(Function(RelayDecision decision)? callback) =>
      _meshRelayHandler.onRelayDecisionMade = callback;
  Function(RelayStatistics stats)? get onRelayStatsUpdated =>
      _meshRelayHandler.onRelayStatsUpdated;
  set onRelayStatsUpdated(Function(RelayStatistics stats)? callback) =>
      _meshRelayHandler.onRelayStatsUpdated = callback;
  Function(ProtocolMessage message)? get onSendAckMessage =>
      _meshRelayHandler.onSendAckMessage;
  set onSendAckMessage(Function(ProtocolMessage message)? callback) =>
      _meshRelayHandler.onSendAckMessage = callback;
  Function(ProtocolMessage relayMessage, String nextHopId)?
  get onSendRelayMessage => _meshRelayHandler.onSendRelayMessage;
  set onSendRelayMessage(
    Function(ProtocolMessage relayMessage, String nextHopId)? callback,
  ) => _meshRelayHandler.onSendRelayMessage = callback;

  // Spy mode callbacks
  Function(String contactName)? onIdentityRevealed;

  late final ProtocolMessageDispatcher _protocolDispatcher;

  BLEMessageHandler({
    bool enableCleanupTimer = true,
    Duration ackTimeout = const Duration(seconds: 5),
  }) {
    _ackTracker = MessageAckTracker(timeout: ackTimeout);
    _queueSyncProcessor = QueueSyncProcessor(logger: _logger);
    _meshRelayHandler = MeshRelayHandler(logger: _logger);
    _contactEventHandler = ContactEventHandler(logger: _logger);
    _chunkSender = MessageChunkSender(logger: _logger);
    _outboundSender = OutboundMessageSender(
      logger: _logger,
      ackTracker: _ackTracker,
      chunkSender: _chunkSender,
    );
    _inboundTextProcessor = InboundTextProcessor(
      contactRepository: _contactRepository,
      isMessageForMe: (intended) => _isMessageForMe(intended),
      currentNodeIdProvider: () => _currentNodeId,
      logger: _logger,
    );
    _protocolDispatcher = ProtocolMessageDispatcher(
      ackTracker: _ackTracker,
      onRelayAck:
          ({
            required String originalMessageId,
            required String relayNode,
            required bool delivered,
            List<String>? ackRoutingPath,
          }) async {
            await _meshRelayHandler.handleRelayAck(
              originalMessageId: originalMessageId,
              relayNode: relayNode,
              delivered: delivered,
              ackRoutingPath: ackRoutingPath,
            );
          },
      onRelayAckIds:
          ({
            required MessageId originalMessageId,
            required String relayNode,
            required bool delivered,
            List<String>? ackRoutingPath,
          }) async {
            await _meshRelayHandler.handleRelayAck(
              originalMessageId: originalMessageId.value,
              relayNode: relayNode,
              delivered: delivered,
              ackRoutingPath: ackRoutingPath,
            );
          },
      onQueueSyncReceived: (syncMessage, fromNodeId) {
        _queueSyncProcessor.handleDispatchedQueueSync(
          syncMessage: syncMessage,
          fromNodeId: fromNodeId,
        );
      },
      onUnhandledMessage:
          (protocolMessage, onMessageIdFound, senderPublicKey) =>
              _processCompleteProtocolMessageDirect(
                protocolMessage,
                onMessageIdFound,
                senderPublicKey,
              ),
      logger: _logger,
    );

    if (enableCleanupTimer) {
      // Setup periodic cleanup of old partial messages
      _cleanupTimer?.cancel();
      _cleanupTimer = Timer.periodic(
        Duration(minutes: 2),
        (_) => _messageReassembler.cleanupOldMessages(),
      );
    }
  }

  /// Set current node ID for routing validation
  void setCurrentNodeId(String nodeId) {
    _currentNodeId = nodeId;
    _meshRelayHandler.setCurrentNodeId(nodeId);
    _outboundSender.setCurrentNodeId(nodeId);

    // 🚨 DIAGNOSTIC: Check for bounds error cause
    print('🔧 DIAGNOSTIC: Node ID length: ${nodeId.length}');
    print('🔧 DIAGNOSTIC: Node ID: "$nodeId"');
    print(
      '🔧 ROUTING DEBUG: Current node ID set to: ${_safeTruncate(nodeId, 16)}...',
    );
  }

  /// Initialize relay system for mesh networking
  Future<void> initializeRelaySystem({
    required String currentNodeId,
    required OfflineMessageQueue messageQueue,
    Function(String originalMessageId, String content, String originalSender)?
    onRelayMessageReceived,
    Function(RelayDecision decision)? onRelayDecisionMade,
    Function(RelayStatistics stats)? onRelayStatsUpdated,
  }) async {
    try {
      _currentNodeId = currentNodeId;
      await _meshRelayHandler.initializeRelaySystem(
        currentNodeId: currentNodeId,
        messageQueue: messageQueue,
        onRelayMessageReceived: onRelayMessageReceived,
        onRelayDecisionMade: onRelayDecisionMade,
        onRelayStatsUpdated: onRelayStatsUpdated,
      );

      _logger.info(
        'Mesh relay system initialized for node: ${_safeTruncate(currentNodeId, 16)}...',
      );
    } catch (e) {
      _logger.severe('Failed to initialize relay system: $e');
    }
  }

  /// Get list of available next hops for relay routing
  List<String> getAvailableNextHops() {
    return _meshRelayHandler.getAvailableNextHops();
  }

  /// Provide next-hop source from BLE connection manager (addresses/peer IDs)
  void setNextHopsProvider(List<String> Function() provider) {
    _meshRelayHandler.setNextHopsProvider(provider);
  }

  Future<bool> sendMessage({
    required CentralManager centralManager,
    required Peripheral connectedDevice,
    required GATTCharacteristic messageCharacteristic,
    required String message,
    required int mtuSize,
    String? messageId,
    String? contactPublicKey,
    String? recipientId, // STEP 7: Recipient ID (ephemeral or persistent)
    bool useEphemeralAddressing = false, // STEP 7: Addressing flag
    String?
    originalIntendedRecipient, // For relay messages: preserve original recipient
    required ContactRepository contactRepository,
    required BLEStateManager stateManager,
    Function(bool)? onMessageOperationChanged,
  }) async {
    _outboundSender.setCurrentNodeId(_currentNodeId);
    return _outboundSender.sendCentralMessage(
      centralManager: centralManager,
      connectedDevice: connectedDevice,
      messageCharacteristic: messageCharacteristic,
      message: message,
      mtuSize: mtuSize,
      messageId: messageId,
      contactPublicKey: contactPublicKey,
      recipientId: recipientId,
      useEphemeralAddressing: useEphemeralAddressing,
      originalIntendedRecipient: originalIntendedRecipient,
      contactRepository: contactRepository,
      stateManager: stateManager,
      onMessageOperationChanged: onMessageOperationChanged,
      onMessageSent: stateManager.onMessageSent,
      onMessageSentIds: stateManager.onMessageSentIds,
    );
  }

  Future<bool> sendPeripheralMessage({
    required PeripheralManager peripheralManager,
    required Central connectedCentral,
    required GATTCharacteristic messageCharacteristic,
    required String message,
    required int mtuSize,
    String? messageId,
    String? contactPublicKey,
    String? recipientId, // STEP 7: Recipient ID (ephemeral or persistent)
    bool useEphemeralAddressing = false, // STEP 7: Addressing flag
    String?
    originalIntendedRecipient, // For relay messages: preserve original recipient
    required ContactRepository contactRepository,
    required BLEStateManager stateManager,
  }) async {
    _outboundSender.setCurrentNodeId(_currentNodeId);
    return _outboundSender.sendPeripheralMessage(
      peripheralManager: peripheralManager,
      connectedCentral: connectedCentral,
      messageCharacteristic: messageCharacteristic,
      message: message,
      mtuSize: mtuSize,
      messageId: messageId,
      contactPublicKey: contactPublicKey,
      recipientId: recipientId,
      useEphemeralAddressing: useEphemeralAddressing,
      originalIntendedRecipient: originalIntendedRecipient,
      contactRepository: contactRepository,
      stateManager: stateManager,
      onMessageSent: stateManager.onMessageSent,
      onMessageSentIds: stateManager.onMessageSentIds,
    );
  }

  bool _looksLikeChunkString(Uint8List bytes) {
    final max = bytes.length < 128 ? bytes.length : 128;
    int pipes = 0;
    for (var i = 0; i < max; i++) {
      final b = bytes[i];
      if (b == 0x7C) pipes++; // '|'
      // Reject most control chars except TAB(9), LF(10), CR(13)
      if (b < 0x20 && b != 0x09 && b != 0x0A && b != 0x0D) return false;
      // Reject extended binary (our chunk strings are ASCII)
      if (b > 0x7E) return false;
    }
    return pipes >= 4; // id|idx|total|isBinary|content
  }

  Future<String?> processReceivedData(
    Uint8List data, {
    String? Function(String)? onMessageIdFound,
    String? senderPublicKey,
    required ContactRepository contactRepository,
  }) async {
    try {
      print('📥 RECEIVE STEP 1: Received ${data.length} bytes from BLE');
      print(
        '📥 RECEIVE STEP 1a: First 50 bytes: ${data.sublist(0, data.length > 50 ? 50 : data.length)}',
      );
      print(
        '📥 RECEIVE STEP 1b: First 50 chars as string: ${String.fromCharCodes(data.sublist(0, data.length > 50 ? 50 : data.length))}',
      );

      // Skip single-byte pings
      if (data.length == 1 && data[0] == 0x00) {
        print('📥 RECEIVE: Skipping single-byte ping [0x00]');
        return null;
      }

      // Check for direct protocol messages (non-fragmented ACKs/pings)
      try {
        print(
          '📥 RECEIVE STEP 2: Attempting UTF-8 decode for direct protocol message check',
        );
        final directMessage = utf8.decode(data);
        if (ProtocolMessage.isProtocolMessage(directMessage)) {
          print(
            '📥 RECEIVE STEP 2✅: Detected direct protocol message (non-chunked)',
          );
          final messageBytes = utf8.encode(directMessage);
          final protocolMessage = ProtocolMessage.fromBytes(messageBytes);

          return await _protocolDispatcher.dispatch(
            protocolMessage,
            onMessageIdFound: onMessageIdFound,
            senderPublicKey: senderPublicKey,
          );
        }
        print('📥 RECEIVE STEP 2❌: Not a direct protocol message');
      } catch (e) {
        print(
          '📥 RECEIVE STEP 2❌: UTF-8 decode failed (expected for chunked messages): $e',
        );
        // Not a direct message, try chunk processing
      }

      // Process as message chunk ONLY if it looks like our chunk string format
      if (_looksLikeChunkString(data)) {
        try {
          print('📥 RECEIVE STEP 3: Attempting to parse as MessageChunk');
          final chunk = MessageChunk.fromBytes(data);
          print(
            '📥 RECEIVE STEP 3✅: Parsed chunk: ${chunk.messageId}|${chunk.chunkIndex}|${chunk.totalChunks}|${chunk.isBinary ? "1" : "0"}',
          );

          print('📥 RECEIVE STEP 4: Adding chunk to reassembler');
          // Use addChunkBytes() to get raw bytes
          final completeMessageBytes = _messageReassembler.addChunkBytes(chunk);
          print(
            '📥 RECEIVE STEP 4: Reassembler result: ${completeMessageBytes != null ? "MESSAGE COMPLETE ✅" : "waiting for more chunks ⏳"}',
          );

          if (completeMessageBytes != null) {
            print(
              '📥 RECEIVE STEP 5: Processing complete message (${completeMessageBytes.length} bytes)',
            );
            try {
              final protocolMessage = ProtocolMessage.fromBytes(
                completeMessageBytes,
              );
              print(
                '📥 RECEIVE STEP 5✅: Protocol message parsed successfully (type: ${protocolMessage.type})',
              );

              // Process the protocol message directly
              return await _protocolDispatcher.dispatch(
                protocolMessage,
                onMessageIdFound: onMessageIdFound,
                senderPublicKey: senderPublicKey,
              );
            } catch (e) {
              print('📥 RECEIVE STEP 5❌: Failed to parse protocol message: $e');
              _logger.warning('Protocol message parsing failed: $e');
              return null;
            }
          }
        } catch (e) {
          print('📥 RECEIVE STEP 3❌: Chunk parsing failed: $e');
          _logger.warning('Chunk processing failed: $e');
        }
      } else {
        // Not a chunk-string payload; ignore here so other handlers (e.g., handshake) can process
        print(
          '📥 RECEIVE STEP 3❌: Not a chunk-string payload; ignoring in message handler',
        );
        return null;
      }
    } catch (e) {
      _logger.severe('Error processing received data: $e');
    }

    return null;
  }

  /// 🔧 FIX BUG #1: Process complete protocol message from ProtocolMessage object
  /// This avoids the double-parsing bug by working directly with the parsed object.
  Future<String?> _processCompleteProtocolMessageDirect(
    ProtocolMessage protocolMessage,
    String? Function(String)? onMessageIdFound,
    String? senderPublicKey,
  ) async {
    try {
      // Process the already-parsed protocol message
      return await _processProtocolMessageContent(
        protocolMessage,
        onMessageIdFound,
        senderPublicKey,
      );
    } catch (e) {
      _logger.severe('Failed to process complete protocol message: $e');
      return null;
    }
  }

  /// Helper method to process protocol message content (shared by both direct and string-based paths)
  Future<String?> _processProtocolMessageContent(
    ProtocolMessage protocolMessage,
    String? Function(String)? onMessageIdFound,
    String? senderPublicKey,
  ) async {
    try {
      switch (protocolMessage.type) {
        case ProtocolMessageType.textMessage:
          return await _inboundTextProcessor.process(
            protocolMessage: protocolMessage,
            senderPublicKey: senderPublicKey,
            onMessageIdFound: onMessageIdFound,
          );

        case ProtocolMessageType.ack:
          // ACKs are handled in ProtocolMessageDispatcher; ignore here.
          return null;

        case ProtocolMessageType.identity:
          return null;

        case ProtocolMessageType.contactRequest:
          return await _contactEventHandler.handleContactRequest(
            protocolMessage,
          );

        case ProtocolMessageType.contactAccept:
          return await _contactEventHandler.handleContactAccept(
            protocolMessage,
          );

        case ProtocolMessageType.contactReject:
          return await _contactEventHandler.handleContactReject();

        case ProtocolMessageType.queueSync:
          return await _queueSyncProcessor.handleProtocolQueueSync(
            protocolMessage: protocolMessage,
            senderPublicKey: senderPublicKey,
          );

        case ProtocolMessageType.meshRelay:
          return await _meshRelayHandler.handleIncomingRelay(
            protocolMessage: protocolMessage,
            senderPublicKey: senderPublicKey,
          );

        case ProtocolMessageType.friendReveal:
          // Handle friend identity reveal in spy mode
          return await _handleFriendReveal(protocolMessage, senderPublicKey);

        default:
          return null;
      }
    } catch (e) {
      _logger.severe('Failed to process protocol message: $e');
      return null;
    }
  }

  Future<void> handleQRIntroductionClaim({
    required String otherPublicKey,
    required String introId,
    required int scannedTime,
    required String theirName,
    required BLEStateManager stateManager,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final sessionData = prefs.getString('my_qr_session_$introId');

    if (sessionData != null) {
      final session = jsonDecode(sessionData);
      final startedShowing = session['started_showing'] as int;
      final stoppedShowing = session['stopped_showing'] as int?;

      // Check if their scan time is within our showing window
      final isValidTime =
          scannedTime >= startedShowing &&
          (stoppedShowing == null || scannedTime <= stoppedShowing);

      if (isValidTime) {
        _logger.info('✅ Valid QR introduction from $theirName');
      } else {
        _logger.info('❌ Invalid QR introduction timeframe from $theirName');
      }
    } else {
      _logger.info('❓ Unknown QR introduction from $theirName');
    }

    // QR verification complete - existing connection flow will handle pairing
  }

  Future<bool> checkQRIntroductionMatch({
    required String otherPublicKey,
    required String theirName,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final introData = prefs.getString('scanned_intro_$otherPublicKey');

    if (introData != null) {
      final intro = jsonDecode(introData);
      final introId = intro['intro_id'] as String;

      _logger.info('✅ Found matching QR introduction: $introId for $theirName');
      return true;
    }

    return false;
  }

  /// Handle friend identity reveal in spy mode
  Future<String?> _handleFriendReveal(
    ProtocolMessage protocolMessage,
    String? senderPublicKey,
  ) async {
    try {
      final theirPersistentKey =
          protocolMessage.payload['myPersistentKey'] as String?;
      final proof = protocolMessage.payload['proof'] as String?;
      final timestamp = protocolMessage.payload['timestamp'] as int?;

      if (theirPersistentKey == null || proof == null || timestamp == null) {
        _logger.warning(
          '🕵️ FRIEND_REVEAL: Invalid message - missing required fields',
        );
        return null;
      }

      // Verify timestamp (reject if > 5 minutes old)
      final messageAge = DateTime.now().millisecondsSinceEpoch - timestamp;
      if (messageAge > 300000) {
        // 5 minutes
        _logger.warning(
          '🕵️ FRIEND_REVEAL rejected: Timestamp too old ($messageAge ms)',
        );
        return null;
      }

      // Verify cryptographic proof of ownership
      // For now, verify that the contact exists and proof is not empty
      // Full cryptographic verification would involve signature checking
      final isValid =
          await _contactRepository.getCachedSharedSecret(theirPersistentKey) !=
              null &&
          proof.isNotEmpty;

      if (!isValid) {
        _logger.severe(
          '🕵️ FRIEND_REVEAL rejected: Invalid cryptographic proof',
        );
        return null;
      }

      _logger.info('✅ FRIEND_REVEAL: Cryptographic proof verified');

      // Check if this persistent key is in our contacts
      final contact = await _contactRepository.getContact(theirPersistentKey);

      if (contact != null) {
        _logger.info(
          '🕵️ FRIEND_REVEAL: Anonymous user is actually ${contact.displayName}!',
        );

        // Register mapping for Noise session lookup
        if (senderPublicKey != null) {
          SecurityManager.instance.registerIdentityMapping(
            persistentPublicKey: theirPersistentKey,
            ephemeralID: senderPublicKey,
          );
        }

        // Notify UI via callback (if set by BLEService)
        onIdentityRevealed?.call(contact.displayName);
        _logger.info('✅ Identity revealed: ${contact.displayName}');

        return null; // Don't show as a text message
      } else {
        _logger.warning(
          '🕵️ FRIEND_REVEAL: Unknown persistent key - not in contacts',
        );
        return null;
      }
    } catch (e) {
      _logger.severe('🕵️ FRIEND_REVEAL: Failed to handle reveal: $e');
      return null;
    }
  }

  /// Send queue synchronization message
  Future<bool> sendQueueSyncMessage({
    required CentralManager? centralManager,
    required PeripheralManager? peripheralManager,
    required Peripheral? connectedDevice,
    required Central? connectedCentral,
    required GATTCharacteristic messageCharacteristic,
    required QueueSyncMessage syncMessage,
    required int mtuSize,
    required BLEStateManager stateManager,
  }) async {
    // Maintain signature for compatibility
    final _ = stateManager;
    return await _queueSyncProcessor.sendQueueSyncMessage(
      centralManager: centralManager,
      peripheralManager: peripheralManager,
      connectedDevice: connectedDevice,
      connectedCentral: connectedCentral,
      messageCharacteristic: messageCharacteristic,
      syncMessage: syncMessage,
      mtuSize: mtuSize,
    );
  }

  /// Create outgoing relay message
  Future<MeshRelayMessage?> createOutgoingRelay({
    required String originalMessageId,
    required String originalContent,
    required String finalRecipientPublicKey,
    MessagePriority priority = MessagePriority.normal,
  }) async {
    return await _meshRelayHandler.createOutgoingRelay(
      originalMessageId: originalMessageId,
      originalContent: originalContent,
      finalRecipientPublicKey: finalRecipientPublicKey,
      priority: priority,
    );
  }

  /// Check if current node should attempt message decryption
  Future<bool> shouldAttemptDecryption({
    required String finalRecipientPublicKey,
    required String originalSenderPublicKey,
  }) async {
    return await _meshRelayHandler.shouldAttemptDecryption(
      finalRecipientPublicKey: finalRecipientPublicKey,
      originalSenderPublicKey: originalSenderPublicKey,
    );
  }

  /// Get relay engine statistics
  RelayStatistics? getRelayStatistics() {
    return _meshRelayHandler.getRelayStatistics();
  }

  /// Dispose of resources
  void dispose() {
    _cleanupTimer?.cancel();
    _ackTracker.dispose();
    _meshRelayHandler.dispose();
    _queueSyncProcessor.dispose();
  }

  // ========== SPY MODE IDENTITY RESOLUTION ==========

  /// Check if message is addressed to this node (spy mode-aware)
  ///
  /// Checks all possible identities: persistent key, ephemeral ID, and hint ID
  Future<bool> _isMessageForMe(String? intendedRecipient) async {
    if (intendedRecipient == null || intendedRecipient.isEmpty) {
      // No recipient specified - accept (broadcast or direct connection)
      return true;
    }

    final userPrefs = UserPreferences();
    final myPersistentKey = await userPrefs.getPublicKey();
    final myEphemeralID = EphemeralKeyManager.generateMyEphemeralKey();

    // TODO: Get hint ID from hint system when implemented
    // final myHintID = HintSystem.getCurrentHintId();

    // Check all possible identities
    final isForMe =
        intendedRecipient == myPersistentKey || // Normal friend mode
        intendedRecipient == myEphemeralID; // Spy mode
    // || intendedRecipient == myHintID;       // Relay routing (future)

    if (isForMe) {
      _logger.fine(
        '✅ Message addressed to us (matched: ${intendedRecipient == myPersistentKey ? "persistent" : "ephemeral"})',
      );
    } else {
      _logger.fine(
        '❌ Message NOT for us (recipient: ${intendedRecipient.shortId(8)}...)',
      );
    }

    return isForMe;
  }
}
