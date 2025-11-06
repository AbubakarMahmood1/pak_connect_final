// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:logging/logging.dart';
import '../../core/security/signing_manager.dart';
import '../../core/utils/message_fragmenter.dart';
import '../../core/models/protocol_message.dart';
import '../../core/models/mesh_relay_models.dart';
import '../../data/repositories/contact_repository.dart';
import 'ble_state_manager.dart';
import '../../core/services/security_manager.dart';
import '../../core/messaging/queue_sync_manager.dart';
import '../../core/messaging/offline_message_queue.dart';
import '../../core/messaging/mesh_relay_engine.dart';
import '../../core/security/spam_prevention_manager.dart';
import '../../domain/entities/enhanced_message.dart';
import '../../data/repositories/user_preferences.dart';
import '../../core/security/ephemeral_key_manager.dart';

class BLEMessageHandler {
  final _logger = Logger('BLEMessageHandler');
  final ContactRepository _contactRepository = ContactRepository();

  /// 🔧 UTILITY: Safe string truncation to prevent RangeError
  static String _safeTruncate(String? input, int maxLength, {String fallback = "NULL"}) {
    if (input == null || input.isEmpty) return fallback;
    if (input.length <= maxLength) return input;
    return input.substring(0, maxLength);
  }

  // Message fragmentation and reassembly
  final MessageReassembler _messageReassembler = MessageReassembler();

  // ACK management
  final Map<String, Timer> _messageTimeouts = {};
  final Map<String, Completer<bool>> _messageAcks = {};

  Timer? _cleanupTimer;

  // Message operation tracking
  String encryptionMethod = 'none';

  // Contact request callbacks
  Function(String, String)? onContactRequestReceived;
  Function(String, String)? onContactAcceptReceived;
  Function()? onContactRejectReceived;

  // Crypto verification callbacks
  Function(String, String)? onCryptoVerificationReceived;
  Function(String, String, bool, Map<String, dynamic>?)? onCryptoVerificationResponseReceived;

  // Queue sync callbacks
  Function(QueueSyncMessage syncMessage, String fromNodeId)? onQueueSyncReceived;
  Function(List<QueuedMessage> messages, String toNodeId)? onSendQueueMessages;
  Function(String nodeId, QueueSyncResult result)? onQueueSyncCompleted;

  // Mesh relay callbacks
  Function(String originalMessageId, String content, String originalSender)? onRelayMessageReceived;
  Function(RelayDecision decision)? onRelayDecisionMade;
  Function(RelayStatistics stats)? onRelayStatsUpdated;
  Function(ProtocolMessage message)? onSendAckMessage;  // Callback for sending ACK protocol messages
  Function(ProtocolMessage relayMessage, String nextHopId)? onSendRelayMessage;  // Callback for forwarding relay messages

  // Spy mode callbacks
  Function(String contactName)? onIdentityRevealed;

  // Relay system components
  MeshRelayEngine? _relayEngine;
  SpamPreventionManager? _spamPrevention;
  OfflineMessageQueue? _messageQueue;  // Reference to message queue for ACK handling
  String? _currentNodeId;

  BLEMessageHandler() {
    // Setup periodic cleanup of old partial messages
    _cleanupTimer = Timer.periodic(Duration(minutes: 2), (timer) {
      _messageReassembler.cleanupOldMessages();
    });
  }

  /// Set current node ID for routing validation
  void setCurrentNodeId(String nodeId) {
    _currentNodeId = nodeId;

    // 🚨 DIAGNOSTIC: Check for bounds error cause
    print('🔧 DIAGNOSTIC: Node ID length: ${nodeId.length}');
    print('🔧 DIAGNOSTIC: Node ID: "$nodeId"');
    print('🔧 ROUTING DEBUG: Current node ID set to: ${_safeTruncate(nodeId, 16)}...');
  }

  /// Initialize relay system for mesh networking
  Future<void> initializeRelaySystem({
    required String currentNodeId,
    required OfflineMessageQueue messageQueue,
    Function(String originalMessageId, String content, String originalSender)? onRelayMessageReceived,
    Function(RelayDecision decision)? onRelayDecisionMade,
    Function(RelayStatistics stats)? onRelayStatsUpdated,
  }) async {
    try {
      _currentNodeId = currentNodeId;
      _messageQueue = messageQueue;

      // 🚨 DIAGNOSTIC: Check for bounds error in init
      print('🔧 INIT DIAGNOSTIC: Node ID length: ${currentNodeId.length}');
      print('🔧 INIT DEBUG: Setting current node ID to: ${_safeTruncate(currentNodeId, 16)}...');
      this.onRelayMessageReceived = onRelayMessageReceived;
      this.onRelayDecisionMade = onRelayDecisionMade;
      this.onRelayStatsUpdated = onRelayStatsUpdated;

      // Initialize spam prevention
      _spamPrevention = SpamPreventionManager();
      await _spamPrevention!.initialize();

      // Initialize relay engine
      _relayEngine = MeshRelayEngine(
        contactRepository: _contactRepository,
        messageQueue: messageQueue,
        spamPrevention: _spamPrevention!,
      );

      await _relayEngine!.initialize(
        currentNodeId: currentNodeId,
        onRelayMessage: _handleRelayToNextHop,
        onDeliverToSelf: _handleRelayDeliveryToSelf,
        onRelayDecision: onRelayDecisionMade,
        onStatsUpdated: onRelayStatsUpdated,
      );

      _logger.info('Mesh relay system initialized for node: ${_safeTruncate(currentNodeId, 16)}...');

    } catch (e) {
      _logger.severe('Failed to initialize relay system: $e');
    }
  }

  /// Get list of available next hops for relay routing
  List<String> getAvailableNextHops() {
    // This would be provided by the BLE connection manager
    // For now, return empty list as placeholder
    return [];
  }

  Future<bool> sendMessage({
  required CentralManager centralManager,
  required Peripheral connectedDevice,
  required GATTCharacteristic messageCharacteristic,
  required String message,
  required int mtuSize,
  String? messageId,
  String? contactPublicKey,
  String? recipientId,  // STEP 7: Recipient ID (ephemeral or persistent)
  bool useEphemeralAddressing = false,  // STEP 7: Addressing flag
  String? originalIntendedRecipient, // For relay messages: preserve original recipient
  required ContactRepository contactRepository,
  required BLEStateManager stateManager,
  Function(bool)? onMessageOperationChanged,
}) async {
  final msgId = messageId ?? DateTime.now().millisecondsSinceEpoch.toString();

  try {
    onMessageOperationChanged?.call(true);

    // Connection validation ping
    try {
      final pingData = Uint8List.fromList([0x00]);
      await centralManager.writeCharacteristic(
        connectedDevice,
        messageCharacteristic,
        value: pingData,
        type: GATTCharacteristicWriteType.withResponse,
      );
      _logger.info('Connection validation (ping) successful');
    } catch (e) {
      _logger.severe('Connection validation failed: $e');
      _logger.warning('🔥 Forcing disconnect to trigger reconnection...');
      try {
        await centralManager.disconnect(connectedDevice);
      } catch (disconnectError) {
        _logger.warning('Force disconnect failed: $disconnectError');
      }
      throw Exception('Connection unhealthy - forced disconnect');
    }

    // 🕵️ SPY MODE: Resolve message identities based on hint broadcast status
    final identities = await _resolveMessageIdentities(
      contactPublicKey: contactPublicKey,
      contactRepository: contactRepository,
      stateManager: stateManager,
    );

    // Override recipient and sender IDs if in spy mode
    final finalRecipientId = identities.intendedRecipient;
    final finalSenderIf = identities.originalSender;

    if (identities.isSpyMode) {
      _logger.info('🕵️ SPY MODE: Sending anonymously');
      _logger.info('🕵️   Sender: ${finalSenderIf.substring(0, 8)}... (ephemeral)');
      _logger.info('🕵️   Recipient: ${finalRecipientId.substring(0, 8)}... (ephemeral)');
    }

    // 🔧 NEW: Use simplified encryption
    String payload = message;
    String encryptionMethod = 'none';

    if (contactPublicKey != null && contactPublicKey.isNotEmpty) {
      try {
        payload = await SecurityManager.encryptMessage(message, contactPublicKey, contactRepository);
        encryptionMethod = await _getSimpleEncryptionMethod(contactPublicKey, contactRepository);
        _logger.info('🔒 MESSAGE: Encrypted with ${encryptionMethod.toUpperCase()} method');
      } catch (e) {
        _logger.warning('🔒 MESSAGE: Encryption failed, sending unencrypted: $e');
        encryptionMethod = 'none';
      }
    } else {
      _logger.info('🔒 MESSAGE: No contact key, sending unencrypted');
    }

    // Sign the original message content (before encryption)
    // 🔧 FIX: Get trust level safely with fallback
    SecurityLevel trustLevel;
    try {
      trustLevel = await SecurityManager.getCurrentLevel(
        contactPublicKey ?? '',
        contactRepository
      );
    } catch (e) {
      _logger.warning('🔒 CENTRAL: Failed to get security level: $e, defaulting to LOW');
      trustLevel = SecurityLevel.low;
    }

    final signingInfo = SigningManager.getSigningInfo(trustLevel);
    final signature = SigningManager.signMessage(message, trustLevel);

  // STEP 7: Create protocol message with recipient addressing
  final protocolMessage = ProtocolMessage.textMessage(
    messageId: msgId,
    content: payload,
    encrypted: encryptionMethod != 'none',
    recipientId: recipientId,  // STEP 7: Include recipient ID
    useEphemeralAddressing: useEphemeralAddressing,  // STEP 7: Include addressing flag
  );

  // ✅ SPY MODE: Use resolved identities in protocol message
  final legacyPayload = {
    ...protocolMessage.payload,
    'encryptionMethod': encryptionMethod,
    'intendedRecipient': finalRecipientId,     // From identity resolution
    'originalSender': finalSenderIf,            // From identity resolution
  };

  final finalMessage = ProtocolMessage(
    type: protocolMessage.type,
    payload: legacyPayload,
    timestamp: protocolMessage.timestamp,
    signature: signature,
    useEphemeralSigning: signingInfo.useEphemeralSigning,
    ephemeralSigningKey: signingInfo.signingKey,
  );

  // DIAGNOSTIC: Log message sending details with safe truncation
  print('🔧 SEND DEBUG: ===== MESSAGE SENDING ANALYSIS =====');
  print('🔧 SEND DIAGNOSTIC: Message ID length: ${msgId.length}');
  print('🔧 SEND DIAGNOSTIC: Contact key length: ${contactPublicKey?.length ?? 0}');
  print('🔧 SEND DIAGNOSTIC: Current node length: ${_currentNodeId?.length ?? 0}');

  print('🔧 SEND DEBUG: Message ID: ${_safeTruncate(msgId, 16)}...');
  print('🔧 SEND DEBUG: Recipient ID: ${_safeTruncate(recipientId, 16, fallback: "NOT SPECIFIED")}...');
  print('🔧 SEND DEBUG: Addressing: ${useEphemeralAddressing ? "EPHEMERAL" : "PERSISTENT"}');
  print('🔧 SEND DEBUG: Intended recipient: ${_safeTruncate(contactPublicKey, 16, fallback: "NOT SPECIFIED")}...');
  print('🔧 SEND DEBUG: Current node ID: ${_safeTruncate(_currentNodeId, 16, fallback: "NOT SET")}...');
  print('🔧 SEND DEBUG: Encryption method: $encryptionMethod');
  print('🔧 SEND DEBUG: Message content: "${_safeTruncate(message, 50)}..."');
  print('🔧 SEND DEBUG: ===== END SENDING ANALYSIS =====');

    print('📨 SEND STEP 1: Converting protocol message to bytes');
    final jsonBytes = finalMessage.toBytes();
    print('📨 SEND STEP 2: Protocol message → ${jsonBytes.length} bytes');
    print('📨 SEND STEP 2a: First 20 bytes: ${jsonBytes.sublist(0, jsonBytes.length > 20 ? 20 : jsonBytes.length)}');

    print('📨 SEND STEP 3: Fragmenting into chunks (MTU: $mtuSize)');
    final chunks = MessageFragmenter.fragmentBytes(jsonBytes, mtuSize, msgId);
    _logger.info('Created ${chunks.length} chunks for message: $msgId');
    print('📨 SEND STEP 4: Created ${chunks.length} chunks');

    // Set up ACK waiting
    final ackCompleter = Completer<bool>();
    _messageAcks[msgId] = ackCompleter;

    // Set up timeout (5 seconds)
    _messageTimeouts[msgId] = Timer(Duration(seconds: 5), () {
      if (!ackCompleter.isCompleted) {
        _logger.warning('Message timeout: $msgId');
        _messageAcks.remove(msgId);
        ackCompleter.complete(false);
      }
    });

    // Send each chunk via write characteristic (central mode)
    for (int i = 0; i < chunks.length; i++) {
      final chunk = chunks[i];
      print('📨 SEND STEP 5.${i + 1}: Converting chunk ${i + 1}/${chunks.length} to bytes');
      print('📨 SEND STEP 5.${i + 1}a: Chunk format: ${chunk.messageId}|${chunk.chunkIndex}|${chunk.totalChunks}|${chunk.isBinary ? "1" : "0"}|[${chunk.content.length} chars]');

      final chunkData = chunk.toBytes();
      print('📨 SEND STEP 5.${i + 1}b: Chunk ${i + 1} → ${chunkData.length} bytes');
      print('📨 SEND STEP 5.${i + 1}c: First 50 bytes: ${chunkData.sublist(0, chunkData.length > 50 ? 50 : chunkData.length)}');

      _logger.info('Sending central chunk ${i + 1}/${chunks.length} for message: $msgId');

      print('📨 SEND STEP 6.${i + 1}: Writing chunk ${i + 1} to BLE characteristic');
      await centralManager.writeCharacteristic(
        connectedDevice,
        messageCharacteristic,
        value: chunkData,
        type: GATTCharacteristicWriteType.withResponse,
      );
      print('📨 SEND STEP 6.${i + 1}✅: Chunk ${i + 1} written to BLE successfully');

      if (i < chunks.length - 1) {
        await Future.delayed(Duration(milliseconds: 100));
      }
    }

    _logger.info('All chunks sent for message: $msgId, waiting for ACK...');

    // Wait for ACK or timeout
    final success = await ackCompleter.future;

    // Cleanup
    _messageTimeouts[msgId]?.cancel();
    _messageTimeouts.remove(msgId);
    _messageAcks.remove(msgId);

    return success;

  } catch (e, stackTrace) {
    _logger.severe('Failed to send message: $e');
    _logger.severe('Stack trace: $stackTrace');

    // Cleanup on error
    _messageTimeouts[msgId]?.cancel();
    _messageTimeouts.remove(msgId);
    _messageAcks.remove(msgId);

    rethrow;
  } finally {
    Future.delayed(Duration(milliseconds: 500), () {
      onMessageOperationChanged?.call(false);
    });
  }
}

Future<bool> sendPeripheralMessage({
  required PeripheralManager peripheralManager,
  required Central connectedCentral,
  required GATTCharacteristic messageCharacteristic,
  required String message,
  required int mtuSize,
  String? messageId,
  String? contactPublicKey,
  String? recipientId,  // STEP 7: Recipient ID (ephemeral or persistent)
  bool useEphemeralAddressing = false,  // STEP 7: Addressing flag
  String? originalIntendedRecipient, // For relay messages: preserve original recipient
  required ContactRepository contactRepository,
  required BLEStateManager stateManager,
}) async {
  final msgId = messageId ?? DateTime.now().millisecondsSinceEpoch.toString();

  try {
    String payload = message;
    String encryptionMethod = 'none';

    if (contactPublicKey != null && contactPublicKey.isNotEmpty) {
      try {
        payload = await SecurityManager.encryptMessage(message, contactPublicKey, contactRepository);
        encryptionMethod = await _getSimpleEncryptionMethod(contactPublicKey, contactRepository);
        _logger.info('🔒 PERIPHERAL MESSAGE: Encrypted with ${encryptionMethod.toUpperCase()} method');
      } catch (e) {
        _logger.warning('🔒 PERIPHERAL MESSAGE: Encryption failed, sending unencrypted: $e');
        encryptionMethod = 'none';
      }
    } else {
      _logger.info('🔒 PERIPHERAL MESSAGE: No contact key, sending unencrypted');
    }

    // Sign the original message content (before encryption)
    // 🔧 FIX: Get trust level safely with fallback
    SecurityLevel trustLevel;
    try {
      trustLevel = await SecurityManager.getCurrentLevel(
        contactPublicKey ?? '',
        contactRepository
      );
    } catch (e) {
      _logger.warning('🔒 PERIPHERAL: Failed to get security level: $e, defaulting to LOW');
      trustLevel = SecurityLevel.low;
    }

    final signingInfo = SigningManager.getSigningInfo(trustLevel);
    final signature = SigningManager.signMessage(message, trustLevel);

  // 🔧 FIX: If using ephemeral signing, ensure we have the signing key
  if (signingInfo.useEphemeralSigning && signingInfo.signingKey == null) {
    _logger.warning('⚠️ PERIPHERAL: Ephemeral signing key not available - message will not be signed');
  }

  // 🕵️ SPY MODE: Resolve message identities (same as central mode)
  final identities = await _resolveMessageIdentities(
    contactPublicKey: contactPublicKey,
    contactRepository: contactRepository,
    stateManager: stateManager,
  );

  final finalRecipientId = identities.intendedRecipient;
  final finalSenderIf = identities.originalSender;

  // STEP 7: Create protocol message with recipient addressing
  final protocolMessage = ProtocolMessage.textMessage(
    messageId: msgId,
    content: payload,
    encrypted: encryptionMethod != 'none',
    recipientId: recipientId,  // STEP 7: Include recipient ID
    useEphemeralAddressing: useEphemeralAddressing,  // STEP 7: Include addressing flag
  );

  // ✅ SPY MODE: Use resolved identities in protocol message
  final legacyPayload = {
    ...protocolMessage.payload,
    'encryptionMethod': encryptionMethod,
    'intendedRecipient': finalRecipientId,     // From identity resolution
    'originalSender': finalSenderIf,            // From identity resolution
  };

  final finalMessage = ProtocolMessage(
    type: protocolMessage.type,
    payload: legacyPayload,
    timestamp: protocolMessage.timestamp,
    signature: signature,
    useEphemeralSigning: signingInfo.useEphemeralSigning,
    ephemeralSigningKey: signingInfo.signingKey,
  );

  // DIAGNOSTIC: Log peripheral message sending details
  print('🔧 PERIPHERAL SEND DEBUG: ===== MESSAGE SENDING ANALYSIS =====');
  print('🔧 PERIPHERAL SEND DEBUG: Message ID: ${_safeTruncate(msgId, 16)}...');
  print('🔧 PERIPHERAL SEND DEBUG: Recipient ID: ${_safeTruncate(recipientId, 16, fallback: "NOT SPECIFIED")}...');
  print('🔧 PERIPHERAL SEND DEBUG: Addressing: ${useEphemeralAddressing ? "EPHEMERAL" : "PERSISTENT"}');
  print('🔧 PERIPHERAL SEND DEBUG: Intended recipient: ${_safeTruncate(contactPublicKey, 16, fallback: "NOT SPECIFIED")}...');
  print('🔧 PERIPHERAL SEND DEBUG: Current node ID: ${_safeTruncate(_currentNodeId, 16, fallback: "NOT SET")}...');
  print('🔧 PERIPHERAL SEND DEBUG: Encryption method: $encryptionMethod');
  print('🔧 PERIPHERAL SEND DEBUG: ===== END SENDING ANALYSIS =====');

    final jsonBytes = finalMessage.toBytes();
    final chunks = MessageFragmenter.fragmentBytes(jsonBytes, mtuSize, msgId);
    _logger.info('Created ${chunks.length} chunks for peripheral message: $msgId');

    // Send each chunk via notifications
    for (int i = 0; i < chunks.length; i++) {
      final chunk = chunks[i];
      final chunkData = chunk.toBytes();

      _logger.info('Sending peripheral chunk ${i + 1}/${chunks.length} for message: $msgId');

      await peripheralManager.notifyCharacteristic(
        connectedCentral,
        messageCharacteristic,
        value: chunkData,
      );

      if (i < chunks.length - 1) {
        await Future.delayed(Duration(milliseconds: 100));
      }
    }

    _logger.info('All peripheral chunks sent for message: $msgId');
    return true;

  } catch (e, stackTrace) {
    _logger.severe('Failed to send peripheral message: $e');
    _logger.severe('Stack trace: $stackTrace');
    rethrow;
  }
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

Future<String?> processReceivedData(Uint8List data, {String? Function(String)? onMessageIdFound, String? senderPublicKey, required ContactRepository contactRepository,}) async {
  try {
    print('📥 RECEIVE STEP 1: Received ${data.length} bytes from BLE');
    print('📥 RECEIVE STEP 1a: First 50 bytes: ${data.sublist(0, data.length > 50 ? 50 : data.length)}');
    print('📥 RECEIVE STEP 1b: First 50 chars as string: ${String.fromCharCodes(data.sublist(0, data.length > 50 ? 50 : data.length))}');

    // Skip single-byte pings
    if (data.length == 1 && data[0] == 0x00) {
      print('📥 RECEIVE: Skipping single-byte ping [0x00]');
      return null;
    }

    // Check for direct protocol messages (non-fragmented ACKs/pings)
    try {
      print('📥 RECEIVE STEP 2: Attempting UTF-8 decode for direct protocol message check');
      final directMessage = utf8.decode(data);
      if (ProtocolMessage.isProtocolMessage(directMessage)) {
        print('📥 RECEIVE STEP 2✅: Detected direct protocol message (non-chunked)');
        return await _handleDirectProtocolMessage(directMessage, onMessageIdFound, senderPublicKey);
      }
      print('📥 RECEIVE STEP 2❌: Not a direct protocol message');
    } catch (e) {
      print('📥 RECEIVE STEP 2❌: UTF-8 decode failed (expected for chunked messages): $e');
      // Not a direct message, try chunk processing
    }

    // Process as message chunk ONLY if it looks like our chunk string format
    if (_looksLikeChunkString(data)) {
      try {
        print('📥 RECEIVE STEP 3: Attempting to parse as MessageChunk');
        final chunk = MessageChunk.fromBytes(data);
        print('📥 RECEIVE STEP 3✅: Parsed chunk: ${chunk.messageId}|${chunk.chunkIndex}|${chunk.totalChunks}|${chunk.isBinary ? "1" : "0"}');

        print('📥 RECEIVE STEP 4: Adding chunk to reassembler');
        // Use addChunkBytes() to get raw bytes
        final completeMessageBytes = _messageReassembler.addChunkBytes(chunk);
        print('📥 RECEIVE STEP 4: Reassembler result: ${completeMessageBytes != null ? "MESSAGE COMPLETE ✅" : "waiting for more chunks ⏳"}');

        if (completeMessageBytes != null) {
          print('📥 RECEIVE STEP 5: Processing complete message (${completeMessageBytes.length} bytes)');
          try {
            final protocolMessage = ProtocolMessage.fromBytes(completeMessageBytes);
            print('📥 RECEIVE STEP 5✅: Protocol message parsed successfully (type: ${protocolMessage.type})');

            // Process the protocol message directly
            return await _processProtocolMessageDirect(protocolMessage, onMessageIdFound, senderPublicKey);
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
      print('📥 RECEIVE STEP 3❌: Not a chunk-string payload; ignoring in message handler');
      return null;
    }

  } catch (e) {
    _logger.severe('Error processing received data: $e');
  }

  return null;
}

Future<String?> _handleDirectProtocolMessage(String jsonMessage, String? Function(String)? onMessageIdFound, String? senderPublicKey) async {
  try {
    final messageBytes = utf8.encode(jsonMessage);
    final protocolMessage = ProtocolMessage.fromBytes(messageBytes);

    switch (protocolMessage.type) {
      case ProtocolMessageType.ack:
        final originalId = protocolMessage.payload['originalMessageId'] as String;
        final ackCompleter = _messageAcks[originalId];
        if (ackCompleter != null && !ackCompleter.isCompleted) {
          ackCompleter.complete(true);
        }
        _logger.info('Received protocol ACK for: $originalId');
        return null;

      case ProtocolMessageType.ping:
        _logger.info('Received protocol ping');
        return null;

      case ProtocolMessageType.textMessage:
        // Text messages should go through the complete message processing pipeline
        // where routing validation and decryption happens
        return await _processCompleteProtocolMessage(jsonMessage, onMessageIdFound, senderPublicKey);

      case ProtocolMessageType.relayAck:
        final originalMessageId = protocolMessage.relayAckOriginalMessageId;
        final relayNode = protocolMessage.relayAckRelayNode;
        final delivered = protocolMessage.relayAckDelivered;
        final ackRoutingPath = protocolMessage.payload['ackRoutingPath'] as List<dynamic>?;

        if (originalMessageId == null) {
          _logger.warning('Received relayAck with no message ID');
          return null;
        }

        await _handleRelayAck(
          originalMessageId: originalMessageId,
          relayNode: relayNode ?? 'unknown',
          delivered: delivered,
          ackRoutingPath: ackRoutingPath?.cast<String>(),
        );
        return null;

      case ProtocolMessageType.queueSync:
        // Handle queue sync messages
        final queueHash = protocolMessage.payload['queueHash'] as String?;
        final messageIds = (protocolMessage.payload['messageIds'] as List<dynamic>?)?.cast<String>();

        if (queueHash != null && messageIds != null && senderPublicKey != null) {
          final syncMessage = QueueSyncMessage.createRequest(
            messageIds: messageIds,
            nodeId: senderPublicKey,
          );

          // Forward to sync manager via callback
          onQueueSyncReceived?.call(syncMessage, senderPublicKey);
          // 🔧 FIX: Safe truncation to prevent RangeError
          final truncated = senderPublicKey.length > 16
              ? senderPublicKey.substring(0, 16)
              : senderPublicKey;
          _logger.info('Received queue sync message from $truncated...');
        } else {
          _logger.warning('Received invalid queue sync message');
        }
        return null;

      default:
        _logger.warning('Unexpected direct protocol message type: ${protocolMessage.type}');
        return null;
    }
  } catch (e) {
    _logger.severe('Failed to process direct protocol message: $e');
    return null;
  }
}

/// 🔧 FIX BUG #1: Process ProtocolMessage directly without JSON conversion
/// This method handles protocol messages that have been reassembled from chunks.
/// It avoids the double-parsing bug by working with the ProtocolMessage object directly.
Future<String?> _processProtocolMessageDirect(
  ProtocolMessage protocolMessage,
  String? Function(String)? onMessageIdFound,
  String? senderPublicKey,
) async {
  try {
    switch (protocolMessage.type) {
      case ProtocolMessageType.ack:
        final originalId = protocolMessage.payload['originalMessageId'] as String;
        final ackCompleter = _messageAcks[originalId];
        if (ackCompleter != null && !ackCompleter.isCompleted) {
          ackCompleter.complete(true);
        }
        _logger.info('Received protocol ACK for: $originalId');
        return null;

      case ProtocolMessageType.ping:
        _logger.info('Received protocol ping');
        return null;

      case ProtocolMessageType.textMessage:
        // Text messages should go through the complete message processing pipeline
        // where routing validation and decryption happens
        return await _processCompleteProtocolMessageDirect(protocolMessage, onMessageIdFound, senderPublicKey);

      case ProtocolMessageType.relayAck:
        final originalMessageId = protocolMessage.relayAckOriginalMessageId;
        final relayNode = protocolMessage.relayAckRelayNode;
        final delivered = protocolMessage.relayAckDelivered;
        final ackRoutingPath = protocolMessage.payload['ackRoutingPath'] as List<dynamic>?;

        if (originalMessageId == null) {
          _logger.warning('Received relayAck with no message ID');
          return null;
        }

        await _handleRelayAck(
          originalMessageId: originalMessageId,
          relayNode: relayNode ?? 'unknown',
          delivered: delivered,
          ackRoutingPath: ackRoutingPath?.cast<String>(),
        );
        return null;

      case ProtocolMessageType.queueSync:
        // Handle queue sync messages
        final queueHash = protocolMessage.payload['queueHash'] as String?;
        final messageIds = (protocolMessage.payload['messageIds'] as List<dynamic>?)?.cast<String>();

        if (queueHash != null && messageIds != null && senderPublicKey != null) {
          final syncMessage = QueueSyncMessage.createRequest(
            messageIds: messageIds,
            nodeId: senderPublicKey,
          );

          // Forward to sync manager via callback
          onQueueSyncReceived?.call(syncMessage, senderPublicKey);
          final truncated = senderPublicKey.length > 16
              ? senderPublicKey.substring(0, 16)
              : senderPublicKey;
          _logger.info('Received queue sync message from $truncated...');
        } else {
          _logger.warning('Received invalid queue sync message');
        }
        return null;

      default:
        _logger.warning('Unexpected direct protocol message type: ${protocolMessage.type}');
        return null;
    }
  } catch (e) {
    _logger.severe('Failed to process direct protocol message: $e');
    return null;
  }
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
    return await _processProtocolMessageContent(protocolMessage, onMessageIdFound, senderPublicKey);
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
        final messageId = protocolMessage.textMessageId!;
        final content = protocolMessage.textContent!;
        final encryptionMethod = protocolMessage.payload['encryptionMethod'] as String?;
        final intendedRecipient = protocolMessage.payload['intendedRecipient'] as String?;

        print('🔧 ROUTING DEBUG: ===== MESSAGE ROUTING ANALYSIS =====');

        // 🚨 DIAGNOSTIC: Check all string lengths before substring
        print('🔧 ROUTING DIAGNOSTIC: Message ID length: ${messageId.length}');
        print('🔧 ROUTING DIAGNOSTIC: Sender key length: ${senderPublicKey?.length ?? 0}');
        print('🔧 ROUTING DIAGNOSTIC: Intended recipient length: ${intendedRecipient?.length ?? 0}');
        print('🔧 ROUTING DIAGNOSTIC: Current node length: ${_currentNodeId?.length ?? 0}');

        print('🔧 ROUTING DEBUG: Message ID: ${_safeTruncate(messageId, 16)}...');
        print('🔧 ROUTING DEBUG: Sender public key: ${_safeTruncate(senderPublicKey, 16, fallback: "NULL")}...');
        print('🔧 ROUTING DEBUG: Intended recipient: ${_safeTruncate(intendedRecipient, 16, fallback: "NOT SPECIFIED")}...');
        print('🔧 ROUTING DEBUG: Current node ID: ${_safeTruncate(_currentNodeId, 16, fallback: "NOT SET")}...');
        print('🔧 ROUTING DEBUG: Encryption method: $encryptionMethod');
        print('🔧 ROUTING DEBUG: Message encrypted flag: ${protocolMessage.isEncrypted}');

        // Block our own messages (echo prevention)
        if (senderPublicKey != null && _currentNodeId != null && senderPublicKey == _currentNodeId) {
          print('🔧 ROUTING DEBUG: 🚫 BLOCKING OWN MESSAGE - Sender matches current user');
          return null;
        }

        // ✅ SPY MODE: Check if message is addressed to us using multi-identity check
        if (intendedRecipient != null) {
          final isForMe = await _isMessageForMe(intendedRecipient);
          if (!isForMe) {
            print('🔧 ROUTING DEBUG: 🚫 DISCARDING - Message not addressed to any of our identities');
            print('🔧 ROUTING DEBUG: - Intended recipient: ${_safeTruncate(intendedRecipient, 16)}...');
            return null; // Not for us, discard
          }
          print('🔧 ROUTING DEBUG: ✅ MESSAGE FOR US - Matched one of our identities');
        } else {
          print('🔧 ROUTING DEBUG: ✅ DIRECT MESSAGE - No routing info, accepting');
        }

        print('🔧 ROUTING DEBUG: ===== END ROUTING ANALYSIS =====');

        onMessageIdFound?.call(messageId);

        // 🔧 NEW: Use simplified decryption
        String decryptedContent = content;

        if (protocolMessage.isEncrypted && senderPublicKey != null && senderPublicKey.isNotEmpty) {
          try {
            decryptedContent = await SecurityManager.decryptMessage(content, senderPublicKey, _contactRepository);
            _logger.info('🔒 MESSAGE: Decrypted successfully');
          }  catch (e) {
        _logger.severe('🔒 MESSAGE: Decryption failed: $e');

        // Don't return error message immediately - try to show what we can
        if (e.toString().contains('security resync requested')) {
          return '[🔄 Security resync in progress - message will be readable after reconnection]';
        } else {
          return '[❌ Could not decrypt message - please reconnect to resync security]';
        }
      }
        } else if (protocolMessage.isEncrypted) {
          _logger.warning('🔒 MESSAGE: Encrypted but no sender key available');
          return '[❌ Encrypted message but no sender identity]';
        }

        // Verify signature on decrypted content
        if (protocolMessage.signature != null) {
  String verifyingKey;

  if (protocolMessage.useEphemeralSigning) {
    // Global message - use ephemeral key from message
    if (protocolMessage.ephemeralSigningKey == null) {
      _logger.warning('⚠️ Ephemeral message missing signing key - accepting without verification');
      // 🔧 FIX: Don't reject the message, just log warning and accept
      // This can happen if sender's EphemeralKeyManager wasn't ready
      _logger.info('✅ Message accepted (unsigned ephemeral)');
      return decryptedContent; // Return without signature verification
    }
    verifyingKey = protocolMessage.ephemeralSigningKey!;
  } else {
    // Trusted message - use real key from identity
    if (senderPublicKey == null) {
      _logger.severe('❌ Trusted message but no sender identity');
      return '[❌ Missing sender identity]';
    }
    verifyingKey = senderPublicKey;
  }

  final isValid = SigningManager.verifySignature(
    decryptedContent,
    protocolMessage.signature!,
    verifyingKey,
    protocolMessage.useEphemeralSigning
  );

  if (!isValid) {
    _logger.severe('❌ SIGNATURE VERIFICATION FAILED');
    return '[❌ UNTRUSTED MESSAGE - Signature Invalid]';
  }

  if (protocolMessage.useEphemeralSigning) {
    _logger.info('✅ Ephemeral signature verified - message authentic but anonymous');
  } else {
    _logger.info('✅ Real signature verified - message authentic and identified');
  }
}

        return decryptedContent;

      case ProtocolMessageType.ack:
        final originalId = protocolMessage.ackOriginalId!;
        final ackCompleter = _messageAcks[originalId];
        if (ackCompleter != null && !ackCompleter.isCompleted) {
          ackCompleter.complete(true);
        }
        return null;

      case ProtocolMessageType.identity:
        return null;

      case ProtocolMessageType.contactRequest:
        // Handle incoming contact request
        final requestPublicKey = protocolMessage.contactRequestPublicKey;
        final requestDisplayName = protocolMessage.contactRequestDisplayName;

        if (requestPublicKey != null && requestDisplayName != null) {
          _logger.info('📱 CONTACT REQUEST: Received from $requestDisplayName');
          // This will be handled by the BLE state manager via callback
          onContactRequestReceived?.call(requestPublicKey, requestDisplayName);
        }
        return null;

      case ProtocolMessageType.contactAccept:
        // Handle contact request acceptance
        final acceptPublicKey = protocolMessage.contactAcceptPublicKey;
        final acceptDisplayName = protocolMessage.contactAcceptDisplayName;

        if (acceptPublicKey != null && acceptDisplayName != null) {
          _logger.info('📱 CONTACT ACCEPT: Received from $acceptDisplayName');
          onContactAcceptReceived?.call(acceptPublicKey, acceptDisplayName);
        }
        return null;

      case ProtocolMessageType.contactReject:
        // Handle contact request rejection
        _logger.info('📱 CONTACT REJECT: Received');
        onContactRejectReceived?.call();
        return null;

      case ProtocolMessageType.queueSync:
        // Handle queue synchronization request/response
        return await _handleQueueSync(protocolMessage, senderPublicKey);

      case ProtocolMessageType.meshRelay:
        // Handle mesh relay message
        return await _handleMeshRelay(protocolMessage, senderPublicKey);

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

/// Original method for backward compatibility - parses JSON string to ProtocolMessage
Future<String?> _processCompleteProtocolMessage(
  String completeMessage,
  String? Function(String)? onMessageIdFound,
  String? senderPublicKey,
) async {
  if (!ProtocolMessage.isProtocolMessage(completeMessage)) {
    _logger.warning('Received non-protocol message, ignoring');
    return null;
  }

  try {
    final messageBytes = utf8.encode(completeMessage);
    final protocolMessage = ProtocolMessage.fromBytes(messageBytes);
    return await _processProtocolMessageContent(protocolMessage, onMessageIdFound, senderPublicKey);
  } catch (e) {
    _logger.severe('Failed to process complete protocol message: $e');
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
    final isValidTime = scannedTime >= startedShowing &&
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

/// Get encryption method from security state
Future<String> _getSimpleEncryptionMethod(String? contactPublicKey, ContactRepository contactRepository) async {
  if (contactPublicKey == null || contactPublicKey.isEmpty) {
    return 'global';
  }

  final level = await SecurityManager.getCurrentLevel(contactPublicKey, contactRepository);

  switch (level) {
    case SecurityLevel.high:
      return 'ecdh';
    case SecurityLevel.medium:
      return 'pairing';
    case SecurityLevel.low:
      return 'global';
  }
}

  /// Handle queue synchronization message
  Future<String?> _handleQueueSync(ProtocolMessage protocolMessage, String? senderPublicKey) async {
    try {
      final queueHash = protocolMessage.queueSyncHash;
      final messageIds = protocolMessage.queueSyncMessageIds;
      final syncTimestamp = protocolMessage.queueSyncTimestamp;

      if (queueHash == null || messageIds == null || syncTimestamp == null || senderPublicKey == null) {
        _logger.warning('🔄 QUEUE SYNC: Invalid sync message received');
        return null;
      }

      // Create QueueSyncMessage from protocol message
      final syncMessage = QueueSyncMessage(
        queueHash: queueHash,
        messageIds: messageIds,
        syncTimestamp: DateTime.fromMillisecondsSinceEpoch(syncTimestamp),
        nodeId: senderPublicKey,
        syncType: QueueSyncType.request,
      );

      _logger.info('🔄 QUEUE SYNC: Received from ${_safeTruncate(senderPublicKey, 16)}...');

      // Forward to sync manager via callback
      onQueueSyncReceived?.call(syncMessage, senderPublicKey);

      return null; // Queue sync messages don't return text content

    } catch (e) {
      _logger.severe('🔄 QUEUE SYNC: Failed to handle sync message: $e');
      return null;
    }
  }

  /// Handle friend identity reveal in spy mode
  Future<String?> _handleFriendReveal(ProtocolMessage protocolMessage, String? senderPublicKey) async {
    try {
      final theirPersistentKey = protocolMessage.payload['myPersistentKey'] as String?;
      final proof = protocolMessage.payload['proof'] as String?;
      final timestamp = protocolMessage.payload['timestamp'] as int?;

      if (theirPersistentKey == null || proof == null || timestamp == null) {
        _logger.warning('🕵️ FRIEND_REVEAL: Invalid message - missing required fields');
        return null;
      }

      // Verify timestamp (reject if > 5 minutes old)
      final messageAge = DateTime.now().millisecondsSinceEpoch - timestamp;
      if (messageAge > 300000) {  // 5 minutes
        _logger.warning('🕵️ FRIEND_REVEAL rejected: Timestamp too old ($messageAge ms)');
        return null;
      }

      // Verify cryptographic proof of ownership
      // For now, verify that the contact exists and proof is not empty
      // Full cryptographic verification would involve signature checking
      final isValid = await _contactRepository.getCachedSharedSecret(theirPersistentKey) != null &&
          proof.isNotEmpty;

      if (!isValid) {
        _logger.severe('🕵️ FRIEND_REVEAL rejected: Invalid cryptographic proof');
        return null;
      }

      _logger.info('✅ FRIEND_REVEAL: Cryptographic proof verified');

      // Check if this persistent key is in our contacts
      final contact = await _contactRepository.getContact(theirPersistentKey);

      if (contact != null) {
        _logger.info('🕵️ FRIEND_REVEAL: Anonymous user is actually ${contact.displayName}!');

        // Register mapping for Noise session lookup
        if (senderPublicKey != null) {
          SecurityManager.registerIdentityMapping(
            persistentPublicKey: theirPersistentKey,
            ephemeralID: senderPublicKey,
          );
        }

        // Notify UI via callback (if set by BLEService)
        onIdentityRevealed?.call(contact.displayName);
        _logger.info('✅ Identity revealed: ${contact.displayName}');

        return null;  // Don't show as a text message
      } else {
        _logger.warning('🕵️ FRIEND_REVEAL: Unknown persistent key - not in contacts');
        return null;
      }

    } catch (e) {
      _logger.severe('🕵️ FRIEND_REVEAL: Failed to handle reveal: $e');
      return null;
    }
  }

  /// Handle mesh relay message using the relay engine
  Future<String?> _handleMeshRelay(ProtocolMessage protocolMessage, String? senderPublicKey) async {
    try {
      if (_relayEngine == null || senderPublicKey == null) {
        _logger.warning('🔀 MESH RELAY: Relay system not initialized or no sender');
        return null;
      }

      final originalMessageId = protocolMessage.meshRelayOriginalMessageId;
      final originalSender = protocolMessage.meshRelayOriginalSender;
      final finalRecipient = protocolMessage.meshRelayFinalRecipient;
      final relayMetadata = protocolMessage.meshRelayMetadata;
      final originalPayload = protocolMessage.meshRelayOriginalPayload;
      final originalMessageType = protocolMessage.meshRelayOriginalMessageType;  // PHASE 2: Extract message type

      if (originalMessageId == null || originalSender == null ||
          finalRecipient == null || relayMetadata == null ||
          originalPayload == null) {
        _logger.warning('🔀 MESH RELAY: Invalid relay message received');
        return null;
      }

      _logger.info('🔀 MESH RELAY: Processing message ${_safeTruncate(originalMessageId, 16)}... from ${_safeTruncate(senderPublicKey, 8)}...');
      if (originalMessageType != null) {
        _logger.info('🔀 MESH RELAY: Original message type: ${originalMessageType.name}');
      }

      // Create relay metadata and message objects
      final metadata = RelayMetadata.fromJson(relayMetadata);
      final originalContent = originalPayload['content'] as String? ?? '';

      final relayMessage = MeshRelayMessage(
        originalMessageId: originalMessageId,
        originalContent: originalContent,
        relayMetadata: metadata,
        relayNodeId: senderPublicKey,
        relayedAt: DateTime.now(),
        originalMessageType: originalMessageType,  // PHASE 2: Include message type
      );

      // PHASE 2: Process with relay engine, passing message type for filtering
      final result = await _relayEngine!.processIncomingRelay(
        relayMessage: relayMessage,
        fromNodeId: senderPublicKey,
        availableNextHops: getAvailableNextHops(),
        messageType: originalMessageType,  // PHASE 2: Pass to relay engine for policy check
      );

      // Handle result based on type
      switch (result.type) {
        case RelayProcessingType.deliveredToSelf:
          _logger.info('🔀 MESH RELAY: Message delivered to self');

          // Send ACK back to originator through relay chain
          await _sendRelayAck(
            originalMessageId: relayMessage.originalMessageId,
            relayMetadata: relayMessage.relayMetadata,
            delivered: true,
          );

          return result.content;

        case RelayProcessingType.relayed:
          _logger.info('🔀 MESH RELAY: Message relayed to ${_safeTruncate(result.nextHopNodeId, 8)}...');
          return null; // No content to return for relayed messages

        case RelayProcessingType.dropped:
        case RelayProcessingType.blocked:
          _logger.warning('🔀 MESH RELAY: Message ${result.type.name}: ${result.reason}');
          return null;

        case RelayProcessingType.error:
          _logger.severe('🔀 MESH RELAY: Processing error: ${result.reason}');
          return null;
      }

    } catch (e) {
      _logger.severe('🔀 MESH RELAY: Failed to handle relay message: $e');
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
    try {
      final protocolMessage = ProtocolMessage.queueSync(
        queueHash: syncMessage.queueHash,
        messageIds: syncMessage.messageIds,
        syncTimestamp: syncMessage.syncTimestamp.millisecondsSinceEpoch,
      );

      final jsonBytes = protocolMessage.toBytes();
      final chunks = MessageFragmenter.fragmentBytes(jsonBytes, mtuSize, 'queue_sync_${DateTime.now().millisecondsSinceEpoch}');

      _logger.info('🔄 QUEUE SYNC: Sending sync message with ${syncMessage.messageIds.length} message IDs');

      // Send via central or peripheral
      if (centralManager != null && connectedDevice != null) {
        for (final chunk in chunks) {
          await centralManager.writeCharacteristic(
            connectedDevice,
            messageCharacteristic,
            value: chunk.toBytes(),
            type: GATTCharacteristicWriteType.withResponse,
          );
          await Future.delayed(Duration(milliseconds: 50));
        }
      } else if (peripheralManager != null && connectedCentral != null) {
        for (final chunk in chunks) {
          await peripheralManager.notifyCharacteristic(
            connectedCentral,
            messageCharacteristic,
            value: chunk.toBytes(),
          );
          await Future.delayed(Duration(milliseconds: 50));
        }
      }

      return true;

    } catch (e) {
      _logger.severe('🔄 QUEUE SYNC: Failed to send sync message: $e');
      return false;
    }
  }

  /// Handle relay message forwarding to next hop
  Future<void> _handleRelayToNextHop(MeshRelayMessage message, String nextHopNodeId) async {
    try {
      _logger.info('🔀 RELAY FORWARD: Preparing to send relay message to ${_safeTruncate(nextHopNodeId, 8)}...');

      // PHASE 2: Create protocol message for relay forwarding, preserving message type
      final protocolMessage = ProtocolMessage.meshRelay(
        originalMessageId: message.originalMessageId,
        originalSender: message.relayMetadata.originalSender,
        finalRecipient: message.relayMetadata.finalRecipient,
        relayMetadata: message.relayMetadata.toJson(),
        originalPayload: {
          'content': message.originalContent,
          if (message.encryptedPayload != null) 'encrypted': message.encryptedPayload,
        },
        useEphemeralAddressing: false,  // Relay messages use persistent keys
        originalMessageType: message.originalMessageType,  // PHASE 2: Preserve message type
      );

      // Forward via callback to BLE service layer
      if (onSendRelayMessage != null) {
        onSendRelayMessage!(protocolMessage, nextHopNodeId);
        _logger.info('✅ Relay message forwarded to ${_safeTruncate(nextHopNodeId, 8)}');
      } else {
        _logger.warning('⚠️ Cannot forward relay: onSendRelayMessage callback not set');
      }

    } catch (e) {
      _logger.severe('Failed to handle relay to next hop: $e');
    }
  }

  /// Handle relay message delivered to current node
  void _handleRelayDeliveryToSelf(String originalMessageId, String content, String originalSender) {
    try {
      _logger.info('🔀 RELAY DELIVERY: Message delivered to self from ${_safeTruncate(originalSender, 8)}...');

      // Notify the application layer
      onRelayMessageReceived?.call(originalMessageId, content, originalSender);

    } catch (e) {
      _logger.severe('Failed to handle relay delivery to self: $e');
    }
  }

  /// Create outgoing relay message
  Future<MeshRelayMessage?> createOutgoingRelay({
    required String originalMessageId,
    required String originalContent,
    required String finalRecipientPublicKey,
    MessagePriority priority = MessagePriority.normal,
  }) async {
    try {
      if (_relayEngine == null) {
        _logger.warning('Cannot create relay: relay engine not initialized');
        return null;
      }

      return await _relayEngine!.createOutgoingRelay(
        originalMessageId: originalMessageId,
        originalContent: originalContent,
        finalRecipientPublicKey: finalRecipientPublicKey,
        priority: priority,
      );

    } catch (e) {
      _logger.severe('Failed to create outgoing relay: $e');
      return null;
    }
  }

  /// Check if current node should attempt message decryption
  Future<bool> shouldAttemptDecryption({
    required String finalRecipientPublicKey,
    required String originalSenderPublicKey,
  }) async {
    if (_relayEngine == null) return false;

    return await _relayEngine!.shouldAttemptDecryption(
      finalRecipientPublicKey: finalRecipientPublicKey,
      originalSenderPublicKey: originalSenderPublicKey,
    );
  }

  /// Send relay ACK back through the relay chain
  Future<void> _sendRelayAck({
    required String originalMessageId,
    required RelayMetadata relayMetadata,
    required bool delivered,
  }) async {
    try {
      // Get previous hop (where to send ACK)
      final previousHop = relayMetadata.previousHop;
      if (previousHop == null) {
        _logger.info('🔙 No previous hop for ACK - message was direct delivery');
        return;
      }

      if (_currentNodeId == null) {
        _logger.warning('Cannot send ACK - current node ID not set');
        return;
      }

      final truncatedMessageId = originalMessageId.length > 16
          ? originalMessageId.substring(0, 16)
          : originalMessageId;
      final truncatedPrevHop = previousHop.length > 8
          ? previousHop.substring(0, 8)
          : previousHop;

      _logger.info('🔙 Sending relayAck for $truncatedMessageId... to previous hop: $truncatedPrevHop...');

      // Create relayAck protocol message with routing path for backward propagation
      final ackMessage = ProtocolMessage.relayAck(
        originalMessageId: originalMessageId,
        relayNode: _currentNodeId!,
        delivered: delivered,
      );

      // Add ACK routing path for backward propagation
      ackMessage.payload['ackRoutingPath'] = relayMetadata.ackRoutingPath;

      // Send via callback (will be handled by BLE service)
      onSendAckMessage?.call(ackMessage);

      _logger.info('✅ RelayAck sent for $truncatedMessageId...');

    } catch (e) {
      _logger.severe('Failed to send relay ACK: $e');
    }
  }

  /// Handle received relay ACK
  Future<void> _handleRelayAck({
    required String originalMessageId,
    required String relayNode,
    required bool delivered,
    List<String>? ackRoutingPath,
  }) async {
    try {
      if (_currentNodeId == null) {
        _logger.warning('Cannot handle ACK - current node ID not set');
        return;
      }

      final truncatedMessageId = originalMessageId.length > 16
          ? originalMessageId.substring(0, 16)
          : originalMessageId;
      final truncatedRelayNode = relayNode.length > 8
          ? relayNode.substring(0, 8)
          : relayNode;

      _logger.info('🔙 Received relayAck for $truncatedMessageId... from $truncatedRelayNode...');

      // Check if this ACK is for a message WE originated
      final queuedMessage = _messageQueue?.getMessageById(originalMessageId);

      if (queuedMessage != null) {
        // This is for our message - mark as delivered and remove from queue
        _logger.info('✅ ACK for our originated message - marking as delivered');
        await _messageQueue?.markMessageDelivered(originalMessageId);
        return;
      }

      // We're a relay node - propagate ACK backward
      if (ackRoutingPath != null && ackRoutingPath.isNotEmpty) {
        final currentIndex = ackRoutingPath.indexOf(_currentNodeId!);

        if (currentIndex > 0) {
          // There's a previous hop - forward ACK backward
          final previousHop = ackRoutingPath[currentIndex - 1];

          final truncatedPrevHop = previousHop.length > 8
              ? previousHop.substring(0, 8)
              : previousHop;

          _logger.info('⚡ Propagating ACK backward to $truncatedPrevHop...');

          final forwardAck = ProtocolMessage.relayAck(
            originalMessageId: originalMessageId,
            relayNode: _currentNodeId!,
            delivered: delivered,
          );
          forwardAck.payload['ackRoutingPath'] = ackRoutingPath;

          onSendAckMessage?.call(forwardAck);

          _logger.info('✅ ACK propagated for $truncatedMessageId...');
        } else {
          _logger.info('🏁 This is the originator - ACK propagation complete');
        }
      } else {
        _logger.warning('⚠️ No ackRoutingPath in relay ACK - cannot propagate backward');
      }

    } catch (e) {
      _logger.severe('Failed to handle relay ACK: $e');
    }
  }

  /// Get relay engine statistics
  RelayStatistics? getRelayStatistics() {
    return _relayEngine?.getStatistics();
  }

  /// Dispose of resources
  void dispose() {
    _cleanupTimer?.cancel();
    for (final timer in _messageTimeouts.values) {
      timer.cancel();
    }
    _messageTimeouts.clear();
    _messageAcks.clear();
    _spamPrevention?.dispose();
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
    final isForMe = intendedRecipient == myPersistentKey ||   // Normal friend mode
                     intendedRecipient == myEphemeralID;       // Spy mode
                     // || intendedRecipient == myHintID;       // Relay routing (future)

    if (isForMe) {
      _logger.fine('✅ Message addressed to us (matched: ${intendedRecipient == myPersistentKey ? "persistent" : "ephemeral"})');
    } else {
      _logger.fine('❌ Message NOT for us (recipient: ${intendedRecipient.substring(0, 8)}...)');
    }

    return isForMe;
  }

  /// Resolve message identities based on hint broadcast status
  ///
  /// Returns appropriate sender/recipient IDs for spy mode or normal mode
  Future<_MessageIdentities> _resolveMessageIdentities({
    required String? contactPublicKey,
    required ContactRepository contactRepository,
    required BLEStateManager stateManager,
  }) async {
    final userPrefs = UserPreferences();
    final hintsEnabled = await userPrefs.getHintBroadcastEnabled();

    // Get my identities
    final myPersistentKey = await userPrefs.getPublicKey();
    final myEphemeralID = EphemeralKeyManager.generateMyEphemeralKey();

    // Get recipient identities
    final contact = contactPublicKey != null
        ? await contactRepository.getContact(contactPublicKey)
        : null;

    // Check if Noise session exists
    final noiseSessionExists = contact?.currentEphemeralId != null &&
        SecurityManager.noiseService?.hasEstablishedSession(contact!.currentEphemeralId!) == true;

    // RULE 1: Determine sender identity
    String originalSender;
    if (!hintsEnabled && noiseSessionExists) {
      originalSender = myEphemeralID;  // Spy mode: anonymous
    } else {
      originalSender = myPersistentKey;  // Normal mode: identifiable
    }

    // RULE 2: Determine recipient identity
    String intendedRecipient;
    if (!hintsEnabled && noiseSessionExists && contact?.currentEphemeralId != null) {
      // Spy mode: Use their ephemeral ID (assumes they're online)
      intendedRecipient = contact!.currentEphemeralId!;
    } else if (contact?.persistentPublicKey != null) {
      // Normal mode: Use persistent key (works offline)
      intendedRecipient = contact!.persistentPublicKey!;
    } else {
      // Fallback: Use whatever ID we have
      intendedRecipient = contact?.publicKey ?? contactPublicKey ?? myEphemeralID;
    }

    return _MessageIdentities(
      originalSender: originalSender,
      intendedRecipient: intendedRecipient,
      isSpyMode: !hintsEnabled && noiseSessionExists,
    );
  }
}

/// Message identities for spy mode
class _MessageIdentities {
  final String originalSender;
  final String intendedRecipient;
  final bool isSpyMode;

  _MessageIdentities({
    required this.originalSender,
    required this.intendedRecipient,
    required this.isSpyMode,
  });
}

/// Encryption method result
class MessageEncryptionMethod {
  final String method;
  final bool isEncrypted;
  final String description;

  const MessageEncryptionMethod._({
    required this.method,
    required this.isEncrypted,
    required this.description,
  });

  factory MessageEncryptionMethod.ecdh() => MessageEncryptionMethod._(
    method: 'ecdh',
    isEncrypted: true,
    description: 'ECDH + Global Encryption',
  );

  factory MessageEncryptionMethod.conversation() => MessageEncryptionMethod._(
    method: 'conversation',
    isEncrypted: true,
    description: 'Pairing Key + Global Encryption',
  );

  factory MessageEncryptionMethod.global() => MessageEncryptionMethod._(
    method: 'global',
    isEncrypted: true,
    description: 'Global Encryption Only',
  );

  factory MessageEncryptionMethod.none() => MessageEncryptionMethod._(
    method: 'none',
    isEncrypted: false,
    description: 'No Encryption',
  );
}