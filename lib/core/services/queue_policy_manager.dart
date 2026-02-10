import 'package:logging/logging.dart';
import '../../domain/entities/queued_message.dart';
import '../../domain/entities/queue_enums.dart';
import '../interfaces/i_repository_provider.dart';
import 'package:pak_connect/core/utils/string_extensions.dart';

/// Manages queue policy decisions including favorites-based benefits and per-peer limits
///
/// Responsibility: Queue policy logic
/// - Determine per-peer queue limits based on favorites status
/// - Auto-boost priority for favorite contacts
/// - Validate queue capacity before adding messages
/// - No database or network I/O (delegates to repository provider)
class QueuePolicyManager {
  static final _logger = Logger('QueuePolicyManager');

  // Per-peer queue limits (favorites-based store-and-forward)
  static const int _maxMessagesPerFavorite = 500;
  static const int _maxMessagesPerRegular = 100;

  final IRepositoryProvider? _repositoryProvider;

  QueuePolicyManager({IRepositoryProvider? repositoryProvider})
    : _repositoryProvider = repositoryProvider;

  /// Check if contact is a favorite
  Future<bool> isContactFavorite(String publicKey) async {
    if (_repositoryProvider == null) return false;

    try {
      return await _repositoryProvider.contactRepository.isContactFavorite(
        publicKey,
      );
    } catch (e) {
      _logger.warning(
        'Failed to check favorite status for ${publicKey.shortId(8)}...: $e',
      );
      return false;
    }
  }

  /// Get queue limit for a contact based on favorites status
  Future<int> getQueueLimit(String publicKey) async {
    final isFavorite = await isContactFavorite(publicKey);
    return isFavorite ? _maxMessagesPerFavorite : _maxMessagesPerRegular;
  }

  /// Auto-boost priority for favorite contacts
  ///
  /// If contact is a favorite and priority is normal or low, boost to high.
  /// Returns the potentially boosted priority and whether it was boosted.
  Future<PriorityBoostResult> applyFavoritesPriorityBoost({
    required String recipientPublicKey,
    required MessagePriority currentPriority,
  }) async {
    final isFavorite = await isContactFavorite(recipientPublicKey);

    if (isFavorite &&
        (currentPriority == MessagePriority.normal ||
            currentPriority == MessagePriority.low)) {
      _logger.fine(
        '⭐ Auto-boosted priority to HIGH for favorite contact ${recipientPublicKey.shortId(8)}...',
      );
      return PriorityBoostResult(
        priority: MessagePriority.high,
        wasBoosted: true,
        isFavorite: true,
      );
    }

    return PriorityBoostResult(
      priority: currentPriority,
      wasBoosted: false,
      isFavorite: isFavorite,
    );
  }

  /// Check if adding a message would exceed per-peer queue limits
  ///
  /// Returns validation result with details about limit and current count.
  Future<QueueLimitValidation> validateQueueLimit({
    required String recipientPublicKey,
    required List<QueuedMessage> allMessages,
  }) async {
    final isFavorite = await isContactFavorite(recipientPublicKey);
    final limit = isFavorite ? _maxMessagesPerFavorite : _maxMessagesPerRegular;

    final existingCount = allMessages
        .where(
          (m) =>
              m.recipientPublicKey == recipientPublicKey &&
              m.status != QueuedMessageStatus.delivered &&
              m.status != QueuedMessageStatus.failed,
        )
        .length;

    final wouldExceed = existingCount >= limit;

    if (wouldExceed) {
      final limitType = isFavorite ? 'favorite' : 'regular';
      _logger.warning(
        'Queue limit reached for $limitType contact ${recipientPublicKey.shortId(8)}...: '
        '$existingCount/$limit messages',
      );
    }

    return QueueLimitValidation(
      isValid: !wouldExceed,
      currentCount: existingCount,
      limit: limit,
      isFavorite: isFavorite,
    );
  }

  /// Get policy statistics
  PolicyStatistics getStatistics({required List<QueuedMessage> allMessages}) {
    final Map<String, int> peerCounts = {};

    for (final message in allMessages) {
      if (message.status != QueuedMessageStatus.delivered &&
          message.status != QueuedMessageStatus.failed) {
        peerCounts[message.recipientPublicKey] =
            (peerCounts[message.recipientPublicKey] ?? 0) + 1;
      }
    }

    final totalPeers = peerCounts.length;
    final maxPerPeer = peerCounts.values.fold<int>(
      0,
      (max, count) => count > max ? count : 0,
    );
    final avgPerPeer = totalPeers > 0 ? allMessages.length / totalPeers : 0.0;

    return PolicyStatistics(
      totalPeers: totalPeers,
      maxMessagesPerPeer: maxPerPeer,
      avgMessagesPerPeer: avgPerPeer,
      hasRepositoryProvider: _repositoryProvider != null,
    );
  }
}

/// Result of priority boost operation
class PriorityBoostResult {
  final MessagePriority priority;
  final bool wasBoosted;
  final bool isFavorite;

  const PriorityBoostResult({
    required this.priority,
    required this.wasBoosted,
    required this.isFavorite,
  });
}

/// Result of queue limit validation
class QueueLimitValidation {
  final bool isValid;
  final int currentCount;
  final int limit;
  final bool isFavorite;

  const QueueLimitValidation({
    required this.isValid,
    required this.currentCount,
    required this.limit,
    required this.isFavorite,
  });

  String get limitType => isFavorite ? 'favorite' : 'regular';

  String get errorMessage =>
      'Per-peer queue limit reached: $currentCount/$limit messages for $limitType contact';
}

/// Policy manager statistics
class PolicyStatistics {
  final int totalPeers;
  final int maxMessagesPerPeer;
  final double avgMessagesPerPeer;
  final bool hasRepositoryProvider;

  const PolicyStatistics({
    required this.totalPeers,
    required this.maxMessagesPerPeer,
    required this.avgMessagesPerPeer,
    required this.hasRepositoryProvider,
  });

  @override
  String toString() =>
      'PolicyStats(peers: $totalPeers, maxPerPeer: $maxMessagesPerPeer, avgPerPeer: ${avgMessagesPerPeer.toStringAsFixed(1)})';
}
