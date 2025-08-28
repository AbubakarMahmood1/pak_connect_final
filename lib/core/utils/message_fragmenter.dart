import 'dart:convert';
import 'dart:typed_data';
import 'dart:math' as math;
import 'package:logging/logging.dart';

class MessageChunk {
  final String messageId;
  final int chunkIndex;
  final int totalChunks;
  final String content;
  final DateTime timestamp;
  final bool isBinary;

  MessageChunk({
    required this.messageId,
    required this.chunkIndex,
    required this.totalChunks,
    required this.content,
    required this.timestamp,
    this.isBinary = false,
  });

  // Ultra-compact format: "shortId|idx|total|content"
  Uint8List toBytes() {
  final shortId = messageId.substring(messageId.length - 6);
  final binaryFlag = isBinary ? '1' : '0';
  final compactString = '$shortId|$chunkIndex|$totalChunks|$binaryFlag|$content';
  return Uint8List.fromList(utf8.encode(compactString));
}

  static MessageChunk fromBytes(Uint8List bytes) {
  final compactString = utf8.decode(bytes);
  final parts = compactString.split('|');
  
  if (parts.length != 5) {  // Changed from 4 to 5
    throw FormatException('Invalid chunk format: $compactString');
  }
  
  return MessageChunk(
    messageId: parts[0],
    chunkIndex: int.parse(parts[1]),
    totalChunks: int.parse(parts[2]),
    isBinary: parts[3] == '1',  // Parse binary flag
    content: parts[4],  // Content is now at index 4
    timestamp: DateTime.now(),
  );
}

  @override
  String toString() => 'Chunk ${chunkIndex + 1}/$totalChunks: "$content"';
}

class MessageFragmenter {
  // Fragment a message into chunks that fit within MTU limit
static List<MessageChunk> fragment(String message, int maxChunkSize) {
  if (message.isEmpty) return [];
  
  final messageId = DateTime.now().millisecondsSinceEpoch.toString();
  final timestamp = DateTime.now();
  
  // Safety check: Minimum viable MTU
  if (maxChunkSize < 25) {
    throw Exception('MTU too small: $maxChunkSize bytes (minimum 25 required)');
  }
  
  // Safety limit: Maximum iterations to prevent infinite loops
  const maxIterations = 10;
  int iterations = 0;
  
  int estimatedChunks = 1;
  List<MessageChunk> finalChunks = [];
  
  while (iterations < maxIterations) {
    iterations++;
    
    // Calculate header size for current chunk estimate
    final sampleHeader = '$messageId|0|$estimatedChunks|';
    final headerSize = utf8.encode(sampleHeader).length;
    final contentSpace = maxChunkSize - headerSize;
    
    if (contentSpace <= 5) { // Need at least 5 bytes for content
      throw Exception('MTU insufficient: need ${headerSize + 6} bytes minimum, got $maxChunkSize');
    }
    
    // Calculate actual chunks needed
    final actualChunksNeeded = (message.length / contentSpace).ceil();
    
    if (actualChunksNeeded == estimatedChunks || iterations >= maxIterations) {
      // Create chunks with current estimate
      for (int i = 0; i < estimatedChunks; i++) {
        final start = i * contentSpace;
        final end = (start + contentSpace < message.length) 
            ? start + contentSpace 
            : message.length;
            
        finalChunks.add(MessageChunk(
          messageId: messageId,
          chunkIndex: i,
          totalChunks: estimatedChunks,
          content: message.substring(start, end),
          timestamp: timestamp,
          isBinary: true,
        ));
      }
      break;
    } else {
      estimatedChunks = actualChunksNeeded;
    }
  }
  
  if (finalChunks.isEmpty) {
    throw Exception('Fragmentation failed after $maxIterations iterations');
  }
  
  return finalChunks;
}

static List<MessageChunk> fragmentBytes(Uint8List data, int maxSize, String messageId) {
  final timestamp = DateTime.now();
  
  // Use short ID (last 6 digits) like the regular fragment method
  final shortId = messageId.substring(messageId.length - 6);
  
  // Step 1: Estimate chunks needed and calculate actual header size
  int estimatedChunks = 1;
  List<MessageChunk> finalChunks = [];
  
  while (true) {
    // Calculate header size for this chunk count (using base64 content estimate)
    final sampleHeader = '$shortId|0|$estimatedChunks|0|';
    final headerSize = utf8.encode(sampleHeader).length;
    
    // Reserve extra space for base64 overhead (base64 is ~33% larger)
    final base64Overhead = 1.34; // Base64 is 4/3 = 1.333... larger
    final contentSpaceBytes = ((maxSize - headerSize) / base64Overhead).floor();
    
    if (contentSpaceBytes <= 0) {
      throw Exception('MTU too small for headers: need ${headerSize + 10} bytes minimum');
    }
    
    // Calculate how many chunks we actually need
    final actualChunksNeeded = (data.length / contentSpaceBytes).ceil();
    
    if (actualChunksNeeded == estimatedChunks) {
      // Our estimate was correct, create the chunks
      for (int i = 0; i < estimatedChunks; i++) {
        final start = i * contentSpaceBytes;
        final end = math.min(start + contentSpaceBytes, data.length);
        final chunkData = data.sublist(start, end);
        
        // Store as base64 to avoid UTF-8 issues in chunk format
        final chunkContent = base64Encode(chunkData);
        
        finalChunks.add(MessageChunk(
          messageId: shortId, // Use short ID consistently
          chunkIndex: i,
          totalChunks: estimatedChunks,
          content: chunkContent,
          timestamp: timestamp,
        ));
      }
      break;
    } else {
      // Update estimate and try again
      estimatedChunks = actualChunksNeeded;
    }
  }
  
  return finalChunks;
}

}

class MessageReassembler {
  final _logger = Logger('MessageReassembler');
  final Map<String, Map<int, MessageChunk>> _pendingMessages = {};
  final Map<String, DateTime> _messageTimestamps = {};
  
  // Add a chunk and return complete message if all chunks received
  String? addChunk(MessageChunk chunk) {
  final messageId = chunk.messageId;
  
  // Initialize message tracking
  if (!_pendingMessages.containsKey(messageId)) {
    _pendingMessages[messageId] = {};
    _messageTimestamps[messageId] = DateTime.now();
  }
  
  // Store this chunk
  _pendingMessages[messageId]![chunk.chunkIndex] = chunk;
  
  // Check if we have all chunks
  final receivedChunks = _pendingMessages[messageId]!;
  if (receivedChunks.length == chunk.totalChunks) {
    // Reassemble message
    final sortedChunks = <MessageChunk>[];
    for (int i = 0; i < chunk.totalChunks; i++) {
      if (!receivedChunks.containsKey(i)) {
        return null; // Missing chunk
      }
      sortedChunks.add(receivedChunks[i]!);
    }
    
    // Clean up
    _pendingMessages.remove(messageId);
    _messageTimestamps.remove(messageId);
    
try {
  // Always try direct concatenation first
  final reconstructed = sortedChunks.map((c) => c.content).join('');
  
  // If it looks like base64 JSON, decode it
  if (_looksLikeBase64Json(reconstructed)) {
    try {
      final decoded = utf8.decode(base64Decode(reconstructed));
      _logger.info('Decoded base64 message: ${decoded.substring(0, 50)}...');
      return decoded;
    } catch (e) {
      _logger.warning('Base64 decode failed: $e');
      return reconstructed;
    }
  }
  
  // For binary chunks (file data), decode each chunk
  if (sortedChunks[0].isBinary) {
    final allBytes = <int>[];
    for (final chunk in sortedChunks) {
      final chunkBytes = base64Decode(chunk.content);
      allBytes.addAll(chunkBytes);
    }
    return utf8.decode(allBytes);
  }
  
  return reconstructed;
} catch (e) {
  _logger.severe('Message reassembly failed: $e');
  return sortedChunks.map((c) => c.content).join('');
}
  }
  
  return null; // Still waiting for more chunks
}

bool _looksLikeBase64Json(String str) {
  if (str.length < 10) return false;
  
  // Base64 pattern check
  final base64Pattern = RegExp(r'^[A-Za-z0-9+/]*={0,2}$');
  if (!base64Pattern.hasMatch(str)) return false;
  
  // Try to decode and check if it starts with JSON
  try {
    final decoded = utf8.decode(base64Decode(str));
    final trimmed = decoded.trim();
    
    // Check for both old format (has "id") and new protocol (has "type")
    return trimmed.startsWith('{') && 
           (trimmed.contains('"id"') || trimmed.contains('"type"'));
  } catch (e) {
    return false;
  }
}
  
  // Clean up old partial messages (call periodically)
  void cleanupOldMessages({Duration timeout = const Duration(minutes: 2)}) {
    final now = DateTime.now();
    final expiredIds = <String>[];
    
    _messageTimestamps.forEach((messageId, timestamp) {
      if (now.difference(timestamp) > timeout) {
        expiredIds.add(messageId);
      }
    });
    
    for (final id in expiredIds) {
      _pendingMessages.remove(id);
      _messageTimestamps.remove(id);
    }
  }
}