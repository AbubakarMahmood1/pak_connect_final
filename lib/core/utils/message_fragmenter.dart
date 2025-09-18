import 'dart:convert';
import 'dart:typed_data';

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
  final shortId = messageId.substring(messageId.length - 6);
  
  // Convert bytes back to string to ensure UTF-8 boundary safety
  final originalString = utf8.decode(data);
  
  // Fixed header size calculation
  const headerSize = 15; // "123456|0|999|0|"
  final contentSpace = maxSize - headerSize;
  
  if (contentSpace <= 10) {
    throw Exception('MTU too small for headers');
  }
  
  // Fragment by characters (UTF-8 safe), not bytes
  final totalChunks = (originalString.length / contentSpace).ceil();
  final chunks = <MessageChunk>[];
  
  for (int i = 0; i < totalChunks; i++) {
    final start = i * contentSpace;
    final end = (start + contentSpace < originalString.length) 
        ? start + contentSpace 
        : originalString.length;
    
    final chunkContent = originalString.substring(start, end);
    
    chunks.add(MessageChunk(
      messageId: shortId,
      chunkIndex: i,
      totalChunks: totalChunks,
      content: chunkContent, // Keep as string, not base64
      timestamp: timestamp,
      isBinary: false, // Mark as text
    ));
  }
  
  return chunks;
}

}

class MessageReassembler {
  final Map<String, Map<int, MessageChunk>> _pendingMessages = {};
  final Map<String, DateTime> _messageTimestamps = {};
  
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
    
    // Simple concatenation - no base64 nonsense
    return sortedChunks.map((c) => c.content).join('');
  }
  
  return null; // Still waiting for more chunks
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