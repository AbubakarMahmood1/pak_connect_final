// Multi-layer spam prevention system for mesh relay protection
// Implements rate limiting, trust scoring, and size/hop validation

import 'dart:async';
import 'dart:convert';
import 'package:logging/logging.dart';
import 'package:meta/meta.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/mesh_relay_models.dart';
import 'package:pak_connect/core/utils/string_extensions.dart';

/// Comprehensive spam prevention for mesh relay operations
class SpamPreventionManager {
  static final _logger = Logger('SpamPreventionManager');

  // Rate limiting constants
  static const int maxRelaysPerHour = 50;
  static const int maxRelaysPerSenderPerHour = 10;
  static const int maxMessageSizeBytes = 10240; // 10KB
  static const int maxHopCount = 25; // Prevent artificially inflated TTL
  static const double spamScoreThreshold = 0.7;

  // Storage keys
  static const String _trustScoreKey = 'spam_prevention_trust_score_v1';
  static const String _messageHashKey = 'spam_prevention_message_hashes_v1';

  // In-memory tracking for performance
  final Map<String, List<int>> _hourlyRelayCount = {};
  final Map<String, double> _trustScores = {};
  final Set<String> _processedHashes = {};
  final Map<String, RelayOperation> _recentOperations = {};
  bool _bypassChecksForTests = false;
  static bool _globalBypassForTests = false;

  // Statistics
  int _totalBlocked = 0;
  int _totalAllowed = 0;
  double _averageSpamScore = 0.0;

  // Cleanup timer
  Timer? _cleanupTimer;

  /// Initialize spam prevention system
  Future<void> initialize() async {
    await _loadPersistentData();
    _startPeriodicCleanup();
    _logger.info('SpamPreventionManager initialized');
  }

  /// Check if incoming relay message should be allowed
  Future<SpamCheckResult> checkIncomingRelay({
    required MeshRelayMessage relayMessage,
    required String fromNodeId,
    required String currentNodeId,
  }) async {
    if (_bypassChecksForTests || _globalBypassForTests) {
      return const SpamCheckResult(
        allowed: true,
        spamScore: 0,
        reason: 'Testing bypass enabled',
        checks: [],
      );
    }
    try {
      final checks = <SpamCheck>[];
      double totalSpamScore = 0.0;

      // 1. Rate limiting check
      final rateLimitCheck = await _checkRateLimit(fromNodeId);
      checks.add(rateLimitCheck);
      totalSpamScore += rateLimitCheck.spamScore;

      // 2. Message size check
      final sizeCheck = _checkMessageSize(relayMessage);
      checks.add(sizeCheck);
      totalSpamScore += sizeCheck.spamScore;

      // 3. Hop count validation
      final hopCheck = _checkHopCount(relayMessage.relayMetadata);
      checks.add(hopCheck);
      totalSpamScore += hopCheck.spamScore;

      // 4. Duplicate message detection
      final duplicateCheck = await _checkDuplicate(
        relayMessage.relayMetadata.messageHash,
      );
      checks.add(duplicateCheck);
      totalSpamScore += duplicateCheck.spamScore;

      // 5. Trust score evaluation
      final trustCheck = await _checkTrustScore(fromNodeId);
      checks.add(trustCheck);
      totalSpamScore += trustCheck.spamScore;

      // 6. Loop detection
      final loopCheck = _checkLoop(relayMessage.relayMetadata, currentNodeId);
      checks.add(loopCheck);
      totalSpamScore += loopCheck.spamScore;

      // Calculate average spam score
      final averageScore = totalSpamScore / checks.length;

      // Determine if message should be allowed
      final allowed =
          averageScore < spamScoreThreshold &&
          checks.every((check) => check.passed);

      // Update statistics
      if (allowed) {
        _totalAllowed++;
        await _updateTrustScore(fromNodeId, improve: true);
      } else {
        _totalBlocked++;
        await _updateTrustScore(fromNodeId, improve: false);
      }

      _averageSpamScore = (_averageSpamScore + averageScore) / 2;

      // Record the operation
      _recentOperations[relayMessage.relayMetadata.messageHash] =
          RelayOperation(
            messageHash: relayMessage.relayMetadata.messageHash,
            fromNodeId: fromNodeId,
            timestamp: DateTime.now(),
            allowed: allowed,
            spamScore: averageScore,
          );

      final result = SpamCheckResult(
        allowed: allowed,
        spamScore: averageScore,
        reason: allowed ? 'Message allowed' : _getBlockReason(checks),
        checks: checks,
      );

      if (!allowed) {
        _logger.warning(
          'Blocked relay from ${fromNodeId.shortId(8)}...: ${result.reason} (score: ${averageScore.toStringAsFixed(3)})',
        );
      }

      return result;
    } catch (e) {
      _logger.severe('Error in spam check: $e');
      _totalBlocked++;
      return SpamCheckResult(
        allowed: false,
        spamScore: 1.0,
        reason: 'Spam check error: $e',
        checks: [],
      );
    }
  }

  /// Check if outgoing relay should be allowed
  Future<SpamCheckResult> checkOutgoingRelay({
    required String senderNodeId,
    required int messageSize,
  }) async {
    if (_bypassChecksForTests || _globalBypassForTests) {
      return const SpamCheckResult(
        allowed: true,
        spamScore: 0,
        reason: 'Testing bypass enabled',
        checks: [],
      );
    }
    try {
      final checks = <SpamCheck>[];
      double totalSpamScore = 0.0;

      // 1. Rate limiting check for outgoing
      final rateLimitCheck = await _checkRateLimit(senderNodeId);
      checks.add(rateLimitCheck);
      totalSpamScore += rateLimitCheck.spamScore;

      // 2. Message size check
      final sizeCheck = _checkOutgoingMessageSize(messageSize);
      checks.add(sizeCheck);
      totalSpamScore += sizeCheck.spamScore;

      final averageScore = totalSpamScore / checks.length;
      final allowed = averageScore < spamScoreThreshold;

      return SpamCheckResult(
        allowed: allowed,
        spamScore: averageScore,
        reason: allowed ? 'Outgoing relay allowed' : 'Outgoing relay blocked',
        checks: checks,
      );
    } catch (e) {
      _logger.severe('Error checking outgoing relay: $e');
      return SpamCheckResult(
        allowed: false,
        spamScore: 1.0,
        reason: 'Outgoing check error: $e',
        checks: [],
      );
    }
  }

  @visibleForTesting
  void bypassAllChecksForTests({bool enable = true}) {
    _bypassChecksForTests = enable;
  }

  @visibleForTesting
  static void bypassAllInstancesForTests({bool enable = true}) {
    _globalBypassForTests = enable;
  }

  /// Record successful relay operation for trust building
  Future<void> recordRelayOperation({
    required String fromNodeId,
    required String toNodeId,
    required String messageHash,
    required int messageSize,
  }) async {
    try {
      // Update rate limiting counters
      await _incrementRelayCount(fromNodeId);

      // Mark message hash as processed
      _processedHashes.add(messageHash);

      // Update trust score positively for successful relay
      await _updateTrustScore(fromNodeId, improve: true);
      await _updateTrustScore(toNodeId, improve: true);

      _logger.fine(
        'Recorded relay operation: ${fromNodeId.shortId(8)}... -> ${toNodeId.shortId(8)}...',
      );
    } catch (e) {
      _logger.warning('Failed to record relay operation: $e');
    }
  }

  /// Get spam prevention statistics
  SpamPreventionStatistics getStatistics() {
    final total = _totalAllowed + _totalBlocked;
    return SpamPreventionStatistics(
      totalAllowed: _totalAllowed,
      totalBlocked: _totalBlocked,
      blockRate: total > 0 ? _totalBlocked / total : 0.0,
      averageSpamScore: _averageSpamScore,
      activeTrustScores: _trustScores.length,
      processedHashes: _processedHashes.length,
    );
  }

  /// Clear statistics (for testing)
  void clearStatistics() {
    _totalAllowed = 0;
    _totalBlocked = 0;
    _averageSpamScore = 0.0;
    _hourlyRelayCount.clear();
    _processedHashes.clear();
    _recentOperations.clear();
  }

  /// Dispose resources
  void dispose() {
    _cleanupTimer?.cancel();
    _logger.info('SpamPreventionManager disposed');
  }

  // Private methods

  /// Check rate limiting for a node
  Future<SpamCheck> _checkRateLimit(String nodeId) async {
    final now = DateTime.now();
    final hourlyKey =
        '${nodeId}_${now.hour}_${now.day}_${now.month}_${now.year}';

    final relayCount = _hourlyRelayCount[hourlyKey]?.length ?? 0;

    if (relayCount >= maxRelaysPerSenderPerHour) {
      return SpamCheck(
        type: SpamCheckType.rateLimit,
        passed: false,
        spamScore: 1.0,
        message: 'Rate limit exceeded: $relayCount/$maxRelaysPerSenderPerHour',
      );
    }

    final spamScore = relayCount / maxRelaysPerSenderPerHour;
    return SpamCheck(
      type: SpamCheckType.rateLimit,
      passed: true,
      spamScore: spamScore,
      message: 'Rate limit OK: $relayCount/$maxRelaysPerSenderPerHour',
    );
  }

  /// Check message size limits
  SpamCheck _checkMessageSize(MeshRelayMessage relayMessage) {
    final size = relayMessage.messageSize;

    if (size > maxMessageSizeBytes) {
      return SpamCheck(
        type: SpamCheckType.messageSize,
        passed: false,
        spamScore: 1.0,
        message: 'Message too large: ${size}B > ${maxMessageSizeBytes}B',
      );
    }

    final spamScore = size / maxMessageSizeBytes;
    return SpamCheck(
      type: SpamCheckType.messageSize,
      passed: true,
      spamScore: spamScore,
      message: 'Size OK: ${size}B',
    );
  }

  /// Check outgoing message size
  SpamCheck _checkOutgoingMessageSize(int size) {
    if (size > maxMessageSizeBytes) {
      return SpamCheck(
        type: SpamCheckType.messageSize,
        passed: false,
        spamScore: 1.0,
        message: 'Outgoing message too large: ${size}B',
      );
    }

    final spamScore = size / maxMessageSizeBytes;
    return SpamCheck(
      type: SpamCheckType.messageSize,
      passed: true,
      spamScore: spamScore,
      message: 'Outgoing size OK: ${size}B',
    );
  }

  /// Check hop count validity
  SpamCheck _checkHopCount(RelayMetadata metadata) {
    if (metadata.hopCount > maxHopCount) {
      return SpamCheck(
        type: SpamCheckType.hopCount,
        passed: false,
        spamScore: 1.0,
        message: 'Hop count too high: ${metadata.hopCount}',
      );
    }

    if (metadata.hopCount >= metadata.ttl) {
      return SpamCheck(
        type: SpamCheckType.hopCount,
        passed: false,
        spamScore: 1.0,
        message: 'TTL exceeded: ${metadata.hopCount}/${metadata.ttl}',
      );
    }

    final spamScore = metadata.hopCount / maxHopCount;
    return SpamCheck(
      type: SpamCheckType.hopCount,
      passed: true,
      spamScore: spamScore,
      message: 'Hop count OK: ${metadata.hopCount}/${metadata.ttl}',
    );
  }

  /// Check for duplicate messages
  Future<SpamCheck> _checkDuplicate(String messageHash) async {
    if (_processedHashes.contains(messageHash)) {
      return SpamCheck(
        type: SpamCheckType.duplicate,
        passed: false,
        spamScore: 1.0,
        message: 'Duplicate message hash',
      );
    }

    return SpamCheck(
      type: SpamCheckType.duplicate,
      passed: true,
      spamScore: 0.0,
      message: 'New message hash',
    );
  }

  /// Check trust score for node
  Future<SpamCheck> _checkTrustScore(String nodeId) async {
    final trustScore = _trustScores[nodeId] ?? 0.5; // Default neutral trust

    // Lower trust score = higher spam score (inverted)
    final spamScore = 1.0 - trustScore;

    return SpamCheck(
      type: SpamCheckType.trustScore,
      passed: trustScore > 0.3, // Require minimum trust
      spamScore: spamScore,
      message: 'Trust score: ${trustScore.toStringAsFixed(3)}',
    );
  }

  /// Check for routing loops
  SpamCheck _checkLoop(RelayMetadata metadata, String currentNodeId) {
    if (metadata.hasNodeInPath(currentNodeId)) {
      return SpamCheck(
        type: SpamCheckType.loop,
        passed: false,
        spamScore: 1.0,
        message: 'Loop detected: node already in path',
      );
    }

    return SpamCheck(
      type: SpamCheckType.loop,
      passed: true,
      spamScore: 0.0,
      message: 'No loop detected',
    );
  }

  /// Increment relay count for rate limiting
  Future<void> _incrementRelayCount(String nodeId) async {
    final now = DateTime.now();
    final hourlyKey =
        '${nodeId}_${now.hour}_${now.day}_${now.month}_${now.year}';

    _hourlyRelayCount.putIfAbsent(hourlyKey, () => []);
    _hourlyRelayCount[hourlyKey]!.add(now.millisecondsSinceEpoch);
  }

  /// Update trust score for a node
  Future<void> _updateTrustScore(String nodeId, {required bool improve}) async {
    final currentScore = _trustScores[nodeId] ?? 0.5;

    // Gradual trust adjustment
    final adjustment = improve ? 0.05 : -0.1;
    final newScore = (currentScore + adjustment).clamp(0.0, 1.0);

    _trustScores[nodeId] = newScore;

    // Persist periodically (not every update for performance)
    if (DateTime.now().millisecondsSinceEpoch % 10 == 0) {
      await _saveTrustScores();
    }
  }

  /// Get block reason from failed checks
  String _getBlockReason(List<SpamCheck> checks) {
    final failed = checks.where((check) => !check.passed).toList();
    if (failed.isEmpty) return 'High spam score';

    return failed.map((check) => check.message).join('; ');
  }

  /// Load persistent data
  Future<void> _loadPersistentData() async {
    try {
      await _loadTrustScores();
      await _loadProcessedHashes();
      _logger.info('Loaded spam prevention data');
    } catch (e) {
      _logger.warning('Failed to load spam prevention data: $e');
    }
  }

  /// Load trust scores
  Future<void> _loadTrustScores() async {
    final prefs = await SharedPreferences.getInstance();
    final data = prefs.getString(_trustScoreKey);
    if (data != null) {
      final scores = Map<String, double>.from(jsonDecode(data));
      _trustScores.addAll(scores);
    }
  }

  /// Save trust scores
  Future<void> _saveTrustScores() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_trustScoreKey, jsonEncode(_trustScores));
    } catch (e) {
      _logger.warning('Failed to save trust scores: $e');
    }
  }

  /// Load processed hashes
  Future<void> _loadProcessedHashes() async {
    final prefs = await SharedPreferences.getInstance();
    final hashes = prefs.getStringList(_messageHashKey) ?? [];
    _processedHashes.addAll(hashes);
  }

  /// Save processed hashes
  Future<void> _saveProcessedHashes() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_messageHashKey, _processedHashes.toList());
    } catch (e) {
      _logger.warning('Failed to save processed hashes: $e');
    }
  }

  /// Start periodic cleanup
  void _startPeriodicCleanup() {
    _cleanupTimer = Timer.periodic(Duration(hours: 1), (timer) {
      _performCleanup();
    });
  }

  /// Perform cleanup of old data
  Future<void> _performCleanup() async {
    try {
      final now = DateTime.now();
      final cutoffTime = now
          .subtract(Duration(hours: 24))
          .millisecondsSinceEpoch;

      // Clean hourly rate limit counters
      _hourlyRelayCount.removeWhere((key, timestamps) {
        timestamps.removeWhere((timestamp) => timestamp < cutoffTime);
        return timestamps.isEmpty;
      });

      // Clean processed hashes (keep only recent ones)
      if (_processedHashes.length > 5000) {
        final hashList = _processedHashes.toList();
        _processedHashes.clear();
        _processedHashes.addAll(hashList.take(2000)); // Keep newest 2000
        await _saveProcessedHashes();
      }

      // Clean recent operations
      _recentOperations.removeWhere((hash, operation) {
        return operation.timestamp.isBefore(now.subtract(Duration(hours: 24)));
      });

      _logger.info('Performed spam prevention cleanup');
    } catch (e) {
      _logger.warning('Cleanup failed: $e');
    }
  }
}

/// Result of spam check
class SpamCheckResult {
  final bool allowed;
  final double spamScore;
  final String reason;
  final List<SpamCheck> checks;

  const SpamCheckResult({
    required this.allowed,
    required this.spamScore,
    required this.reason,
    required this.checks,
  });
}

/// Individual spam check
class SpamCheck {
  final SpamCheckType type;
  final bool passed;
  final double spamScore;
  final String message;

  const SpamCheck({
    required this.type,
    required this.passed,
    required this.spamScore,
    required this.message,
  });
}

/// Type of spam check
enum SpamCheckType {
  rateLimit,
  messageSize,
  hopCount,
  duplicate,
  trustScore,
  loop,
}

/// Spam prevention statistics
class SpamPreventionStatistics {
  final int totalAllowed;
  final int totalBlocked;
  final double blockRate;
  final double averageSpamScore;
  final int activeTrustScores;
  final int processedHashes;

  const SpamPreventionStatistics({
    required this.totalAllowed,
    required this.totalBlocked,
    required this.blockRate,
    required this.averageSpamScore,
    required this.activeTrustScores,
    required this.processedHashes,
  });

  @override
  String toString() =>
      'SpamStats(blocked: $totalBlocked/$totalAllowed, rate: ${(blockRate * 100).toStringAsFixed(1)}%)';
}

/// Relay operation record
class RelayOperation {
  final String messageHash;
  final String fromNodeId;
  final DateTime timestamp;
  final bool allowed;
  final double spamScore;

  const RelayOperation({
    required this.messageHash,
    required this.fromNodeId,
    required this.timestamp,
    required this.allowed,
    required this.spamScore,
  });
}
