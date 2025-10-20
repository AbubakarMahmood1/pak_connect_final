import 'dart:convert';
import 'dart:typed_data';
import 'package:logging/logging.dart';

final _logger = Logger('MessageFragmenter');

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
  // FIX: Ensure we don't try to get more characters than available
  final shortId = messageId.length >= 6
    ? messageId.substring(messageId.length - 6)
    : messageId; // Use full messageId if less than 6 chars
  final binaryFlag = isBinary ? '1' : '0';
  final compactString = '$shortId|$chunkIndex|$totalChunks|$binaryFlag|$content';
  final bytes = Uint8List.fromList(utf8.encode(compactString));
  
  // 🔧 DEBUG: Log what we're sending
  _logger.fine('🔧 CHUNK DEBUG: toBytes() called');
  _logger.fine('🔧 CHUNK DEBUG: Format: $shortId|$chunkIndex|$totalChunks|$binaryFlag|${content.length} chars');
  _logger.fine('🔧 CHUNK DEBUG: First 50 bytes: ${bytes.sublist(0, bytes.length > 50 ? 50 : bytes.length)}');
  
  return bytes;
}

  static MessageChunk fromBytes(Uint8List bytes) {
  // 🔧 FIX (Oct 18, 2025): Avoid UTF-8 decoding the entire chunk at once
  // Problem: Combining header bytes + base64 payload bytes can create invalid UTF-8 sequences
  // Solution: Use String.fromCharCodes() which treats bytes as individual characters (no multi-byte validation)
  
  // 🔧 DEBUG: Log what we're receiving
  _logger.fine('🔧 CHUNK DEBUG: fromBytes() called');
  _logger.fine('🔧 CHUNK DEBUG: Received ${bytes.length} bytes');
  _logger.fine('🔧 CHUNK DEBUG: First 50 bytes: ${bytes.sublist(0, bytes.length > 50 ? 50 : bytes.length)}');

  // Convert bytes to string using ASCII-only decoding (safe for base64)
  // This avoids UTF-8 multi-byte sequence validation that causes FormatException
  final chunkString = String.fromCharCodes(bytes);

  _logger.fine('🔧 CHUNK DEBUG: Decoded string length: ${chunkString.length}');
  _logger.fine('🔧 CHUNK DEBUG: First 100 chars: ${chunkString.substring(0, chunkString.length > 100 ? 100 : chunkString.length)}');

  // Split by delimiter
  final parts = chunkString.split('|');

  _logger.fine('🔧 CHUNK DEBUG: Split into ${parts.length} parts');
  if (parts.isNotEmpty) _logger.fine('🔧 CHUNK DEBUG: Part 0 (msgId): ${parts[0]}');
  if (parts.length > 1) _logger.fine('🔧 CHUNK DEBUG: Part 1 (idx): ${parts[1]}');
  if (parts.length > 2) _logger.fine('🔧 CHUNK DEBUG: Part 2 (total): ${parts[2]}');
  if (parts.length > 3) _logger.fine('🔧 CHUNK DEBUG: Part 3 (binary): ${parts[3]}');
  if (parts.length > 4) _logger.fine('🔧 CHUNK DEBUG: Part 4 (content): ${parts[4].length} chars');
  
  if (parts.length != 5) {
    throw FormatException('Invalid chunk format: expected 5 parts, got ${parts.length}. Data: ${chunkString.substring(0, chunkString.length > 50 ? 50 : chunkString.length)}...');
  }
  
  return MessageChunk(
    messageId: parts[0],
    chunkIndex: int.parse(parts[1]),
    totalChunks: int.parse(parts[2]),
    isBinary: parts[3] == '1',
    content: parts[4],
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
  // FIX: Ensure we don't try to get more characters than available
  final shortId = messageId.length >= 6
    ? messageId.substring(messageId.length - 6)
    : messageId; // Use full messageId if less than 6 chars
  
  // 🔧 CRITICAL FIX: Work with bytes directly - data might be compressed binary, not UTF-8 text!
  // Messages can be compressed in ProtocolMessage.toBytes(), so we can't assume UTF-8.
  
  // Fixed header size calculation + BLE notification overhead
  const headerSize = 15; // "123456|0|999|0|"
  const bleOverhead = 5; // BLE notification protocol overhead (ATT headers, etc.)
  
  // 🔧 CRITICAL: Account for base64 expansion (4/3 ratio = ~33% increase)
  // Base64 encoding: every 3 bytes → 4 characters
  // So we need to limit raw bytes to ensure base64 output fits in MTU
  final availableSpace = maxSize - headerSize - bleOverhead;
  
  // Calculate max raw bytes that when base64-encoded will fit in availableSpace
  // base64(n bytes) = ceil(n * 4/3) characters
  // Solving for n: n = floor(availableSpace * 3/4)
  final contentSpace = (availableSpace * 3 / 4).floor();
  
  if (contentSpace <= 10) {
    throw Exception('MTU too small for headers and base64 encoding');
  }
  
  // 🔧 FIX: Fragment by BYTE count directly (no UTF-8 assumptions)
  // Data is already binary (compressed or uncompressed JSON bytes)
  final chunks = <MessageChunk>[];
  int chunkIndex = 0;
  
  // Calculate total chunks needed
  final totalChunks = (data.length / contentSpace).ceil();
  
  // Split data into chunks
  int byteOffset = 0;
  while (byteOffset < data.length) {
    // Calculate chunk size
    final remainingBytes = data.length - byteOffset;
    final chunkSize = remainingBytes > contentSpace ? contentSpace : remainingBytes;
    
    // Extract chunk bytes
    final chunkBytes = data.sublist(byteOffset, byteOffset + chunkSize);
    
    // Base64 encode for text transmission over BLE
    final chunkContent = base64.encode(chunkBytes);
    
    chunks.add(MessageChunk(
      messageId: shortId,
      chunkIndex: chunkIndex,
      totalChunks: totalChunks,
      content: chunkContent,
      timestamp: timestamp,
      isBinary: true, // Mark as binary to indicate base64 encoding
    ));
    
    byteOffset += chunkSize;
    chunkIndex++;
  }
  
  return chunks;
}

}

class MessageReassembler {
  final Map<String, Map<int, MessageChunk>> _pendingMessages = {};
  final Map<String, DateTime> _messageTimestamps = {};
  
  /// Reassemble message chunks and return as string
  /// 
  /// For binary chunks, decodes base64 and converts bytes to UTF-8 string.
  /// For text chunks, concatenates strings directly.
  /// 
  /// IMPORTANT: Only use this for messages where the final bytes are valid UTF-8!
  /// For binary protocol messages with compression, use [addChunkBytes] instead.
  String? addChunk(MessageChunk chunk) {
    _logger.fine('🔄 REASSEMBLE: addChunk() called for chunk ${chunk.chunkIndex + 1}/${chunk.totalChunks} of message ${chunk.messageId}');
    final bytes = addChunkBytes(chunk);
    if (bytes == null) {
      _logger.fine('🔄 REASSEMBLE: Still waiting for more chunks');
      return null;
    }

    _logger.fine('🔄 REASSEMBLE: All chunks received! Reassembled ${bytes.length} bytes');
    _logger.fine('🔄 REASSEMBLE: First 50 bytes: ${bytes.sublist(0, bytes.length > 50 ? 50 : bytes.length)}');

    // Convert bytes to string (assumes valid UTF-8)
    _logger.fine('🔄 REASSEMBLE: Converting bytes to UTF-8 string');
    final result = utf8.decode(bytes);
    _logger.fine('🔄 REASSEMBLE✅: Successfully decoded ${result.length} character string');
    return result;
  }
  
  /// Reassemble message chunks and return as bytes
  /// 
  /// This is the core reassembly method. For binary chunks, decodes base64
  /// and concatenates raw bytes. For text chunks, encodes strings as UTF-8.
  /// 
  /// Use this for protocol messages that may contain compressed (non-UTF-8) data.
  Uint8List? addChunkBytes(MessageChunk chunk) {
    final messageId = chunk.messageId;

    _logger.fine('🔄 REASSEMBLE BYTES: Received chunk ${chunk.chunkIndex + 1}/${chunk.totalChunks} for message $messageId');
    _logger.fine('🔄 REASSEMBLE BYTES: Chunk is ${chunk.isBinary ? "BINARY (base64)" : "TEXT"}');
    _logger.fine('🔄 REASSEMBLE BYTES: Content length: ${chunk.content.length} chars');

    // Initialize message tracking
    if (!_pendingMessages.containsKey(messageId)) {
      _pendingMessages[messageId] = {};
      _messageTimestamps[messageId] = DateTime.now();
      _logger.fine('🔄 REASSEMBLE BYTES: Started tracking new message $messageId');
    }

    // Store this chunk
    _pendingMessages[messageId]![chunk.chunkIndex] = chunk;
    _logger.fine('🔄 REASSEMBLE BYTES: Stored chunk ${chunk.chunkIndex}. Have ${_pendingMessages[messageId]!.length}/${chunk.totalChunks} chunks');
    
    // Check if we have all chunks
    final receivedChunks = _pendingMessages[messageId]!;
    if (receivedChunks.length == chunk.totalChunks) {
      _logger.fine('🔄 REASSEMBLE BYTES✅: All ${chunk.totalChunks} chunks received! Starting reassembly');
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

      // 🔧 FIX: Handle both binary (base64) and text chunks
      // Binary chunks: decode base64, concatenate bytes, return raw bytes
      // Text chunks: concatenate strings, encode as UTF-8
      final firstChunk = sortedChunks.first;
      if (firstChunk.isBinary) {
        _logger.fine('🔄 REASSEMBLE BYTES: Mode = BINARY (base64 decoding)');
        // Binary mode: decode base64 chunks, concatenate bytes
        final allBytes = <int>[];
        for (int i = 0; i < sortedChunks.length; i++) {
          final chunk = sortedChunks[i];
          _logger.fine('🔄 REASSEMBLE BYTES: Decoding base64 chunk ${i + 1}/${sortedChunks.length} (${chunk.content.length} chars)');
          final chunkBytes = base64.decode(chunk.content);
          _logger.fine('🔄 REASSEMBLE BYTES: Chunk ${i + 1} decoded to ${chunkBytes.length} bytes');
          allBytes.addAll(chunkBytes);
        }
        _logger.fine('🔄 REASSEMBLE BYTES✅: Total reassembled: ${allBytes.length} bytes');
        _logger.fine('🔄 REASSEMBLE BYTES: First 50 bytes: ${allBytes.sublist(0, allBytes.length > 50 ? 50 : allBytes.length)}');
        // Return raw bytes (may be compressed/non-UTF-8 data!)
        return Uint8List.fromList(allBytes);
      } else {
        _logger.fine('🔄 REASSEMBLE BYTES: Mode = TEXT (string concatenation)');
        // Legacy text mode: concatenate strings, encode as UTF-8
        final text = sortedChunks.map((c) => c.content).join('');
        _logger.fine('🔄 REASSEMBLE BYTES✅: Concatenated ${text.length} characters');
        return Uint8List.fromList(utf8.encode(text));
      }
    }

    _logger.fine('🔄 REASSEMBLE BYTES: Still waiting for more chunks (${receivedChunks.length}/${chunk.totalChunks})');
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