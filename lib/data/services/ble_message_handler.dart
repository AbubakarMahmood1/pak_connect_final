import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:logging/logging.dart';
import '../../core/utils/message_fragmenter.dart';
import '../../core/services/simple_crypto.dart';
import '../../core/models/protocol_message.dart';
import '../../data/repositories/contact_repository.dart';

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
  bool _messageOperationInProgress = false;
  
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
  Function(bool)? onMessageOperationChanged,
}) async {
  _messageOperationInProgress = true;
  final msgId = messageId ?? DateTime.now().millisecondsSinceEpoch.toString();
  
  try {
  onMessageOperationChanged?.call(true);
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
    
    // CRITICAL: Force disconnect to trigger auto-reconnection
    _logger.warning('🔥 Forcing disconnect to trigger reconnection...');
    try {
      await centralManager.disconnect(connectedDevice);
    } catch (disconnectError) {
      _logger.warning('Force disconnect failed: $disconnectError');
    }
    
    throw Exception('Connection unhealthy - forced disconnect');
  }
    
String payload = message;
bool isEncrypted = false;
String encryptionMethod = 'none';


if (contactPublicKey != null && SimpleCrypto.hasConversationKey(contactPublicKey)) {
  try {
    payload = SimpleCrypto.encryptForConversation(message, contactPublicKey);
    isEncrypted = true;
    encryptionMethod = 'conversation';
    _logger.info('Message encrypted with conversation key');
  } catch (e) {
    _logger.warning('Conversation encryption failed: $e');
    // Don't fall back - if conversation key exists but fails, something is wrong
    throw Exception('Conversation encryption failed - re-pairing may be required');
  }
}
// Fall back to ECDH if no conversation key
else if (contactPublicKey != null && contactPublicKey.isNotEmpty) {
  try {
    final ecdhEncrypted = await SimpleCrypto.encryptForContact(message, contactPublicKey, contactRepository);
    if (ecdhEncrypted != null) {
      payload = ecdhEncrypted;
      isEncrypted = true;
      encryptionMethod = 'ecdh';
      _logger.info('Message encrypted with cached ECDH');
    }
  } catch (e) {
    _logger.warning('ECDH encryption failed: $e');
  }
}

if (!isEncrypted) {
  _logger.warning('Sending unencrypted - no ECDH available');
}

// Sign the original message content (before encryption)
final signature = SimpleCrypto.signMessage(message);

final protocolMessage = ProtocolMessage(
  type: ProtocolMessageType.textMessage,
  payload: {
    'messageId': msgId,
    'content': payload,
    'encrypted': isEncrypted,
    'encryptionMethod': encryptionMethod,
  },
  timestamp: DateTime.now(),
  signature: signature,
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
}) async {
  final msgId = messageId ?? DateTime.now().millisecondsSinceEpoch.toString();
  
  try {
    String payload = message;
    bool isEncrypted = false;
    String encryptionMethod = 'none';

    // ECDH encryption if contact public key available
if (contactPublicKey != null && SimpleCrypto.hasConversationKey(contactPublicKey)) {
  try {
    payload = SimpleCrypto.encryptForConversation(message, contactPublicKey);
    isEncrypted = true;
    encryptionMethod = 'conversation';
    _logger.info('Message encrypted with conversation key');
  } catch (e) {
    _logger.warning('Conversation encryption failed: $e');
    // Don't fall back - if conversation key exists but fails, something is wrong
    throw Exception('Conversation encryption failed - re-pairing may be required');
  }
}
// Fall back to ECDH if no conversation key
else if (contactPublicKey != null && contactPublicKey.isNotEmpty) {
  try {
    final ecdhEncrypted = await SimpleCrypto.encryptForContact(message, contactPublicKey, contactRepository);
    if (ecdhEncrypted != null) {
      payload = ecdhEncrypted;
      isEncrypted = true;
      encryptionMethod = 'ecdh';
      _logger.info('Message encrypted with cached ECDH');
    }
  } catch (e) {
    _logger.warning('ECDH encryption failed: $e');
  }
}

if (!isEncrypted) {
  _logger.warning('Sending unencrypted - no ECDH available');
}

    // Sign the original message content (before encryption)
    final signature = SimpleCrypto.signMessage(message);

    final protocolMessage = ProtocolMessage(
      type: ProtocolMessageType.textMessage,
      payload: {
        'messageId': msgId,
        'content': payload,
        'encrypted': isEncrypted,
        'encryptionMethod': encryptionMethod,
      },
      timestamp: DateTime.now(),
      signature: signature,
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
        
        onMessageIdFound?.call(messageId);
        
        // First: Decrypt the message using appropriate method
        String decryptedContent = content;
        
        if (protocolMessage.isEncrypted) {
          // Try conversation encryption first (highest priority)
          if (encryptionMethod == 'conversation' && senderPublicKey != null) {
            try {
              if (SimpleCrypto.hasConversationKey(senderPublicKey)) {
                decryptedContent = SimpleCrypto.decryptFromConversation(content, senderPublicKey);
                _logger.info('Message decrypted using conversation key');
              } else {
                _logger.warning('No conversation key found for sender');
                return '[Secure chat not established - pairing required]';
              }
            } catch (e) {
              _logger.severe('Conversation decryption failed: $e');
              return '[Decryption failed - re-pair with sender]';
            }
          } 
          // Try ECDH encryption
          else if (encryptionMethod == 'ecdh' && senderPublicKey != null && senderPublicKey.isNotEmpty) {
            try {
              final decrypted = await SimpleCrypto.decryptFromContact(content, senderPublicKey, _contactRepository);
              if (decrypted != null) {
                decryptedContent = decrypted;
                _logger.info('Message decrypted using ECDH');
              } else {
                return '[ECDH decryption failed]';
              }
            } catch (e) {
              _logger.severe('ECDH decryption failed: $e');
              return '[ECDH decryption error]';
            }
          }
          // Legacy passphrase decryption (fallback)
          else if (encryptionMethod == null || encryptionMethod == 'passphrase') {
            if (SimpleCrypto.isInitialized) {
              try {
                decryptedContent = SimpleCrypto.decrypt(content);
                _logger.info('Message decrypted using passphrase (legacy)');
              } catch (e) {
                _logger.severe('Legacy decryption failed: $e');
                return '[Cannot decrypt legacy message]';
              }
            } else {
              return '[No decryption method available]';
            }
          }
          else {
            _logger.warning('Unknown encryption method: $encryptionMethod');
            return '[Unknown encryption method]';
          }
        }
        
        // Then: Verify signature on decrypted content
        if (protocolMessage.signature != null && senderPublicKey != null) {
          final isValid = SimpleCrypto.verifySignature(
            decryptedContent,  // Use decrypted content for verification
            protocolMessage.signature!, 
            senderPublicKey
          );
          
          if (!isValid) {
            _logger.severe('⌠SIGNATURE VERIFICATION FAILED - possible impersonation!');
            return '[UNTRUSTED MESSAGE - Signature Invalid]';
          }
          
          _logger.info('✅ Signature verified - message authentic');
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
        // Identity should be handled at service level, not here
        return null;
        
      default:
        return null;
    }
  } catch (e) {
    _logger.severe('Failed to process protocol message: $e');
    return null;
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