import 'package:flutter_test/flutter_test.dart';
import 'package:pak_connect/core/services/queue_bandwidth_allocator.dart';
import 'package:pak_connect/domain/entities/queue_enums.dart';
import 'package:pak_connect/domain/entities/queued_message.dart';

void main() {
  group('QueueBandwidthAllocator', () {
    late QueueBandwidthAllocator allocator;

    setUp(() {
      allocator = QueueBandwidthAllocator();
    });

    test('sortMessagesByPriority orders by priority then FIFO timestamp', () {
      final base = DateTime(2026, 1, 1, 12);
      final messages = <QueuedMessage>[
        _message(
          id: 'low',
          priority: MessagePriority.low,
          queuedAt: base.add(const Duration(minutes: 3)),
        ),
        _message(
          id: 'urgent-newer',
          priority: MessagePriority.urgent,
          queuedAt: base.add(const Duration(minutes: 2)),
        ),
        _message(
          id: 'urgent-older',
          priority: MessagePriority.urgent,
          queuedAt: base.add(const Duration(minutes: 1)),
        ),
      ];

      allocator.sortMessagesByPriority(messages);

      expect(messages.map((m) => m.id), <String>[
        'urgent-older',
        'urgent-newer',
        'low',
      ]);
    });

    test('createDeliverySchedule returns empty schedule for empty queues', () {
      final result = allocator.createDeliverySchedule(
        directQueue: <QueuedMessage>[],
        relayQueue: <QueuedMessage>[],
      );

      expect(result.isEmpty, isTrue);
      expect(result.totalScheduled, 0);
      expect(result.directCount, 0);
      expect(result.relayCount, 0);
    });

    test('createDeliverySchedule skips non-pending entries and staggers delay', () {
      final base = DateTime(2026, 1, 1, 12);
      final directQueue = <QueuedMessage>[
        _message(
          id: 'direct-pending',
          priority: MessagePriority.high,
          queuedAt: base,
        ),
        _message(
          id: 'direct-failed',
          priority: MessagePriority.normal,
          queuedAt: base.add(const Duration(minutes: 1)),
          status: QueuedMessageStatus.failed,
        ),
      ];
      final relayQueue = <QueuedMessage>[
        _message(
          id: 'relay-pending',
          priority: MessagePriority.normal,
          queuedAt: base.add(const Duration(minutes: 2)),
        ),
      ];

      final result = allocator.createDeliverySchedule(
        directQueue: directQueue,
        relayQueue: relayQueue,
      );

      expect(result.directCount, 2);
      expect(result.relayCount, 1);
      expect(result.totalScheduled, 2);
      expect(result.schedule[0].message.id, 'direct-pending');
      expect(result.schedule[0].queueType, QueueType.direct);
      expect(result.schedule[0].delay, const Duration(milliseconds: 0));
      expect(result.schedule[1].message.id, 'relay-pending');
      expect(result.schedule[1].queueType, QueueType.relay);
      expect(result.schedule[1].delay, const Duration(milliseconds: 200));
    });

    test('getStatistics computes ratios and balance tolerance', () {
      final stats = allocator.getStatistics(directQueueSize: 8, relayQueueSize: 2);
      final skewed = allocator.getStatistics(
        directQueueSize: 10,
        relayQueueSize: 0,
      );
      final empty = allocator.getStatistics(directQueueSize: 0, relayQueueSize: 0);

      expect(stats.totalMessages, 10);
      expect(stats.directRatio, closeTo(0.8, 0.0001));
      expect(stats.relayRatio, closeTo(0.2, 0.0001));
      expect(stats.isBalanced, isTrue);
      expect(stats.toString(), contains('target: 80/20'));

      expect(skewed.isBalanced, isFalse);
      expect(empty.isBalanced, isTrue);
    });
  });
}

QueuedMessage _message({
  required String id,
  required MessagePriority priority,
  required DateTime queuedAt,
  QueuedMessageStatus status = QueuedMessageStatus.pending,
}) {
  return QueuedMessage(
    id: id,
    chatId: 'chat-a',
    content: 'payload',
    recipientPublicKey: 'recipient',
    senderPublicKey: 'sender',
    priority: priority,
    queuedAt: queuedAt,
    maxRetries: 3,
    status: status,
  );
}
