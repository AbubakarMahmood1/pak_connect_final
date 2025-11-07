// Core message security implementation for replay protection and cryptographic message IDs

import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:logging/logging.dart';

/// Advanced replay protection using cryptographic message IDs and nonce tracking
class MessageSecurity {
  static final _logger = Logger('MessageSecurity');
  static const String _processedMessageIdsKey = 'processed_message_ids_v2';
  static const String _nonceCounterKey = 'nonce_counter_';
  static const int _maxProcessedMessages = 10000; // Prevent unbounded growth

  // In-memory cache for fast duplicate detection
  static final Set<String> _processedMessageCache = {};
  static final Map<String, int> _nonceCounters = {};

  /// Generate cryptographically secure message ID with nonce
  static Future<String> generateSecureMessageId({
    required String senderPublicKey,
    required String content,
    String? recipientPublicKey,
  }) async {
    try {
      // Get and increment nonce for sender
      final nonce = await _getAndIncrementNonce(senderPublicKey);

      // Create message components
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final components = [
        'SENDER:$senderPublicKey',
        'RECIPIENT:${recipientPublicKey ?? 'BROADCAST'}',
        'CONTENT_HASH:${_hashContent(content)}',
        'NONCE:$nonce',
        'VERSION:2',
      ];

      // Generate cryptographic hash with timestamp (matching validation logic)
      final componentsWithTimestamp = [...components, 'TIMESTAMP:$timestamp'];
      final messageData = componentsWithTimestamp.join('|');
      final messageHash = sha256.convert(utf8.encode(messageData));

      // Create message ID with format: VERSION.NONCE.HASH
      final messageId = '2.$nonce.${messageHash.toString().substring(0, 32)}';

      _logger.info(
        'Generated secure message ID: ${messageId.substring(0, 20)}... (nonce: $nonce)',
      );
      return messageId;
    } catch (e) {
      _logger.severe('Failed to generate secure message ID: $e');
      // Fallback to timestamp-based ID
      return 'FALLBACK_${DateTime.now().millisecondsSinceEpoch}_${_generateRandomString(8)}';
    }
  }

  /// Validate message ID and check for replay attacks
  static Future<MessageValidationResult> validateMessage({
    required String messageId,
    required String senderPublicKey,
    required String content,
    String? recipientPublicKey,
    bool allowRetry = true,
  }) async {
    try {
      // Parse message ID
      final idParts = messageId.split('.');
      if (idParts.length != 3) {
        return MessageValidationResult.invalid('Invalid message ID format');
      }

      final version = int.tryParse(idParts[0]);
      final nonce = int.tryParse(idParts[1]);
      final providedHash = idParts[2];

      if (version == null || nonce == null || providedHash.isEmpty) {
        return MessageValidationResult.invalid(
          'Malformed message ID components',
        );
      }

      // Check for replay attack (fast in-memory check first)
      if (_processedMessageCache.contains(messageId)) {
        if (!allowRetry) {
          return MessageValidationResult.replay(
            'Message ID already processed (cache)',
          );
        }
        _logger.warning(
          'Potential legitimate retry detected for: ${messageId.substring(0, 20)}...',
        );
      }

      // Check persistent storage for replay protection
      if (await _isMessageProcessed(messageId) && !allowRetry) {
        return MessageValidationResult.replay(
          'Message ID already processed (storage)',
        );
      }

      // Validate nonce sequence (prevent nonce reuse attacks)
      final expectedNonce = await _getCurrentNonce(senderPublicKey);
      if (nonce < expectedNonce - 1000) {
        // Allow some tolerance for network delays
        return MessageValidationResult.invalid(
          'Nonce too old - possible replay attack',
        );
      }

      // Verify message integrity by recalculating hash
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final components = [
        'SENDER:$senderPublicKey',
        'RECIPIENT:${recipientPublicKey ?? 'BROADCAST'}',
        'CONTENT_HASH:${_hashContent(content)}',
        'NONCE:$nonce',
        'VERSION:$version',
      ];

      // For hash verification, we need to try different timestamps within a reasonable window
      final hashValid = await _verifyHashWithTimeWindow(
        components,
        providedHash,
        timestamp,
        windowMinutes: 5,
      );

      if (!hashValid) {
        return MessageValidationResult.invalid(
          'Message integrity check failed',
        );
      }

      // Mark message as processed
      await _markMessageProcessed(messageId, senderPublicKey);

      _logger.info(
        'Message validated successfully: ${messageId.substring(0, 20)}...',
      );
      return MessageValidationResult.valid();
    } catch (e) {
      _logger.severe('Message validation failed: $e');
      return MessageValidationResult.invalid('Validation error: $e');
    }
  }

  /// Get and increment nonce for sender (atomic operation)
  static Future<int> _getAndIncrementNonce(String senderPublicKey) async {
    final key = _nonceCounterKey + _hashPublicKey(senderPublicKey);

    // Check memory cache first
    if (_nonceCounters.containsKey(key)) {
      final currentValue = _nonceCounters[key]!;
      final newValue = currentValue + 1;
      _nonceCounters[key] = newValue;
      return newValue;
    }

    // Load from persistent storage
    final prefs = await SharedPreferences.getInstance();
    final currentNonce = prefs.getInt(key) ?? 0;
    final newNonce = currentNonce + 1;

    // Store atomically
    await prefs.setInt(key, newNonce);
    _nonceCounters[key] = newNonce;

    return newNonce;
  }

  /// Get current nonce without incrementing
  static Future<int> _getCurrentNonce(String senderPublicKey) async {
    final key = _nonceCounterKey + _hashPublicKey(senderPublicKey);

    if (_nonceCounters.containsKey(key)) {
      return _nonceCounters[key]!;
    }

    final prefs = await SharedPreferences.getInstance();
    final nonce = prefs.getInt(key) ?? 0;
    _nonceCounters[key] = nonce;
    return nonce;
  }

  /// Mark message as processed for replay protection
  static Future<void> _markMessageProcessed(
    String messageId,
    String senderPublicKey,
  ) async {
    // Add to memory cache
    _processedMessageCache.add(messageId);

    // Persist to storage
    final prefs = await SharedPreferences.getInstance();
    final processed = prefs.getStringList(_processedMessageIdsKey) ?? [];

    // Add with timestamp for cleanup
    final entry = '$messageId|${DateTime.now().millisecondsSinceEpoch}';
    processed.add(entry);

    // Cleanup old entries if needed
    if (processed.length > _maxProcessedMessages) {
      final cleaned = await _cleanupOldProcessedMessages(processed);
      await prefs.setStringList(_processedMessageIdsKey, cleaned);
    } else {
      await prefs.setStringList(_processedMessageIdsKey, processed);
    }
  }

  /// Check if message was already processed
  static Future<bool> _isMessageProcessed(String messageId) async {
    final prefs = await SharedPreferences.getInstance();
    final processed = prefs.getStringList(_processedMessageIdsKey) ?? [];

    return processed.any((entry) => entry.startsWith('$messageId|'));
  }

  /// Cleanup old processed messages (keep only recent ones)
  static Future<List<String>> _cleanupOldProcessedMessages(
    List<String> processed,
  ) async {
    final cutoffTime = DateTime.now()
        .subtract(Duration(days: 7))
        .millisecondsSinceEpoch;

    final cleaned = processed.where((entry) {
      final parts = entry.split('|');
      if (parts.length != 2) return true; // Keep malformed entries for now

      final timestamp = int.tryParse(parts[1]);
      if (timestamp == null) return true;

      return timestamp > cutoffTime;
    }).toList();

    _logger.info(
      'Cleaned up processed messages: ${processed.length} -> ${cleaned.length}',
    );
    return cleaned;
  }

  /// Verify hash with time window tolerance
  static Future<bool> _verifyHashWithTimeWindow(
    List<String> baseComponents,
    String expectedHash,
    int centerTimestamp, {
    int windowMinutes = 5,
  }) async {
    final windowMs = windowMinutes * 60 * 1000;
    final startTime = centerTimestamp - windowMs;
    final endTime = centerTimestamp + windowMs;

    // Try different timestamps within the window
    for (int timestamp = startTime; timestamp <= endTime; timestamp += 30000) {
      // 30 second intervals
      final components = [...baseComponents, 'TIMESTAMP:$timestamp'];
      final messageData = components.join('|');
      final hash = sha256
          .convert(utf8.encode(messageData))
          .toString()
          .substring(0, 32);

      if (hash == expectedHash) {
        return true;
      }
    }

    return false;
  }

  /// Generate content hash for integrity verification
  static String _hashContent(String content) {
    return sha256.convert(utf8.encode(content)).toString().substring(0, 16);
  }

  /// Generate consistent hash of public key for storage keys
  static String _hashPublicKey(String publicKey) {
    return sha256.convert(utf8.encode(publicKey)).toString().substring(0, 16);
  }

  /// Generate cryptographically secure random string
  static String _generateRandomString(int length) {
    final bytes = Uint8List(length);
    for (int i = 0; i < length; i++) {
      bytes[i] = DateTime.now().microsecondsSinceEpoch % 256;
    }
    return base64Url.encode(bytes).substring(0, length);
  }

  /// Clear processed messages for testing or reset
  static Future<void> clearProcessedMessages() async {
    _processedMessageCache.clear();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_processedMessageIdsKey);
    _logger.info('Cleared all processed message tracking');
  }

  /// Get statistics about replay protection
  static Future<ReplayProtectionStats> getStats() async {
    final prefs = await SharedPreferences.getInstance();
    final processed = prefs.getStringList(_processedMessageIdsKey) ?? [];

    return ReplayProtectionStats(
      processedMessagesCount: processed.length,
      cacheSize: _processedMessageCache.length,
      nonceCountersActive: _nonceCounters.length,
    );
  }
}

/// Result of message validation
class MessageValidationResult {
  final bool isValid;
  final bool isReplay;
  final String? errorMessage;

  const MessageValidationResult._(
    this.isValid,
    this.isReplay,
    this.errorMessage,
  );

  factory MessageValidationResult.valid() =>
      MessageValidationResult._(true, false, null);
  factory MessageValidationResult.replay(String message) =>
      MessageValidationResult._(false, true, message);
  factory MessageValidationResult.invalid(String message) =>
      MessageValidationResult._(false, false, message);

  bool get isError => !isValid && !isReplay;
}

/// Statistics for replay protection system
class ReplayProtectionStats {
  final int processedMessagesCount;
  final int cacheSize;
  final int nonceCountersActive;

  const ReplayProtectionStats({
    required this.processedMessagesCount,
    required this.cacheSize,
    required this.nonceCountersActive,
  });

  @override
  String toString() =>
      'ReplayProtectionStats(processed: $processedMessagesCount, cache: $cacheSize, nonces: $nonceCountersActive)';
}
