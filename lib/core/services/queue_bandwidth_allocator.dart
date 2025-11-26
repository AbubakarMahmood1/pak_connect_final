import 'dart:async';
import 'package:logging/logging.dart';
import '../../domain/entities/queued_message.dart';
import '../../domain/entities/queue_enums.dart';

/// Manages bandwidth allocation between direct and relay message queues
///
/// Responsibility: 80/20 bandwidth allocation strategy
/// - Allocate 80% bandwidth to direct (user-initiated) messages
/// - Allocate 20% bandwidth to relay (mesh forwarding) messages
/// - Schedule message delivery with proper bandwidth distribution
/// - No database or network I/O
class QueueBandwidthAllocator {
  static final _logger = Logger('QueueBandwidthAllocator');

  // Bandwidth allocation constant: 80% for direct, 20% for relay
  static const double _directBandwidthRatio = 0.8;

  /// Sort messages by priority and timestamp
  ///
  /// Higher priority messages are processed first.
  /// Within same priority, older messages are processed first (FIFO).
  void sortMessagesByPriority(List<QueuedMessage> messages) {
    messages.sort((a, b) {
      final priorityComparison = b.priority.index.compareTo(a.priority.index);
      if (priorityComparison != 0) return priorityComparison;
      return a.queuedAt.compareTo(b.queuedAt);
    });
  }

  /// Schedule message delivery with 80/20 bandwidth allocation
  ///
  /// Returns a delivery schedule that interleaves direct and relay messages
  /// according to the bandwidth ratio.
  DeliverySchedule createDeliverySchedule({
    required List<QueuedMessage> directQueue,
    required List<QueuedMessage> relayQueue,
  }) {
    final totalDirect = directQueue.length;
    final totalRelay = relayQueue.length;

    if (totalDirect == 0 && totalRelay == 0) {
      return DeliverySchedule(schedule: [], directCount: 0, relayCount: 0);
    }

    _logger.info(
      'Creating delivery schedule: direct=$totalDirect (80%), relay=$totalRelay (20%)',
    );

    // Sort both queues by priority and timestamp
    sortMessagesByPriority(directQueue);
    sortMessagesByPriority(relayQueue);

    // Calculate bandwidth allocation
    final totalSlots = totalDirect + totalRelay;
    final directSlots = (totalSlots * _directBandwidthRatio).ceil();

    final schedule = <ScheduledMessage>[];
    int directProcessed = 0;
    int relayProcessed = 0;
    int slotIndex = 0;

    // Interleaved processing with bandwidth allocation
    while (directProcessed < totalDirect || relayProcessed < totalRelay) {
      // Determine which queue to process from
      final shouldProcessDirect =
          directProcessed < totalDirect &&
          (relayProcessed >= totalRelay || directProcessed < directSlots);

      if (shouldProcessDirect && directProcessed < totalDirect) {
        final message = directQueue[directProcessed];
        if (message.status == QueuedMessageStatus.pending) {
          // Stagger deliveries to prevent network congestion
          final delay = Duration(milliseconds: slotIndex * 100);
          schedule.add(
            ScheduledMessage(
              message: message,
              delay: delay,
              queueType: QueueType.direct,
            ),
          );
        }
        directProcessed++;
        slotIndex++;
      } else if (relayProcessed < totalRelay) {
        final message = relayQueue[relayProcessed];
        if (message.status == QueuedMessageStatus.pending) {
          // Stagger deliveries to prevent network congestion
          final delay = Duration(milliseconds: slotIndex * 100);
          schedule.add(
            ScheduledMessage(
              message: message,
              delay: delay,
              queueType: QueueType.relay,
            ),
          );
        }
        relayProcessed++;
        slotIndex++;
      } else {
        // Both queues exhausted
        break;
      }
    }

    _logger.info(
      'Delivery schedule created: direct=$directProcessed, relay=$relayProcessed (total slots: $slotIndex)',
    );

    return DeliverySchedule(
      schedule: schedule,
      directCount: directProcessed,
      relayCount: relayProcessed,
    );
  }

  /// Get bandwidth allocation statistics
  BandwidthStatistics getStatistics({
    required int directQueueSize,
    required int relayQueueSize,
  }) {
    final totalMessages = directQueueSize + relayQueueSize;
    final directRatio = totalMessages > 0
        ? directQueueSize / totalMessages
        : 0.0;
    final relayRatio = totalMessages > 0 ? relayQueueSize / totalMessages : 0.0;

    return BandwidthStatistics(
      directQueueSize: directQueueSize,
      relayQueueSize: relayQueueSize,
      totalMessages: totalMessages,
      directRatio: directRatio,
      relayRatio: relayRatio,
      targetDirectRatio: _directBandwidthRatio,
      targetRelayRatio: 1.0 - _directBandwidthRatio,
    );
  }
}

/// Message delivery schedule
class DeliverySchedule {
  final List<ScheduledMessage> schedule;
  final int directCount;
  final int relayCount;

  const DeliverySchedule({
    required this.schedule,
    required this.directCount,
    required this.relayCount,
  });

  int get totalScheduled => schedule.length;
  bool get isEmpty => schedule.isEmpty;
}

/// Scheduled message with delivery timing
class ScheduledMessage {
  final QueuedMessage message;
  final Duration delay;
  final QueueType queueType;

  const ScheduledMessage({
    required this.message,
    required this.delay,
    required this.queueType,
  });
}

/// Queue type for bandwidth allocation
enum QueueType { direct, relay }

/// Bandwidth allocation statistics
class BandwidthStatistics {
  final int directQueueSize;
  final int relayQueueSize;
  final int totalMessages;
  final double directRatio;
  final double relayRatio;
  final double targetDirectRatio;
  final double targetRelayRatio;

  const BandwidthStatistics({
    required this.directQueueSize,
    required this.relayQueueSize,
    required this.totalMessages,
    required this.directRatio,
    required this.relayRatio,
    required this.targetDirectRatio,
    required this.targetRelayRatio,
  });

  /// Check if bandwidth allocation is balanced within 10% tolerance
  bool get isBalanced {
    if (totalMessages == 0) return true;
    final directDeviation = (directRatio - targetDirectRatio).abs();
    return directDeviation <= 0.1; // 10% tolerance
  }

  @override
  String toString() =>
      'BandwidthStats(direct: $directQueueSize (${(directRatio * 100).toStringAsFixed(1)}%), '
      'relay: $relayQueueSize (${(relayRatio * 100).toStringAsFixed(1)}%), '
      'target: 80/20)';
}
