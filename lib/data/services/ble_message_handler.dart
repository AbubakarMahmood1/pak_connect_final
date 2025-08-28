import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:logging/logging.dart';
import '../../core/utils/message_fragmenter.dart';
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
    
    String payload = message;
bool isEncrypted = false;

if (SimpleCrypto.isInitialized) {
  try {
    payload = SimpleCrypto.encrypt(message);
    isEncrypted = true;
    _logger.info('Message encrypted for transmission');
  } catch (e) {
    _logger.warning('Encryption failed, sending plain: $e');
  }
}

final protocolMessage = ProtocolMessage.textMessage(
  messageId: msgId,
  content: payload,
  encrypted: isEncrypted,
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
bool isEncrypted = false;

if (SimpleCrypto.isInitialized) {
  try {
    payload = SimpleCrypto.encrypt(message);
    isEncrypted = true;
    _logger.info('Message encrypted for peripheral transmission');
  } catch (e) {
    _logger.warning('Encryption failed, sending plain: $e');
  }
}

final protocolMessage = ProtocolMessage.textMessage(
  messageId: msgId,
  content: payload,
  encrypted: isEncrypted,
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
        return await _processCompleteProtocolMessage(completeMessage, onMessageIdFound);
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

Future<String?> _processCompleteProtocolMessage(String completeMessage, String? Function(String)? onMessageIdFound) async {
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
        
        onMessageIdFound?.call(messageId);
        
        if (protocolMessage.isEncrypted && SimpleCrypto.isInitialized) {
          try {
            return SimpleCrypto.decrypt(content);
          } catch (e) {
            return '[Encrypted message - cannot decrypt]';
          }
        }
        return content;
        
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