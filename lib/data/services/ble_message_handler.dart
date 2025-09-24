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
  
  // Relay system components
  QueueSyncManager? _queueSyncManager;
  MeshRelayEngine? _relayEngine;
  SpamPreventionManager? _spamPrevention;
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
    final trustLevel = await SecurityManager.getCurrentLevel(
    contactPublicKey ?? '', contactRepository);
    final signingInfo = SigningManager.getSigningInfo(trustLevel);
    final signature = SigningManager.signMessage(message, trustLevel);

  final protocolMessage = ProtocolMessage(
    type: ProtocolMessageType.textMessage,
    payload: {
      'messageId': msgId,
      'content': payload,
      'encrypted': encryptionMethod != 'none',
      'encryptionMethod': encryptionMethod,
      'intendedRecipient': contactPublicKey, // Add recipient for routing
    },
    timestamp: DateTime.now(),
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
  print('🔧 SEND DEBUG: Intended recipient: ${_safeTruncate(contactPublicKey, 16, fallback: "NOT SPECIFIED")}...');
  print('🔧 SEND DEBUG: Current node ID: ${_safeTruncate(_currentNodeId, 16, fallback: "NOT SET")}...');
  print('🔧 SEND DEBUG: Encryption method: $encryptionMethod');
  print('🔧 SEND DEBUG: Message content: "${_safeTruncate(message, 50)}..."');
  print('🔧 SEND DEBUG: ===== END SENDING ANALYSIS =====');

    final jsonBytes = protocolMessage.toBytes();
    final chunks = MessageFragmenter.fragmentBytes(jsonBytes, mtuSize, msgId);
    _logger.info('Created ${chunks.length} chunks for message: $msgId');
    
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
      final chunkData = chunk.toBytes();
      
      _logger.info('Sending central chunk ${i + 1}/${chunks.length} for message: $msgId');
      
      await centralManager.writeCharacteristic(
        connectedDevice,
        messageCharacteristic,
        value: chunkData,
        type: GATTCharacteristicWriteType.withResponse,
      );
      
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
    
  } catch (e) {
    _logger.severe('Failed to send message: $e');
    
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
    final trustLevel = await SecurityManager.getCurrentLevel(
    contactPublicKey ?? '', contactRepository);
    final signingInfo = SigningManager.getSigningInfo(trustLevel);
    final signature = SigningManager.signMessage(message, trustLevel);

  final protocolMessage = ProtocolMessage(
    type: ProtocolMessageType.textMessage,
    payload: {
      'messageId': msgId,
      'content': payload,
      'encrypted': encryptionMethod != 'none',
      'encryptionMethod': encryptionMethod,
      'intendedRecipient': contactPublicKey, // Add recipient for routing
    },
    timestamp: DateTime.now(),
    signature: signature,
    useEphemeralSigning: signingInfo.useEphemeralSigning,
    ephemeralSigningKey: signingInfo.signingKey,
  );
  
  // DIAGNOSTIC: Log peripheral message sending details
  print('🔧 PERIPHERAL SEND DEBUG: ===== MESSAGE SENDING ANALYSIS =====');
  print('🔧 PERIPHERAL SEND DEBUG: Message ID: ${_safeTruncate(msgId, 16)}...');
  print('🔧 PERIPHERAL SEND DEBUG: Intended recipient: ${_safeTruncate(contactPublicKey, 16, fallback: "NOT SPECIFIED")}...');
  print('🔧 PERIPHERAL SEND DEBUG: Current node ID: ${_safeTruncate(_currentNodeId, 16, fallback: "NOT SET")}...');
  print('🔧 PERIPHERAL SEND DEBUG: Encryption method: $encryptionMethod');
  print('🔧 PERIPHERAL SEND DEBUG: ===== END SENDING ANALYSIS =====');

    final jsonBytes = protocolMessage.toBytes();
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
    
  } catch (e) {
    _logger.severe('Failed to send peripheral message: $e');
    rethrow;
  }
}

  
Future<String?> processReceivedData(Uint8List data, {String? Function(String)? onMessageIdFound, String? senderPublicKey, required ContactRepository contactRepository,}) async {
  try {
    // Skip single-byte pings
    if (data.length == 1 && data[0] == 0x00) {
      return null;
    }
    
    // Check for direct protocol messages (non-fragmented ACKs/pings)
    try {
      final directMessage = utf8.decode(data);
      if (ProtocolMessage.isProtocolMessage(directMessage)) {
        return await _handleDirectProtocolMessage(directMessage, onMessageIdFound, senderPublicKey);
      }
    } catch (e) {
      // Not a direct message, try chunk processing
    }
    
    // Process as message chunk
    try {
      final chunk = MessageChunk.fromBytes(data);
      final completeMessage = _messageReassembler.addChunk(chunk);
      
      if (completeMessage != null) {
        return await _processCompleteProtocolMessage(completeMessage, onMessageIdFound, senderPublicKey);
      }
      
    } catch (e) {
      _logger.warning('Chunk processing failed: $e');
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
        
      default:
        _logger.warning('Unexpected direct protocol message type: ${protocolMessage.type}');
        return null;
    }
  } catch (e) {
    _logger.severe('Failed to process direct protocol message: $e');
    return null;
  }
}

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
        
        // FIXED: Smart message routing validation for P2P vs Mesh messages
        if (intendedRecipient != null && _currentNodeId != null) {
          // Check if this is our own message coming back to us
          if (senderPublicKey != null && senderPublicKey == _currentNodeId) {
            print('🔧 ROUTING DEBUG: 🚫 BLOCKING OWN MESSAGE - Sender matches current user');
            print('🔧 ROUTING DEBUG: - This is our own message being incorrectly received');
            return null; // Block our own messages from appearing as incoming
          }
          
          // For direct P2P messages: intendedRecipient contains the recipient's public key
          // If we received the message directly, it's intended for us (we are the recipient)
          if (intendedRecipient == _currentNodeId) {
            // This is a mesh message explicitly addressed to our node ID
            print('🔧 ROUTING DEBUG: ✅ MESH MESSAGE - Explicitly addressed to our node ID');
          } else {
            // This is likely a direct P2P message where intendedRecipient is our public key
            // and _currentNodeId is our node ID (they can be different values)
            print('🔧 ROUTING DEBUG: ✅ P2P MESSAGE - Received directly, accepting as intended for us');
            print('🔧 ROUTING DEBUG: - Intended recipient: ${_safeTruncate(intendedRecipient, 16)}...');
            print('🔧 ROUTING DEBUG: - Our node ID: ${_safeTruncate(_currentNodeId, 16)}...');
            print('🔧 ROUTING DEBUG: - Direct P2P communication - processing normally');
          }
        } else if (intendedRecipient == null) {
          // For messages without explicit recipient routing info
          if (senderPublicKey != null && _currentNodeId != null && senderPublicKey == _currentNodeId) {
            print('🔧 ROUTING DEBUG: 🚫 BLOCKING OWN MESSAGE - Sender matches current user');
            print('🔧 ROUTING DEBUG: - This is our own message being incorrectly received');
            return null; // Block our own messages from appearing as incoming
          }
          
          print('🔧 ROUTING DEBUG: ✅ DIRECT MESSAGE - No routing info, processing as P2P message');
          print('🔧 ROUTING DEBUG: - senderPublicKey: ${_safeTruncate(senderPublicKey, 16, fallback: "null")}');
          print('🔧 ROUTING DEBUG: - _currentNodeId: ${_safeTruncate(_currentNodeId, 16, fallback: "null")}');
        } else {
          print('🔧 ROUTING DEBUG: ⚠️ PARTIAL ROUTING INFO - Processing with available data');
          print('🔧 ROUTING DEBUG: - intendedRecipient: ${_safeTruncate(intendedRecipient, 16, fallback: "null")}');
          print('🔧 ROUTING DEBUG: - _currentNodeId: ${_safeTruncate(_currentNodeId, 16, fallback: "null")}');
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
      _logger.severe('❌ Ephemeral message missing signing key');
      return '[❌ Invalid ephemeral message]';
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
      
      if (originalMessageId == null || originalSender == null ||
          finalRecipient == null || relayMetadata == null ||
          originalPayload == null) {
        _logger.warning('🔀 MESH RELAY: Invalid relay message received');
        return null;
      }
      
      _logger.info('🔀 MESH RELAY: Processing message ${_safeTruncate(originalMessageId, 16)}... from ${_safeTruncate(senderPublicKey, 8)}...');
      
      // Create relay metadata and message objects
      final metadata = RelayMetadata.fromJson(relayMetadata);
      final originalContent = originalPayload['content'] as String? ?? '';
      
      final relayMessage = MeshRelayMessage(
        originalMessageId: originalMessageId,
        originalContent: originalContent,
        relayMetadata: metadata,
        relayNodeId: senderPublicKey,
        relayedAt: DateTime.now(),
      );
      
      // Process with relay engine
      final result = await _relayEngine!.processIncomingRelay(
        relayMessage: relayMessage,
        fromNodeId: senderPublicKey,
        availableNextHops: getAvailableNextHops(),
      );
      
      // Handle result based on type
      switch (result.type) {
        case RelayProcessingType.deliveredToSelf:
          _logger.info('🔀 MESH RELAY: Message delivered to self');
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
  
  /// Set queue sync manager reference
  void setQueueSyncManager(QueueSyncManager syncManager) {
    _queueSyncManager = syncManager;
  }

  /// Handle relay message forwarding to next hop
  Future<void> _handleRelayToNextHop(MeshRelayMessage message, String nextHopNodeId) async {
    try {
      // Create protocol message for relay
      final protocolMessage = ProtocolMessage.meshRelay(
        originalMessageId: message.originalMessageId,
        originalSender: message.relayMetadata.originalSender,
        finalRecipient: message.relayMetadata.finalRecipient,
        relayMetadata: message.relayMetadata.toJson(),
        originalPayload: {
          'content': message.originalContent,
          'encrypted': message.encryptedPayload != null,
          if (message.encryptedPayload != null) 'encryptedPayload': message.encryptedPayload,
        },
      );
      
      _logger.info('🔀 RELAY FORWARD: Preparing to send relay message to ${_safeTruncate(nextHopNodeId, 8)}...');
      
      // The actual sending would be handled by the BLE service layer
      // This is where we'd integrate with the connection manager
      
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