import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:pak_connect/core/services/queue_sync_coordinator.dart';
import 'package:pak_connect/core/messaging/offline_message_queue.dart';
import 'package:pak_connect/domain/entities/enhanced_message.dart';

void main() {
  final List<LogRecord> logRecords = [];
  final Set<String> allowedSevere = {};

  group('QueueSyncCoordinator - Simple Tests', () {
    late QueueSyncCoordinator coordinator;

    setUp(() {
      logRecords.clear();
      Logger.root.level = Level.ALL;
      Logger.root.onRecord.listen(logRecords.add);
      coordinator = QueueSyncCoordinator();
    });

    tearDown(() {
      final severeErrors = logRecords
          .where((log) => log.level >= Level.SEVERE)
          .where(
            (log) =>
                !allowedSevere.any((pattern) => log.message.contains(pattern)),
          )
          .toList();
      expect(
        severeErrors,
        isEmpty,
        reason:
            'Unexpected SEVERE errors:\n${severeErrors.map((e) => '${e.level}: ${e.message}').join('\n')}',
      );
    });

    group('Hash Calculation', () {
      test('calculateQueueHash returns valid SHA256 hash', () {
        // Act
        final hash = coordinator.calculateQueueHash();

        // Assert
        expect(hash, isNotEmpty);
        expect(hash.length, 64); // SHA256 = 64 hex characters
      });

      test('hash is consistent when called repeatedly', () {
        // Act
        final hash1 = coordinator.calculateQueueHash();
        final hash2 = coordinator.calculateQueueHash();

        // Assert
        expect(hash1, equals(hash2));
      });

      test('force recalculation invalidates cache', () {
        // Act
        coordinator.calculateQueueHash();
        final hash = coordinator.calculateQueueHash(forceRecalculation: true);

        // Assert
        expect(hash, isNotEmpty);
      });
    });

    group('Synchronization checks', () {
      test('needsSynchronization returns true for different hashes', () {
        // Act
        final needs = coordinator.needsSynchronization('different-hash-value');

        // Assert
        expect(needs, true);
      });

      test('needsSynchronization returns false for same hash', () {
        // Arrange
        final hash = coordinator.calculateQueueHash();

        // Act
        final needs = coordinator.needsSynchronization(hash);

        // Assert
        expect(needs, false);
      });
    });

    group('Deletion Tracking', () {
      test('marks message as deleted', () async {
        // Act
        await coordinator.markMessageDeleted('msg-1');

        // Assert
        expect(coordinator.isMessageDeleted('msg-1'), true);
      });

      test('returns false for non-deleted messages', () {
        // Act
        final deleted = coordinator.isMessageDeleted('non-existent');

        // Assert
        expect(deleted, false);
      });

      test('tracks multiple deleted messages', () async {
        // Act
        await coordinator.markMessageDeleted('msg-1');
        await coordinator.markMessageDeleted('msg-2');
        await coordinator.markMessageDeleted('msg-3');

        // Assert
        expect(coordinator.getDeletedMessageCount(), 3);
        expect(coordinator.isMessageDeleted('msg-1'), true);
        expect(coordinator.isMessageDeleted('msg-2'), true);
        expect(coordinator.isMessageDeleted('msg-3'), true);
      });

      test('getDeletedMessageIds returns set of IDs', () async {
        // Arrange
        const ids = ['msg-1', 'msg-2'];

        // Act
        for (final id in ids) {
          await coordinator.markMessageDeleted(id);
        }

        // Assert
        expect(coordinator.getDeletedMessageIds(), equals(ids.toSet()));
      });
    });

    group('Cache Management', () {
      test('invalidateHashCache clears cache', () {
        // Arrange
        coordinator.calculateQueueHash();
        coordinator.invalidateHashCache();

        // Act
        final stats = coordinator.getSyncStatistics();

        // Assert
        expect(stats.isCachValid, false);
      });
    });

    group('Statistics', () {
      test('getSyncStatistics returns valid stats', () {
        // Act
        final stats = coordinator.getSyncStatistics();

        // Assert
        expect(stats.activeMessageCount, greaterThanOrEqualTo(0));
        expect(stats.deletedMessageCount, greaterThanOrEqualTo(0));
        expect(stats.currentHash, isNotEmpty);
      });

      test('sync statistics increment sync request count', () {
        // Act
        coordinator.createSyncMessage('node-1');
        final stats1 = coordinator.getSyncStatistics();

        coordinator.createSyncMessage('node-2');
        final stats2 = coordinator.getSyncStatistics();

        // Assert
        expect(stats2.syncRequestsCount, greaterThan(stats1.syncRequestsCount));
      });
    });

    group('State Management', () {
      test('resetSyncState clears all sync state', () async {
        // Arrange
        await coordinator.markMessageDeleted('msg-1');
        coordinator.calculateQueueHash();

        // Act
        await coordinator.resetSyncState();

        // Assert
        expect(coordinator.getDeletedMessageCount(), 0);
        expect(coordinator.isMessageDeleted('msg-1'), false);
      });

      test('cleanup capacity detection works', () async {
        // Arrange
        for (int i = 0; i < 850; i++) {
          await coordinator.markMessageDeleted('msg-$i');
        }

        // Act
        final exceeded = coordinator.isDeletedIdCapacityExceeded();

        // Assert
        expect(exceeded, true);
      });

      test('cleanupOldDeletedIds triggers when needed', () async {
        // Arrange
        for (int i = 0; i < 850; i++) {
          await coordinator.markMessageDeleted('msg-$i');
        }

        // Act
        await coordinator.cleanupOldDeletedIds();

        // Assert
        expect(coordinator.getDeletedMessageCount(), lessThanOrEqualTo(1000));
      });
    });

    group('Integration', () {
      test('hash changes when deleted messages change', () async {
        // Arrange
        final hash1 = coordinator.calculateQueueHash();

        // Act
        await coordinator.markMessageDeleted('test-msg');
        final hash2 = coordinator.calculateQueueHash();

        // Assert
        expect(hash1, isNot(equals(hash2)));
      });

      test('full sync lifecycle works', () {
        // Arrange
        final hash1 = coordinator.calculateQueueHash();

        // Act
        final syncMsg = coordinator.createSyncMessage('peer-node-1');
        final needsSync = coordinator.needsSynchronization('different-hash');

        // Assert
        expect(hash1, isNotEmpty);
        expect(syncMsg, isNotNull);
        expect(needsSync, true);
      });
    });
  });
}
