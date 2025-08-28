import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:logging/logging.dart';
import '../../core/utils/message_fragmenter.dart';
import '../../core/models/ack_message.dart';
import '../../core/models/ble_message.dart';
import '../../core/models/name_exchange.dart';
import '../../core/services/simple_crypto.dart';
import '../../core/models/protocol_message.dart';

class BLEMessageHandler {
  final _logger = Logger('BLEMessageHandler');
  
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
    
    // Rest stays the same...
    String payload = message;
    BLEMessageType messageType = BLEMessageType.text;
    
    if (SimpleCrypto.isInitialized) {
      try {
        payload = SimpleCrypto.encrypt(message);
        messageType = BLEMessageType.encryptedText;
        _logger.info('Message encrypted for transmission');
      } catch (e) {
        _logger.warning('Encryption failed, sending plain: $e');
      }
    }
    
    final protocolMessage = ProtocolMessage.textMessage(
  messageId: msgId,
  content: payload,
  encrypted: messageType == BLEMessageType.encryptedText,
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
}) async {
  final msgId = messageId ?? DateTime.now().millisecondsSinceEpoch.toString();
  
  try {
    String payload = message;
    BLEMessageType messageType = BLEMessageType.text;
    
    if (SimpleCrypto.isInitialized) {
      try {
        payload = SimpleCrypto.encrypt(message);
        messageType = BLEMessageType.encryptedText;
        _logger.info('Message encrypted for peripheral transmission');
      } catch (e) {
        _logger.warning('Encryption failed, sending plain: $e');
      }
    }
    
    final protocolMessage = ProtocolMessage.textMessage(
  messageId: msgId,
  content: payload,
  encrypted: messageType == BLEMessageType.encryptedText,
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

  
Future<String?> processReceivedData(Uint8List data, {String? Function(String)? onMessageIdFound}) async {
  try {
    // Skip single-byte legacy pings
    if (data.length == 1 && data[0] == 0x00) {
      return null;
    }
    
    // Handle legacy special message types first (preserve existing logic)
    if (NameExchange.isNameMessage(data)) {
      return null; // Name exchange handled separately
    }
    
    if (String.fromCharCodes(data) == 'REQUEST_NAME') {
      return null; // Name request handled separately
    }
    
    if (ACKMessage.isACKMessage(data)) {
      final ackMessage = ACKMessage.fromBytes(data);
      if (ackMessage != null) {
        _logger.info('Received legacy ACK for message: ${ackMessage.originalMessageId}');
        
        final ackCompleter = _messageAcks[ackMessage.originalMessageId];
        if (ackCompleter != null && !ackCompleter.isCompleted) {
          ackCompleter.complete(true);
        }
      }
      return null;
    }
    
    // NEW: Check for direct protocol messages (ACKs, etc.) BEFORE chunk processing
    try {
      final directMessage = utf8.decode(data);
      if (ProtocolMessage.isProtocolMessage(directMessage)) {
        return await _handleDirectProtocolMessage(directMessage, onMessageIdFound);
      }
    } catch (e) {
      // Not a direct protocol message, continue to chunk processing
    }
    
    // Try to process as message chunk (existing fragmentation logic)
    try {
      final chunk = MessageChunk.fromBytes(data);
      _logger.info('Received chunk ${chunk.chunkIndex + 1}/${chunk.totalChunks}');
      
      final completeMessage = _messageReassembler.addChunk(chunk);
      
      if (completeMessage != null) {
        _logger.info('Message reassembled successfully');
        return await _processCompleteMessage(completeMessage, onMessageIdFound);
      }
      
    } catch (e) {
      _logger.warning('Chunk processing failed: $e');
      return String.fromCharCodes(data);
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

Future<String?> _processCompleteMessage(String completeMessage, String? Function(String)? onMessageIdFound) async {
  // Try new protocol first
  if (ProtocolMessage.isProtocolMessage(completeMessage)) {
    try {
      final messageBytes = utf8.encode(completeMessage);
      final protocolMessage = ProtocolMessage.fromBytes(messageBytes);
      
      switch (protocolMessage.type) {
        case ProtocolMessageType.textMessage:
          final messageId = protocolMessage.payload['messageId'] as String;
          final content = protocolMessage.payload['content'] as String;
          final isEncrypted = protocolMessage.payload['encrypted'] as bool? ?? false;
          
          onMessageIdFound?.call(messageId);
          
          if (isEncrypted && SimpleCrypto.isInitialized) {
            try {
              return SimpleCrypto.decrypt(content);
            } catch (e) {
              return '[Encrypted message - cannot decrypt]';
            }
          }
          return content;
          
        case ProtocolMessageType.ack:
          final originalId = protocolMessage.payload['originalMessageId'] as String;
          final ackCompleter = _messageAcks[originalId];
          if (ackCompleter != null && !ackCompleter.isCompleted) {
            ackCompleter.complete(true);
          }
          _logger.info('Received protocol ACK for: $originalId');
          return null;

        case ProtocolMessageType.identity:
  	final deviceId = protocolMessage.payload['deviceId'] as String;
  	final displayName = protocolMessage.payload['displayName'] as String;
  	_logger.info('Received protocol identity in message handler: $displayName ($deviceId)');
  	return null;
          
        default:
          _logger.info('Received protocol message type: ${protocolMessage.type.name}');
          return null;
      }
    } catch (e) {
      _logger.warning('Protocol message parsing failed: $e');
      // Fall through to legacy parsing
    }
  }
  
  // Fall back to legacy BLE message parsing (preserve existing logic)
  String actualContent = completeMessage;
  String? messageId;
  
  try {
    final messageBytes = utf8.encode(completeMessage);
    final bleMessage = BLEMessage.fromBytes(messageBytes);
    
    messageId = bleMessage.id;
    _logger.info('Legacy format - extracted message ID: $messageId');
    
    if (bleMessage.type == BLEMessageType.encryptedText && SimpleCrypto.isInitialized) {
      try {
        actualContent = SimpleCrypto.decrypt(bleMessage.payload);
        _logger.info('Legacy message decrypted successfully');
      } catch (e) {
        _logger.warning('Legacy decryption failed: $e');
        actualContent = '[Encrypted message - cannot decrypt]';
      }
    } else {
      actualContent = bleMessage.payload;
    }
  } catch (e) {
    _logger.warning('Legacy BLE message parsing failed: $e');
    // Try alternative parsing for very old messages
    if (completeMessage.startsWith('{') && completeMessage.contains('"id"')) {
      try {
        final json = jsonDecode(completeMessage);
        messageId = json['id'];
        actualContent = json['payload'] ?? completeMessage;
        _logger.info('Very old format parsing successful, extracted ID: $messageId');
      } catch (e2) {
        _logger.warning('All parsing methods failed: $e2');
      }
    }
  }
  
  // Always call the callback with message ID if we have one
  if (messageId != null && onMessageIdFound != null) {
    onMessageIdFound(messageId);
    _logger.info('Message ID callback executed: $messageId');
  } else {
    _logger.warning('No message ID found - ACK will not be sent');
  }
  
  return actualContent;
}
  
  String? extractMessageId(String completeMessage) {
    try {
      final messageBytes = utf8.encode(completeMessage);
      final bleMessage = BLEMessage.fromBytes(messageBytes);
      return bleMessage.id;
    } catch (e) {
      // Try legacy format
      if (completeMessage.startsWith('MSG:')) {
        final parts = completeMessage.split(':');
        if (parts.length >= 3) {
          return parts[1];
        }
      }
    }
    return null;
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