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
import '../../data/repositories/contact_repository.dart';
import 'ble_state_manager.dart';
import '../../core/services/security_manager.dart';

class BLEMessageHandler {
  final _logger = Logger('BLEMessageHandler');
  final ContactRepository _contactRepository = ContactRepository();
  
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
  
  BLEMessageHandler() {
    // Setup periodic cleanup of old partial messages
    _cleanupTimer = Timer.periodic(Duration(minutes: 2), (timer) {
      _messageReassembler.cleanupOldMessages();
    });
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
    },
    timestamp: DateTime.now(),
    signature: signature,
    useEphemeralSigning: signingInfo.useEphemeralSigning,
    ephemeralSigningKey: signingInfo.signingKey,
  );

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
    },
    timestamp: DateTime.now(),
    signature: signature,
    useEphemeralSigning: signingInfo.useEphemeralSigning,
    ephemeralSigningKey: signingInfo.signingKey,
  );

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
        return await _handleDirectProtocolMessage(directMessage, onMessageIdFound);
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

Future<String?> _handleDirectProtocolMessage(String jsonMessage, String? Function(String)? onMessageIdFound) async {
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
        
      print('🔧 DECRYPT DEBUG: Received message with encryption method: $encryptionMethod');
      print('🔧 DECRYPT DEBUG: Message encrypted flag: ${protocolMessage.isEncrypted}');
      print('🔧 DECRYPT DEBUG: Sender public key: ${senderPublicKey?.substring(0, 16)}...');
      

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
        
      case ProtocolMessageType.cryptoVerification:
        // Handle crypto verification challenge
        final challenge = protocolMessage.cryptoVerificationChallenge;
        final testMessage = protocolMessage.cryptoVerificationTestMessage;
        
        if (challenge != null && testMessage != null) {
          _logger.info('🔍 CRYPTO VERIFICATION: Received challenge');
          onCryptoVerificationReceived?.call(challenge, testMessage);
        }
        return null;
        
      case ProtocolMessageType.cryptoVerificationResponse:
        // Handle crypto verification response
        final challenge = protocolMessage.cryptoVerificationResponseChallenge;
        final decryptedMessage = protocolMessage.cryptoVerificationResponseDecrypted;
        final success = protocolMessage.cryptoVerificationSuccess;
        final results = protocolMessage.cryptoVerificationResults;
        
        if (challenge != null && decryptedMessage != null) {
          _logger.info('🔍 CRYPTO VERIFICATION: Received response (success: $success)');
          onCryptoVerificationResponseReceived?.call(challenge, decryptedMessage, success, results);
        }
        return null;
        
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
  
  void dispose() {
    _cleanupTimer?.cancel();
    for (final timer in _messageTimeouts.values) {
      timer.cancel();
    }
    _messageTimeouts.clear();
    _messageAcks.clear();
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