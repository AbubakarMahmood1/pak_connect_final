import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:logging/logging.dart';
import 'package:pak_connect/domain/values/id_types.dart';

final _logger = Logger('MessageFragmenter');

/// Source of collision-resistant transport-level fragment ids.
///
/// The wire id groups a message's chunks at the reassembler; it is not a
/// semantic message id (that lives inside the reassembled payload). It must
/// carry enough entropy that two messages in flight within the reassembly
/// window — possibly from different senders — never share an id.
final Random _wireIdRandom = Random.secure();

/// Generate an ~64-bit collision-resistant fragment wire id.
///
/// base64url of 8 random bytes (11 chars, padding stripped). The base64url
/// alphabet (A-Za-z0-9-_) contains no '|', so it is safe in the pipe-
/// delimited chunk format. Replaces the previous 6-char truncation of the
/// caller id, which collided whenever two ids shared a 6-char suffix
/// (PC-FRAG-001) — trivially likely for timestamp-derived ids.
String _newWireFragmentId() {
  final bytes = List<int>.generate(8, (_) => _wireIdRandom.nextInt(256));
  return base64Url.encode(bytes).replaceAll('=', '');
}

class MessageChunk {
  final String messageId;
  MessageId get messageIdValue => MessageId(messageId);
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

  factory MessageChunk.withId({
    required MessageId messageId,
    required int chunkIndex,
    required int totalChunks,
    required String content,
    required DateTime timestamp,
    bool isBinary = false,
  }) => MessageChunk(
    messageId: messageId.value,
    chunkIndex: chunkIndex,
    totalChunks: totalChunks,
    content: content,
    timestamp: timestamp,
    isBinary: isBinary,
  );

  // Ultra-compact format: "id|idx|total|binaryFlag|content"
  Uint8List toBytes() {
    // The id is emitted verbatim: fragmenters assign a compact, collision-
    // resistant wire id, so there is nothing to truncate. Truncating here
    // (previously to 6 chars) destroyed that entropy and caused reassembly
    // collisions (PC-FRAG-001).
    final binaryFlag = isBinary ? '1' : '0';
    final compactString =
        '$messageId|$chunkIndex|$totalChunks|$binaryFlag|$content';
    final bytes = Uint8List.fromList(utf8.encode(compactString));

    _logger.fine(
      '🔧 CHUNK DEBUG: Encoded chunk $messageId '
      '(${chunkIndex + 1}/$totalChunks, ${bytes.length} bytes, '
      '${isBinary ? "binary" : "text"})',
    );

    return bytes;
  }

  static MessageChunk fromBytes(Uint8List bytes) {
    final chunkString = utf8.decode(bytes);

    _logger.fine(
      '🔧 CHUNK DEBUG: Decoding ${bytes.length} incoming chunk bytes',
    );

    final separators = <int>[];
    for (var i = 0; i < chunkString.length && separators.length < 4; i++) {
      if (chunkString.codeUnitAt(i) == 0x7c) separators.add(i);
    }
    if (separators.length != 4) {
      throw const FormatException(
        'Invalid chunk format: expected four header delimiters',
      );
    }

    final messageId = chunkString.substring(0, separators[0]);
    final indexText = chunkString.substring(separators[0] + 1, separators[1]);
    final totalText = chunkString.substring(separators[1] + 1, separators[2]);
    final binaryText = chunkString.substring(separators[2] + 1, separators[3]);
    final chunkIndex = int.tryParse(indexText);
    final totalChunks = int.tryParse(totalText);
    if (chunkIndex == null || totalChunks == null) {
      throw const FormatException('Invalid chunk index metadata');
    }
    if (binaryText != '0' && binaryText != '1') {
      throw const FormatException('Invalid chunk binary flag');
    }

    return MessageChunk(
      messageId: messageId,
      chunkIndex: chunkIndex,
      totalChunks: totalChunks,
      isBinary: binaryText == '1',
      content: chunkString.substring(separators[3] + 1),
      timestamp: DateTime.now(),
    );
  }

  @override
  String toString() =>
      'Chunk ${chunkIndex + 1}/$totalChunks (${content.length} chars)';
}

class MessageFragmenter {
  // Fragment a message into chunks that fit within MTU limit
  static List<MessageChunk> fragment(String message, int maxChunkSize) {
    if (message.isEmpty) return [];
    return fragmentBytes(
      Uint8List.fromList(utf8.encode(message)),
      maxChunkSize,
      'text',
    );
  }

  static List<MessageChunk> fragmentBytes(
    Uint8List data,
    int maxSize,
    String messageId,
  ) {
    if (data.isEmpty) return const <MessageChunk>[];
    final timestamp = DateTime.now();
    // Collision-resistant transport id (see _newWireFragmentId). The caller's
    // [messageId] is a semantic id and is intentionally not used as the wire
    // grouping key — truncating it to 6 chars caused reassembly collisions
    // (PC-FRAG-001).
    final shortId = _newWireFragmentId();

    const bleOverhead =
        5; // BLE notification protocol overhead (ATT headers, etc.)
    const maxChunks = 0xffff;
    var estimatedTotal = 1;
    var contentSpace = 0;

    for (var iteration = 0; iteration < 20; iteration++) {
      if (estimatedTotal > maxChunks) {
        throw ArgumentError.value(
          estimatedTotal,
          'data',
          'requires more than $maxChunks fragments',
        );
      }
      final maxIndexDigits = (estimatedTotal - 1).toString().length;
      final totalDigits = estimatedTotal.toString().length;
      final headerSize = shortId.length + maxIndexDigits + totalDigits + 6;
      final availableEncodedBytes = maxSize - bleOverhead - headerSize;
      contentSpace = (availableEncodedBytes ~/ 4) * 3;
      if (contentSpace <= 0) {
        throw ArgumentError.value(
          maxSize,
          'maxSize',
          'MTU too small for fragment metadata and base64 payload',
        );
      }

      final actualTotal = (data.length + contentSpace - 1) ~/ contentSpace;
      if (actualTotal == estimatedTotal) break;
      estimatedTotal = actualTotal;
      if (iteration == 19) {
        throw StateError('Fragment sizing did not converge');
      }
    }

    if (estimatedTotal > maxChunks) {
      throw ArgumentError.value(
        estimatedTotal,
        'data',
        'requires more than $maxChunks fragments',
      );
    }

    final chunks = <MessageChunk>[];
    for (var index = 0, offset = 0; offset < data.length; index++) {
      final end = min(offset + contentSpace, data.length);
      final chunk = MessageChunk(
        messageId: shortId,
        chunkIndex: index,
        totalChunks: estimatedTotal,
        content: base64.encode(data.sublist(offset, end)),
        timestamp: timestamp,
        isBinary: true,
      );
      if (chunk.toBytes().length + bleOverhead > maxSize) {
        throw StateError('Fragment exceeded negotiated MTU budget');
      }
      chunks.add(chunk);
      offset = end;
    }

    return chunks;
  }

  static List<MessageChunk> fragmentBytesWithId(
    Uint8List data,
    int maxSize,
    MessageId messageId,
  ) => fragmentBytes(data, maxSize, messageId.value);
}

class MessageReassembler {
  MessageReassembler({
    this.maxActiveAssemblies = 32,
    this.maxMessageBytes = 1024 * 1024,
    this.maxRetainedBytes = 1024 * 1024,
    this.maxChunksPerMessage = 0xffff,
    this.maxRetainedFragments = 16384,
  }) {
    _requirePositive('maxActiveAssemblies', maxActiveAssemblies);
    _requirePositive('maxMessageBytes', maxMessageBytes);
    _requirePositive('maxRetainedBytes', maxRetainedBytes);
    _requirePositive('maxChunksPerMessage', maxChunksPerMessage);
    _requirePositive('maxRetainedFragments', maxRetainedFragments);
  }

  final int maxActiveAssemblies;
  final int maxMessageBytes;
  final int maxRetainedBytes;
  final int maxChunksPerMessage;

  /// Global cap on decoded fragment objects, independent of payload bytes.
  final int maxRetainedFragments;

  final Map<String, _PendingAssembly> _pendingMessages = {};
  int _retainedBytes = 0;
  int _retainedFragments = 0;

  /// Reassemble message chunks and return as string
  ///
  /// For binary chunks, decodes base64 and converts bytes to UTF-8 string.
  /// For text chunks, concatenates strings directly.
  ///
  /// IMPORTANT: Only use this for messages where the final bytes are valid UTF-8!
  /// For binary protocol messages with compression, use [addChunkBytes] instead.
  String? addChunk(MessageChunk chunk) {
    _logger.fine(
      '🔄 REASSEMBLE: addChunk() called for chunk ${chunk.chunkIndex + 1}/${chunk.totalChunks} of message ${chunk.messageId}',
    );
    final bytes = addChunkBytes(chunk);
    if (bytes == null) {
      _logger.fine('🔄 REASSEMBLE: Still waiting for more chunks');
      return null;
    }

    _logger.fine(
      '🔄 REASSEMBLE: All chunks received! Reassembled ${bytes.length} bytes',
    );

    // Convert bytes to string (assumes valid UTF-8)
    _logger.fine('🔄 REASSEMBLE: Converting bytes to UTF-8 string');
    final result = utf8.decode(bytes);
    _logger.fine(
      '🔄 REASSEMBLE✅: Successfully decoded ${result.length} character string',
    );
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

    _logger.fine(
      '🔄 REASSEMBLE BYTES: Received chunk ${chunk.chunkIndex + 1}/${chunk.totalChunks} for message $messageId',
    );
    _logger.fine(
      '🔄 REASSEMBLE BYTES: Chunk is ${chunk.isBinary ? "BINARY (base64)" : "TEXT"}',
    );
    _logger.fine(
      '🔄 REASSEMBLE BYTES: Content length: ${chunk.content.length} chars',
    );

    _validateChunkMetadata(chunk);

    var assembly = _pendingMessages[messageId];
    if (assembly != null &&
        (assembly.totalChunks != chunk.totalChunks ||
            assembly.isBinary != chunk.isBinary)) {
      _discard(messageId);
      throw const FormatException('Conflicting fragment metadata');
    }

    if (assembly == null && _pendingMessages.length >= maxActiveAssemblies) {
      throw const FormatException('Too many active fragment assemblies');
    }

    final existingPart = assembly?.parts[chunk.chunkIndex];
    if (existingPart != null) {
      if (!_encodedPayloadCouldFit(chunk, existingPart.length)) {
        _discard(messageId);
        throw const FormatException('Conflicting duplicate fragment');
      }
    } else {
      final remainingMessageBytes =
          maxMessageBytes - (assembly?.retainedBytes ?? 0);
      if (!_encodedPayloadCouldFit(chunk, remainingMessageBytes)) {
        _discard(messageId);
        throw const FormatException('Fragment assembly exceeds message limit');
      }
      final remainingAggregateBytes = maxRetainedBytes - _retainedBytes;
      if (!_encodedPayloadCouldFit(chunk, remainingAggregateBytes)) {
        _discard(messageId);
        throw const FormatException('Fragment buffer exceeds aggregate limit');
      }
      if (_retainedFragments >= maxRetainedFragments) {
        _discard(messageId);
        throw const FormatException('Fragment buffer contains too many parts');
      }
    }

    Uint8List decodedPart;
    try {
      decodedPart = chunk.isBinary
          ? base64.decode(chunk.content)
          : Uint8List.fromList(utf8.encode(chunk.content));
    } on FormatException {
      _discard(messageId);
      throw const FormatException('Invalid fragment payload encoding');
    }

    if (decodedPart.isEmpty) {
      _discard(messageId);
      throw const FormatException('Fragment payload must not be empty');
    }

    if (assembly == null) {
      assembly = _PendingAssembly(
        totalChunks: chunk.totalChunks,
        isBinary: chunk.isBinary,
        createdAt: DateTime.now(),
      );
      _pendingMessages[messageId] = assembly;
      _logger.fine(
        '🔄 REASSEMBLE BYTES: Started tracking new message $messageId',
      );
    }

    if (existingPart != null) {
      if (_bytesEqual(existingPart, decodedPart)) return null;
      _discard(messageId);
      throw const FormatException('Conflicting duplicate fragment');
    }

    if (assembly.retainedBytes + decodedPart.length > maxMessageBytes) {
      _discard(messageId);
      throw const FormatException('Fragment assembly exceeds message limit');
    }
    if (_retainedBytes + decodedPart.length > maxRetainedBytes) {
      _discard(messageId);
      throw const FormatException('Fragment buffer exceeds aggregate limit');
    }

    assembly.parts[chunk.chunkIndex] = decodedPart;
    assembly.retainedBytes += decodedPart.length;
    _retainedBytes += decodedPart.length;
    _retainedFragments++;
    _logger.fine(
      '🔄 REASSEMBLE BYTES: Stored chunk ${chunk.chunkIndex}. Have ${assembly.parts.length}/${assembly.totalChunks} chunks',
    );

    // Check if we have all chunks
    if (assembly.parts.length == assembly.totalChunks) {
      _logger.fine(
        '🔄 REASSEMBLE BYTES✅: All ${assembly.totalChunks} chunks received! Starting reassembly',
      );
      final builder = BytesBuilder(copy: false);
      for (var i = 0; i < assembly.totalChunks; i++) {
        final part = assembly.parts[i];
        if (part == null) return null;
        builder.add(part);
      }
      final result = builder.takeBytes();
      _discard(messageId);
      _logger.fine(
        '🔄 REASSEMBLE BYTES✅: Total reassembled: ${result.length} bytes',
      );
      return result;
    }

    _logger.fine(
      '🔄 REASSEMBLE BYTES: Still waiting for more chunks (${assembly.parts.length}/${assembly.totalChunks})',
    );
    return null; // Still waiting for more chunks
  }

  void _validateChunkMetadata(MessageChunk chunk) {
    if (chunk.messageId.isEmpty || chunk.messageId.length > 256) {
      throw const FormatException('Invalid fragment message id');
    }
    if (chunk.totalChunks < 1 ||
        chunk.totalChunks > maxChunksPerMessage ||
        chunk.chunkIndex < 0 ||
        chunk.chunkIndex >= chunk.totalChunks) {
      throw const FormatException('Invalid fragment index metadata');
    }
    if (chunk.content.isEmpty) {
      throw const FormatException('Fragment payload must not be empty');
    }
  }

  bool _bytesEqual(Uint8List left, Uint8List right) {
    if (left.length != right.length) return false;
    for (var i = 0; i < left.length; i++) {
      if (left[i] != right[i]) return false;
    }
    return true;
  }

  bool _encodedPayloadCouldFit(MessageChunk chunk, int maxDecodedBytes) {
    if (maxDecodedBytes <= 0) return false;
    if (!chunk.isBinary) {
      var encodedBytes = 0;
      for (final rune in chunk.content.runes) {
        encodedBytes += rune <= 0x7f
            ? 1
            : rune <= 0x7ff
            ? 2
            : rune <= 0xffff
            ? 3
            : 4;
        if (encodedBytes > maxDecodedBytes) return false;
      }
      return true;
    }

    // Standard base64 needs at most four characters for every three decoded
    // bytes. Reject obviously oversized input before allocating its decoded
    // representation; malformed input is still rejected by base64.decode.
    final maxEncodedLength = ((maxDecodedBytes + 2) ~/ 3) * 4;
    return chunk.content.length <= maxEncodedLength;
  }

  void _discard(String messageId) {
    final assembly = _pendingMessages.remove(messageId);
    if (assembly == null) return;
    _retainedBytes -= assembly.retainedBytes;
    _retainedFragments -= assembly.parts.length;
    if (_retainedBytes < 0) _retainedBytes = 0;
    if (_retainedFragments < 0) _retainedFragments = 0;
  }

  static void _requirePositive(String name, int value) {
    if (value <= 0) {
      throw ArgumentError.value(value, name, 'must be greater than zero');
    }
  }

  // Clean up old partial messages (call periodically)
  void cleanupOldMessages({Duration timeout = const Duration(minutes: 2)}) {
    final now = DateTime.now();
    final expiredIds = _pendingMessages.entries
        .where((entry) => now.difference(entry.value.createdAt) >= timeout)
        .map((entry) => entry.key)
        .toList();

    for (final id in expiredIds) {
      _discard(id);
    }
  }
}

final class _PendingAssembly {
  _PendingAssembly({
    required this.totalChunks,
    required this.isBinary,
    required this.createdAt,
  });

  final int totalChunks;
  final bool isBinary;
  final DateTime createdAt;
  final Map<int, Uint8List> parts = {};
  int retainedBytes = 0;
}
