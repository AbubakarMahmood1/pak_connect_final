// Progressive cost policy for mesh relay messages.
// Maps sender volume to proof-of-work difficulty, with trust-aware free tiers.
//
// Design:
// - Rolling 24h window tracks per-sender message counts
// - Trust tier determines free threshold (friends get more free messages)
// - After free tier exhausted, difficulty escalates in tiers
// - Network-adaptive floor rises during high traffic (relay-side defense)

import 'dart:async';

import 'package:logging/logging.dart';
import 'package:meta/meta.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../entities/preference_keys.dart';

/// A single difficulty tier: messages beyond [threshold] require [difficulty].
class CostTier {
  /// Number of messages above free threshold before this tier activates.
  final int threshold;

  /// Required PoW difficulty (leading zero bits in SHA-256).
  final int difficulty;

  const CostTier({required this.threshold, required this.difficulty});

  @override
  String toString() => 'CostTier(+$threshold msgs → difficulty $difficulty)';
}

/// Progressive message cost policy.
///
/// Legitimate users send <100 msgs/day and never see PoW.
/// Heavy senders face escalating computational cost.
/// Relay nodes enforce a network-adaptive minimum floor.
class MessageCostPolicy {
  static final _logger = Logger('MessageCostPolicy');

  // ── Trust-aware free thresholds (daily, configurable) ───────────────

  int _freeThresholdUnknown = PreferenceDefaults.powFreeThresholdUnknown;
  int _freeThresholdKnown = PreferenceDefaults.powFreeThresholdKnown;
  int _freeThresholdFriend = PreferenceDefaults.powFreeThresholdFriend;

  /// Default difficulty tiers (messages above free threshold).
  static const List<CostTier> defaultTiers = [
    CostTier(threshold: 0, difficulty: 8), // +0: ~1ms
    CostTier(threshold: 150, difficulty: 12), // +150: ~15ms
    CostTier(threshold: 400, difficulty: 16), // +400: ~250ms
    CostTier(threshold: 900, difficulty: 20), // +900: ~4s
  ];

  List<CostTier> _tiers = defaultTiers;

  // ── Network-adaptive floor thresholds (hourly) ──────────────────────

  static const List<_FloorTier> _floorTiers = [
    _FloorTier(hourlyVolume: 200, floor: 4),
    _FloorTier(hourlyVolume: 500, floor: 8),
    _FloorTier(hourlyVolume: 1000, floor: 12),
  ];

  // ── Per-sender volume tracking (rolling 24h) ────────────────────────

  final Map<String, List<int>> _dailyCounts = {};

  // ── Network volume tracking (hourly) ────────────────────────────────

  final List<int> _networkHourlyTimestamps = [];

  Timer? _cleanupTimer;

  /// Initialize cost policy from user preferences.
  Future<void> initialize() async {
    await _loadSettings();
    _startPeriodicCleanup();
    _logger.info(
      '⚡ MessageCostPolicy initialized: '
      'free=$_freeThresholdUnknown/$_freeThresholdKnown/$_freeThresholdFriend '
      '(unknown/known/friend)',
    );
  }

  /// Dispose cleanup timer.
  void dispose() {
    _cleanupTimer?.cancel();
  }

  /// Get the required PoW difficulty for the next message from [senderNodeId].
  ///
  /// [trustScore] determines the free threshold tier:
  ///   - <0.4 (unknown): [_freeThresholdUnknown] free msgs/day
  ///   - 0.4-0.7 (known): [_freeThresholdKnown] free msgs/day
  ///   - >0.7 (friend): [_freeThresholdFriend] free msgs/day
  int getRequiredDifficulty(String senderNodeId, double trustScore) {
    final dailyCount = getDailyCount(senderNodeId);
    final freeThreshold = _freeThresholdForTrust(trustScore);

    if (dailyCount < freeThreshold) return 0;

    final overFree = dailyCount - freeThreshold;
    return _difficultyForOverage(overFree);
  }

  /// Get the network-adaptive minimum difficulty floor.
  ///
  /// Relay nodes call this based on their local view of total incoming traffic.
  /// Higher traffic = higher floor = all messages need more PoW.
  int getNetworkFloor(int totalHourlyVolume) {
    int floor = 0;
    for (final tier in _floorTiers) {
      if (totalHourlyVolume >= tier.hourlyVolume) {
        floor = tier.floor;
      }
    }
    return floor;
  }

  /// Record that [senderNodeId] sent a message (for volume tracking).
  void recordMessage(String senderNodeId) {
    final now = DateTime.now().millisecondsSinceEpoch;
    _dailyCounts.putIfAbsent(senderNodeId, () => []);
    _dailyCounts[senderNodeId]!.add(now);
    _networkHourlyTimestamps.add(now);
  }

  /// Get the number of messages sent by [senderNodeId] in the last 24 hours.
  int getDailyCount(String senderNodeId) {
    final timestamps = _dailyCounts[senderNodeId];
    if (timestamps == null || timestamps.isEmpty) return 0;

    final cutoff =
        DateTime.now().subtract(const Duration(hours: 24)).millisecondsSinceEpoch;
    return timestamps.where((t) => t >= cutoff).length;
  }

  /// Get total network volume in the last hour.
  int getNetworkHourlyVolume() {
    final cutoff =
        DateTime.now().subtract(const Duration(hours: 1)).millisecondsSinceEpoch;
    return _networkHourlyTimestamps.where((t) => t >= cutoff).length;
  }

  /// Get the effective required difficulty considering both sender volume
  /// and network floor.
  int getEffectiveDifficulty(
    String senderNodeId,
    double trustScore, {
    int? networkHourlyVolume,
  }) {
    final senderDifficulty = getRequiredDifficulty(senderNodeId, trustScore);
    final volume = networkHourlyVolume ?? getNetworkHourlyVolume();
    final floor = getNetworkFloor(volume);
    return senderDifficulty > floor ? senderDifficulty : floor;
  }

  /// Reload settings from SharedPreferences (call after user changes).
  Future<void> reloadSettings() async {
    await _loadSettings();
  }

  // ── Private helpers ─────────────────────────────────────────────────

  int _freeThresholdForTrust(double trustScore) {
    if (trustScore >= 0.7) return _freeThresholdFriend;
    if (trustScore >= 0.4) return _freeThresholdKnown;
    return _freeThresholdUnknown;
  }

  int _difficultyForOverage(int overFree) {
    int difficulty = 0;
    for (final tier in _tiers) {
      if (overFree >= tier.threshold) {
        difficulty = tier.difficulty;
      }
    }
    return difficulty;
  }

  Future<void> _loadSettings() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _freeThresholdUnknown =
          prefs.getInt(PreferenceKeys.powFreeThresholdUnknown) ??
              PreferenceDefaults.powFreeThresholdUnknown;
      _freeThresholdKnown =
          prefs.getInt(PreferenceKeys.powFreeThresholdKnown) ??
              PreferenceDefaults.powFreeThresholdKnown;
      _freeThresholdFriend =
          prefs.getInt(PreferenceKeys.powFreeThresholdFriend) ??
              PreferenceDefaults.powFreeThresholdFriend;
    } catch (e) {
      _logger.warning('Failed to load PoW settings, using defaults: $e');
    }
  }

  void _startPeriodicCleanup() {
    _cleanupTimer?.cancel();
    _cleanupTimer = Timer.periodic(const Duration(hours: 1), (_) {
      _performCleanup();
    });
  }

  void _performCleanup() {
    final dailyCutoff =
        DateTime.now().subtract(const Duration(hours: 24)).millisecondsSinceEpoch;
    final hourlyCutoff =
        DateTime.now().subtract(const Duration(hours: 1)).millisecondsSinceEpoch;

    // Prune daily counts
    _dailyCounts.forEach((key, timestamps) {
      timestamps.removeWhere((t) => t < dailyCutoff);
    });
    _dailyCounts.removeWhere((key, timestamps) => timestamps.isEmpty);

    // Prune network hourly timestamps
    _networkHourlyTimestamps.removeWhere((t) => t < hourlyCutoff);
  }

  // ── Test helpers ────────────────────────────────────────────────────

  @visibleForTesting
  void resetForTests() {
    _dailyCounts.clear();
    _networkHourlyTimestamps.clear();
  }

  @visibleForTesting
  void setFreeThresholdsForTest({int? unknown, int? known, int? friend}) {
    if (unknown != null) _freeThresholdUnknown = unknown;
    if (known != null) _freeThresholdKnown = known;
    if (friend != null) _freeThresholdFriend = friend;
  }

  @visibleForTesting
  void setTiersForTest(List<CostTier> tiers) {
    _tiers = tiers;
  }

  @visibleForTesting
  Map<String, int> get currentFreeThresholds => {
        'unknown': _freeThresholdUnknown,
        'known': _freeThresholdKnown,
        'friend': _freeThresholdFriend,
      };

  @visibleForTesting
  void addNetworkTimestampsForTest(int count) {
    final now = DateTime.now().millisecondsSinceEpoch;
    for (int i = 0; i < count; i++) {
      _networkHourlyTimestamps.add(now - i);
    }
  }
}

class _FloorTier {
  final int hourlyVolume;
  final int floor;
  const _FloorTier({required this.hourlyVolume, required this.floor});
}
