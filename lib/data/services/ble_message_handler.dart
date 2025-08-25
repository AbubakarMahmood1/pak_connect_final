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
    
    final jsonString = jsonEncode({
      'id': msgId,
      'type': messageType.index,
      'payload': payload,
      'timestamp': DateTime.now().millisecondsSinceEpoch,
      'encrypted': messageType == BLEMessageType.encryptedText,
    });
    
    final jsonBytes = utf8.encode(jsonString);
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
    
    final jsonString = jsonEncode({
      'id': msgId,
      'type': messageType.index,
      'payload': payload,
      'timestamp': DateTime.now().millisecondsSinceEpoch,
      'encrypted': messageType == BLEMessageType.encryptedText,
    });
    
    final jsonBytes = utf8.encode(jsonString);
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
    // Check special message types first
    if (data.length == 1 && data[0] == 0x00) {
      return null; // Ping message, ignore
    }
    
    if (NameExchange.isNameMessage(data)) {
      return null; // Name exchange handled separately
    }
    
    if (String.fromCharCodes(data) == 'REQUEST_NAME') {
      return null; // Name request handled separately
    }
    
    if (ACKMessage.isACKMessage(data)) {
      final ackMessage = ACKMessage.fromBytes(data);
      if (ackMessage != null) {
        _logger.info('Received ACK for message: ${ackMessage.originalMessageId}');
        
        final ackCompleter = _messageAcks[ackMessage.originalMessageId];
        if (ackCompleter != null && !ackCompleter.isCompleted) {
          ackCompleter.complete(true);
        }
      }
      return null;
    }
    
    // Try to process as message chunk
    try {
      final chunk = MessageChunk.fromBytes(data);
      _logger.info('Received chunk ${chunk.chunkIndex + 1}/${chunk.totalChunks}');
      
      final completeMessage = _messageReassembler.addChunk(chunk);
      
      if (completeMessage != null) {
        _logger.info('Message reassembled successfully');
        
        String actualContent = completeMessage;
        String? messageId;
        
        try {
          // FIXED: Be more defensive about JSON parsing
          final messageBytes = utf8.encode(completeMessage);
          final bleMessage = BLEMessage.fromBytes(messageBytes);
          
          messageId = bleMessage.id;
          _logger.info('Extracted message ID: $messageId');
          
          if (bleMessage.type == BLEMessageType.encryptedText && SimpleCrypto.isInitialized) {
            try {
              actualContent = SimpleCrypto.decrypt(bleMessage.payload);
              _logger.info('Message decrypted successfully');
            } catch (e) {
              _logger.warning('Decryption failed: $e');
              actualContent = '[Encrypted message - cannot decrypt]';
            }
          } else {
            actualContent = bleMessage.payload;
          }
        } catch (e) {
          _logger.warning('BLE message parsing failed: $e');
          // Try alternative parsing for legacy messages
          if (completeMessage.startsWith('{') && completeMessage.contains('"id"')) {
            try {
              final json = jsonDecode(completeMessage);
              messageId = json['id'];
              actualContent = json['payload'] ?? completeMessage;
              _logger.info('Legacy parsing successful, extracted ID: $messageId');
            } catch (e2) {
              _logger.warning('Legacy parsing also failed: $e2');
            }
          }
        }
        
        // CRITICAL: Always call the callback with message ID if we have one
        if (messageId != null && onMessageIdFound != null) {
          onMessageIdFound(messageId);
          _logger.info('Message ID callback executed: $messageId');
        } else {
          _logger.warning('No message ID found - ACK will not be sent');
        }
        
        return actualContent;
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