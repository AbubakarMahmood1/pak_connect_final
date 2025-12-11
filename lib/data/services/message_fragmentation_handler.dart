import 'dart:async';
import 'dart:typed_data';
import 'dart:convert';
import 'package:logging/logging.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../core/interfaces/i_message_fragmentation_handler.dart';
import '../../core/utils/message_fragmenter.dart';
import '../../core/models/protocol_message.dart';
import '../../domain/values/id_types.dart';
import '../../core/utils/binary_fragmenter.dart';

/// Handles message fragmentation, reassembly, and ACK management
///
/// Responsibilities:
/// - Detecting fragmented messages (multi-chunk format)
/// - Reassembling chunks into complete messages
/// - Managing ACK callbacks for delivery confirmation
/// - Timeout management for partial messages
/// - Periodic cleanup of stale reassembly state
class MessageFragmentationHandler implements IMessageFragmentationHandler {
  final _logger = Logger('MessageFragmentationHandler');
  static const String _verbosePrefKey = 'debug_verbose_fragments';
  static bool _verboseLogging = false;

  // Match BitChat-style fragment timeout (30s) for partial reassembly.
  static const Duration _fragmentTimeout = Duration(seconds: 30);
  static const int _binaryFragmentMagic = BinaryFragmenter.magic;
  static const int _ttlOffset = 1 + 8 + 2 + 2; // magic + fragId + idx + total

  String? _localNodeId;

  // Message fragmentation and reassembly
  final MessageReassembler _messageReassembler = MessageReassembler();
  final Map<String, ReassembledPayload> _completedMessages = {};
  final Map<String, _BinaryAccumulator> _binaryFragments = {};
  final Map<String, Uint8List> _forwardFragments = {};
  final Map<String, DateTime> _forwardTimestamps = {};
  final Map<String, Map<int, DateTime>> _seenFragmentParts = {};
  final Map<String, _BinaryAccumulator> _forwardBinaryBuffers = {};
  final Map<String, _ForwardReassembled> _forwardReassembled = {};

  // ACK management
  final Map<String, Timer> _messageTimeouts = {};
  final Map<String, Completer<bool>> _messageAcks = {};

  Timer? _cleanupTimer;
  bool _cleanupInProgress = false;

  MessageFragmentationHandler({bool enableCleanupTimer = false}) {
    // Setup periodic cleanup of old partial messages
    if (enableCleanupTimer) {
      _cleanupTimer ??= Timer.periodic(
        Duration(minutes: 2),
        (_) => cleanupOldMessages(),
      );
    }
    // Load persisted verbose flag so noisy fragment logs stay gated by default.
    unawaited(_configureVerboseLogging());
  }

  static Future<void> _configureVerboseLogging() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      setVerboseLogging(prefs.getBool(_verbosePrefKey) ?? false);
    } catch (_) {
      // If prefs are unavailable, keep default (muted).
    }
  }

  static void setVerboseLogging(bool enabled) {
    _verboseLogging = enabled;
  }

  bool get _isVerbose => _verboseLogging && _logger.isLoggable(Level.FINE);

  void _v(String message) {
    if (_isVerbose) {
      _logger.fine(message);
    }
  }

  /// Detects if raw bytes look like a fragmented message chunk
  ///
  /// Fragmented messages have format: id|idx|total|isBinary|content
  /// This method checks for 4+ pipe characters and valid ASCII-like content
  @override
  void setLocalNodeId(String nodeId) {
    _localNodeId = nodeId;
  }

  /// Legacy chunk-string detection
  bool looksLikeChunkString(Uint8List bytes) {
    final max = bytes.length < 128 ? bytes.length : 128;
    int pipes = 0;
    for (var i = 0; i < max; i++) {
      final b = bytes[i];
      if (b == 0x7C) pipes++; // '|'
      // Reject most control chars except TAB(9), LF(10), CR(13)
      if (b < 0x20 && b != 0x09 && b != 0x0A && b != 0x0D) return false;
      // Reject extended binary (our chunk strings are ASCII)
      if (b > 0x7E) return false;
    }
    return pipes >= 4; // id|idx|total|isBinary|content
  }

  /// Main entry point for processing received data from BLE
  ///
  /// Pipeline:
  /// 1. Skip single-byte pings
  /// 2. Check for direct protocol messages (non-fragmented)
  /// 3. Process fragmented chunks if applicable
  /// 4. Return complete message when all chunks received
  @override
  Future<String?> processReceivedData({
    required Uint8List data,
    required String fromDeviceId,
    required String fromNodeId,
  }) async {
    try {
      _v('📥 Processing ${data.length} bytes from BLE');

      // Binary fragment envelope (media/file path)
      if (data.isNotEmpty && data[0] == _binaryFragmentMagic) {
        final envelope = BinaryFragmentEnvelope.decode(data);
        if (envelope == null) {
          _v('📥 Binary fragment decode failed');
          return null;
        }

        // If recipient is specified and not us, do not reassemble here.
        final recipient = envelope.recipient;
        if (recipient != null &&
            recipient.isNotEmpty &&
            _localNodeId != null &&
            recipient != _localNodeId) {
          return _handleForwardFragment(
            envelope,
            fromDeviceId: fromDeviceId,
            fromNodeId: fromNodeId,
          );
        }

        final marker = _addBinaryFragment(envelope);
        return marker;
      }

      // Skip single-byte pings
      if (data.length == 1 && data[0] == 0x00) {
        _v('📥 Skipping single-byte ping');
        return null;
      }

      // Check for direct protocol messages (non-fragmented)
      try {
        final directMessage = String.fromCharCodes(data);
        if (ProtocolMessage.isProtocolMessage(directMessage)) {
          _v('📥 Detected direct protocol message (non-chunked)');
          // Signal that we found a direct message (not fragmented)
          // The caller will handle the actual processing
          return 'DIRECT_PROTOCOL_MESSAGE'; // Marker to indicate fragment handler completes
        }
      } catch (e) {
        // Not a direct message, try chunk processing
        _v(
          '📥 Not a direct protocol message, checking for fragments: $e',
        );
      }

      // Process as message chunk ONLY if it looks like chunk format
      if (looksLikeChunkString(data)) {
        try {
          _v('📥 Parsing as MessageChunk');
          final chunk = MessageChunk.fromBytes(data);
          _v(
            '📥 Parsed chunk: ${chunk.messageId}|${chunk.chunkIndex}|${chunk.totalChunks}',
          );

          // If we already completed this messageId recently, drop duplicates
          if (_completedMessages.containsKey(chunk.messageId)) {
            _v(
              '📥 Dropping chunk for already-completed message ${chunk.messageId}',
            );
            return null;
          }

          // Add chunk to reassembler
          final completeMessageBytes = _messageReassembler.addChunkBytes(chunk);
          _v(
            '📥 Reassembler: ${completeMessageBytes != null ? "MESSAGE COMPLETE ✅" : "waiting for more chunks ⏳"}',
          );

          if (completeMessageBytes != null) {
            _v(
              '📥 Processing complete message (${completeMessageBytes.length} bytes)',
            );
            _completedMessages[chunk.messageId] = ReassembledPayload(
              bytes: completeMessageBytes,
              receivedAt: DateTime.now(),
              isBinary: false,
              originalType: null,
              ttl: 0,
            );
            // Return complete message marker with length
            // Caller will reconstruct from reassembler
            return 'REASSEMBLY_COMPLETE:${chunk.messageId}';
          }
        } catch (e) {
          _logger.warning('Chunk processing failed: $e');
        }
      } else {
        _v('📥 Not a chunk-string payload');
        return null;
      }
    } catch (e) {
      _logger.severe('Error processing received data: $e');
    }

    return null;
  }

  /// Registers an ACK callback for a specific message
  @override
  Future<bool> registerMessageAck({
    required String messageId,
    required Duration timeout,
  }) async {
    final completer = Completer<bool>();
    _messageAcks[messageId] = completer;

    // Start timeout timer
    _messageTimeouts[messageId] = Timer(timeout, () {
      if (!completer.isCompleted) {
        completer.complete(false);
        _messageAcks.remove(messageId);
        _messageTimeouts.remove(messageId);
        _logger.warning('⏱️ ACK timeout for message: $messageId');
      }
    });

    try {
      return await completer.future;
    } finally {
      // Cleanup
      _messageTimeouts[messageId]?.cancel();
      _messageTimeouts.remove(messageId);
    }
  }

  @override
  Future<bool> registerMessageAckWithId({
    required MessageId messageId,
    required Duration timeout,
  }) => registerMessageAck(messageId: messageId.value, timeout: timeout);

  /// Acknowledges successful message receipt
  @override
  void acknowledgeMessage(String messageId) {
    final completer = _messageAcks[messageId];
    if (completer != null && !completer.isCompleted) {
      completer.complete(true);
      _messageAcks.remove(messageId);
      _messageTimeouts[messageId]?.cancel();
      _messageTimeouts.remove(messageId);
      _v('✅ ACK received for message: $messageId');
    }
  }

  @override
  void acknowledgeMessageWithId(MessageId messageId) =>
      acknowledgeMessage(messageId.value);

  /// Gets current reassembly state for debugging
  @override
  Map<String, int> getReassemblyState() {
    // Get state from reassembler
    // This would require a getter in MessageReassembler
    return {};
  }

  /// Retrieves and removes completed reassembled message bytes by ID.
  Uint8List? takeReassembledMessageBytes(String messageId) {
    final completed = _completedMessages.remove(messageId);
    if (completed == null) {
      _v('📥 No completed message found for id: $messageId');
      return null;
    }

    return completed.bytes;
  }

  /// Retrieves and removes completed payload with metadata.
  ReassembledPayload? takeReassembledPayload(String messageId) {
    return _completedMessages.remove(messageId);
  }

  @override
  Uint8List? takeForwardFragment(String fragmentId, int index) {
    final key = '$fragmentId:$index';
    _forwardTimestamps.remove(key);
    return _forwardFragments.remove(key);
  }

  @override
  ForwardReassembledPayload? takeForwardReassembledPayload(String fragmentId) {
    final result = _forwardReassembled.remove(fragmentId);
    if (result == null) return null;
    return ForwardReassembledPayload(
      bytes: result.bytes,
      originalType: result.originalType,
      recipient: result.recipient,
      ttl: result.ttl,
    );
  }

  /// Cleans up old partial messages that have timed out
  @override
  void cleanupOldMessages() {
    if (_cleanupInProgress) return;
    _cleanupInProgress = true;
    try {
      _messageReassembler.cleanupOldMessages(timeout: _fragmentTimeout);
      final cutoff = DateTime.now().subtract(_fragmentTimeout);
      _completedMessages.removeWhere(
        (_, completed) => completed.receivedAt.isBefore(cutoff),
      );
      _binaryFragments.removeWhere(
        (_, frag) => frag.startedAt.isBefore(cutoff),
      );
      _forwardBinaryBuffers.removeWhere(
        (_, frag) => frag.startedAt.isBefore(cutoff),
      );
      _forwardReassembled.removeWhere(
        (_, payload) => payload.receivedAt.isBefore(cutoff),
      );
      _forwardFragments.removeWhere(
        (key, _) => (_forwardTimestamps[key]?.isBefore(cutoff) ?? true),
      );
      _forwardTimestamps.removeWhere((_, ts) => ts.isBefore(cutoff));
      _seenFragmentParts.removeWhere((_, map) {
        map.removeWhere((_, ts) => ts.isBefore(cutoff));
        return map.isEmpty;
      });
      _v('🧹 Cleaned up old partial messages');
    } finally {
      _cleanupInProgress = false;
    }
  }

  /// Disposes resources (timers, etc.)
  @override
  void dispose() {
    _cleanupTimer?.cancel();

    // Cancel all pending ACK timers
    for (var timer in _messageTimeouts.values) {
      timer.cancel();
    }
    _messageTimeouts.clear();

    // Complete any pending ACK completers
    for (var completer in _messageAcks.values) {
      if (!completer.isCompleted) {
        completer.completeError('Handler disposed');
      }
    }
    _messageAcks.clear();

    _completedMessages.clear();
    _binaryFragments.clear();

    _logger.info('🔌 MessageFragmentationHandler disposed');
  }
}

class _BinaryAccumulator {
  _BinaryAccumulator({
    required this.fragmentId,
    required this.total,
    required this.originalType,
    required this.recipient,
    required this.ttl,
    required this.startedAt,
  });

  final String fragmentId;
  final int total;
  final int originalType;
  final String? recipient;
  int ttl;
  final DateTime startedAt;
  final Map<int, Uint8List> parts = {};
}

class _ForwardReassembled {
  _ForwardReassembled({
    required this.bytes,
    required this.originalType,
    required this.recipient,
    required this.ttl,
    required this.receivedAt,
  });

  final Uint8List bytes;
  final int originalType;
  final String? recipient;
  final int ttl;
  final DateTime receivedAt;
}

class BinaryFragmentEnvelope {
  BinaryFragmentEnvelope({
    required this.fragmentId,
    required this.index,
    required this.total,
    required this.ttl,
    required this.originalType,
    this.recipient,
    required this.data,
    required this.raw,
  });

  final String fragmentId;
  final int index;
  final int total;
  final int ttl;
  final int originalType;
  final String? recipient; // null/empty => broadcast/unknown
  final Uint8List data;
  final Uint8List raw;

  static BinaryFragmentEnvelope? decode(Uint8List bytes) {
    try {
      if (bytes.isEmpty || bytes[0] != BinaryFragmenter.magic) return null;
      if (bytes.length < 1 + 8 + 2 + 2 + 1 + 1 + 1) return null;
      int offset = 1;
      final fragIdBytes = bytes.sublist(offset, offset + 8);
      offset += 8;
      final fragmentId = fragIdBytes
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join();

      // Header is 4 bytes: 2 bytes index + 2 bytes total, big endian.
      if (offset + 4 > bytes.length) return null;
      final bd = ByteData.sublistView(bytes, offset, offset + 4);
      final index = bd.getUint16(0, Endian.big);
      final total = bd.getUint16(2, Endian.big);
      offset += 4;

      final ttl = bytes[offset];
      offset += 1;

      final originalType = bytes[offset];
      offset += 1;

      final recipientLen = bytes[offset];
      offset += 1;
      String? recipient;
      if (recipientLen > 0) {
        if (offset + recipientLen > bytes.length) return null;
        recipient = utf8.decode(bytes.sublist(offset, offset + recipientLen));
        offset += recipientLen;
      }

      if (offset > bytes.length) return null;
      final data = bytes.sublist(offset);

      return BinaryFragmentEnvelope(
        fragmentId: fragmentId,
        index: index,
        total: total,
        ttl: ttl,
        originalType: originalType,
        recipient: recipient,
        data: data,
        raw: bytes,
      );
    } catch (_) {
      return null;
    }
  }
}

// Binary fragment reassembly for media/file transfer
extension on MessageFragmentationHandler {
  String? _handleForwardFragment(
    BinaryFragmentEnvelope env, {
    required String fromDeviceId,
    required String fromNodeId,
  }) {
    final now = DateTime.now();
    final key = '${env.fragmentId}:${env.index}';
    final seenForId = _seenFragmentParts.putIfAbsent(env.fragmentId, () => {});
    final seenTs = seenForId[env.index];
    if (seenTs != null &&
        now.difference(seenTs) <=
            MessageFragmentationHandler._fragmentTimeout) {
      _v('📥 Duplicate binary fragment (forward) $key');
      return null;
    }

    if (env.ttl <= 1) {
      _v('📥 Dropping binary fragment $key due to TTL exhaustion');
      seenForId[env.index] = now;
      return null;
    }

    final forwarded = Uint8List.fromList(env.raw);
    forwarded[MessageFragmentationHandler._ttlOffset] = (env.ttl - 1) & 0xFF;
    _forwardFragments[key] = forwarded;
    _forwardTimestamps[key] = now;
    seenForId[env.index] = now;

    // Opportunistically buffer for full reassembly if downstream MTU adaptation is needed.
    final acc = _forwardBinaryBuffers.putIfAbsent(
      env.fragmentId,
      () => _BinaryAccumulator(
        fragmentId: env.fragmentId,
        total: env.total,
        originalType: env.originalType,
        recipient: env.recipient,
        ttl: env.ttl,
        startedAt: now,
      ),
    );
    acc.ttl = acc.ttl < env.ttl ? acc.ttl : env.ttl;
    acc.parts[env.index] = env.data;
    if (acc.parts.length == acc.total) {
      final ordered = <int>[];
      var missingPart = false;
      for (var i = 0; i < acc.total; i++) {
        final part = acc.parts[i];
        if (part == null) {
          missingPart = true;
          break;
        }
        ordered.addAll(part);
      }
      if (!missingPart) {
        _forwardBinaryBuffers.remove(env.fragmentId);
        _forwardReassembled[env.fragmentId] = _ForwardReassembled(
          bytes: Uint8List.fromList(ordered),
          originalType: acc.originalType,
          recipient: acc.recipient,
          ttl: acc.ttl,
          receivedAt: DateTime.now(),
        );
        _v(
          '📦 Forward reassembly complete for ${env.fragmentId} (type=${acc.originalType})',
        );
      }
    }

    _v('📤 Forwarding binary fragment $key (ttl -> ${env.ttl - 1})');
    return 'FORWARD_BIN:$key:$fromDeviceId:$fromNodeId';
  }

  String? _addBinaryFragment(BinaryFragmentEnvelope env) {
    final now = DateTime.now();
    final seenForId = _seenFragmentParts.putIfAbsent(env.fragmentId, () => {});
    final seenTs = seenForId[env.index];
    if (seenTs != null &&
        now.difference(seenTs) <=
            MessageFragmentationHandler._fragmentTimeout) {
      _v(
        '📥 Duplicate binary fragment ${env.index} for ${env.fragmentId}',
      );
      return null;
    }
    seenForId[env.index] = now;

    final acc = _binaryFragments.putIfAbsent(
      env.fragmentId,
      () => _BinaryAccumulator(
        fragmentId: env.fragmentId,
        total: env.total,
        originalType: env.originalType,
        recipient: env.recipient,
        ttl: env.ttl,
        startedAt: DateTime.now(),
      ),
    );

    if (acc.parts.containsKey(env.index)) {
      _v(
        '📥 Duplicate binary fragment ${env.index} for ${env.fragmentId}',
      );
      return null;
    }

    acc.parts[env.index] = env.data;
    acc.ttl = acc.ttl < env.ttl ? acc.ttl : env.ttl;
    _v(
      '📥 Stored binary fragment ${env.index}/${acc.total - 1} for ${env.fragmentId} (have ${acc.parts.length}/${acc.total})',
    );

    if (acc.parts.length == acc.total) {
      final ordered = <int>[];
      for (var i = 0; i < acc.total; i++) {
        final part = acc.parts[i];
        if (part == null) return null;
        ordered.addAll(part);
      }
      _binaryFragments.remove(env.fragmentId);
      _completedMessages[env.fragmentId] = ReassembledPayload(
        bytes: Uint8List.fromList(ordered),
        receivedAt: DateTime.now(),
        isBinary: true,
        originalType: env.originalType,
        recipient: env.recipient,
        ttl: 0, // Explicitly suppress relay after local delivery.
        suppressForwarding: true,
      );
      _v('📦 Binary reassembly complete for ${env.fragmentId}');
      return 'REASSEMBLY_COMPLETE_BIN:${env.fragmentId}:${env.originalType}';
    }

    return null;
  }
}
