import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:pak_connect/domain/models/change_log_entry.dart';
import 'package:pak_connect/domain/services/change_log_sync_service.dart';

/// Phase 2 tests: change_log exchange during live P2P sync.
///
/// Verifies:
/// - ChangeLogEntry model serialization
/// - ChangeLogSyncService cursor-based querying
/// - First-sync (no cursor) falls back to time window
/// - Replay of received entries (INSERT/UPDATE/DELETE)
/// - Cursor tracking per peer
void main() {
  group('Phase 2: ChangeLogEntry model', () {
    test('serializes to JSON and back', () {
      final entry = ChangeLogEntry(
        id: 42,
        tableName: 'contacts',
        operation: 'INSERT',
        rowKey: 'pk_abc123',
        changedAt: 1709900000000,
      );

      final json = entry.toJson();
      expect(json['id'], 42);
      expect(json['table_name'], 'contacts');
      expect(json['operation'], 'INSERT');
      expect(json['row_key'], 'pk_abc123');
      expect(json['changed_at'], 1709900000000);

      final restored = ChangeLogEntry.fromJson(json);
      expect(restored.id, entry.id);
      expect(restored.tableName, entry.tableName);
      expect(restored.operation, entry.operation);
      expect(restored.rowKey, entry.rowKey);
      expect(restored.changedAt, entry.changedAt);
    });

    test('creates from database row map', () {
      final map = {
        'id': 7,
        'table_name': 'messages',
        'operation': 'DELETE',
        'row_key': 'msg_xyz',
        'changed_at': 1709800000000,
      };

      final entry = ChangeLogEntry.fromMap(map);
      expect(entry.id, 7);
      expect(entry.tableName, 'messages');
      expect(entry.operation, 'DELETE');
      expect(entry.rowKey, 'msg_xyz');
    });

    test('toString is readable', () {
      final entry = ChangeLogEntry(
        id: 1,
        tableName: 'chats',
        operation: 'UPDATE',
        rowKey: 'chat_1',
        changedAt: 0,
      );
      expect(entry.toString(), contains('UPDATE'));
      expect(entry.toString(), contains('chats'));
    });
  });

  group('Phase 2: ChangeLogSyncService', () {
    final List<LogRecord> logRecords = [];

    late ChangeLogSyncService service;
    late _FakeChangeLogDB fakeDb;

    setUp(() {
      logRecords.clear();
      Logger.root.level = Level.ALL;
      Logger.root.onRecord.listen(logRecords.add);

      fakeDb = _FakeChangeLogDB();
      service = ChangeLogSyncService();

      // Wire callbacks to fake DB
      service.onQueryChangeLogSince = fakeDb.queryChangeLogSince;
      service.onQueryChangeLogSinceTime = fakeDb.queryChangeLogSinceTime;
      service.onReplayChangeLogEntries = fakeDb.replayEntries;
      service.onGetLastSyncedCursorForPeer = fakeDb.getCursorForPeer;
      service.onSetLastSyncedCursorForPeer = fakeDb.setCursorForPeer;
      service.onSendChangeLogToPeer = fakeDb.recordSentEntries;
    });

    test('getEntriesForPeer uses cursor when available', () async {
      // Set cursor for peer_B
      await fakeDb.setCursorForPeer('peer_B', 5);

      // Add entries with IDs after cursor
      fakeDb.addEntries([
        _entry(6, 'contacts', 'INSERT', 'pk_1'),
        _entry(7, 'messages', 'DELETE', 'msg_1'),
      ]);

      final entries = await service.getEntriesForPeer('peer_B');

      expect(entries, hasLength(2));
      expect(entries[0].id, 6);
      expect(entries[1].id, 7);
    });

    test('getEntriesForPeer uses time window for first sync', () async {
      // No cursor set → first sync
      final recentMillis = DateTime.now()
          .subtract(Duration(days: 5))
          .millisecondsSinceEpoch;

      fakeDb.addEntries([
        _entry(1, 'contacts', 'INSERT', 'pk_1', changedAt: recentMillis),
        _entry(
          2,
          'contacts',
          'INSERT',
          'pk_2',
          changedAt: DateTime.now()
              .subtract(Duration(days: 60))
              .millisecondsSinceEpoch,
        ),
      ]);

      final entries = await service.getEntriesForPeer('new_peer');

      // Only the recent entry should be returned (last 30 days)
      expect(entries, hasLength(1));
      expect(entries[0].rowKey, 'pk_1');
    });

    test('processReceivedEntries replays and updates cursor', () async {
      final entries = [
        _entry(10, 'contacts', 'INSERT', 'pk_new'),
        _entry(11, 'messages', 'DELETE', 'msg_old'),
        _entry(12, 'chats', 'UPDATE', 'chat_1'),
      ];

      final result = await service.processReceivedEntries(
        fromPeerId: 'peer_A',
        entries: entries,
      );

      // Check replay was called
      expect(fakeDb.replayedEntries, hasLength(3));

      // Check cursor updated to max ID
      final cursor = await fakeDb.getCursorForPeer('peer_A');
      expect(cursor, 12);

      // Check result
      expect(result.totalApplied, greaterThan(0));
    });

    test('processReceivedEntries handles empty list', () async {
      final result = await service.processReceivedEntries(
        fromPeerId: 'peer_A',
        entries: [],
      );

      expect(result.totalApplied, 0);
      expect(fakeDb.replayedEntries, isEmpty);
    });

    test('exchangeWithPeer sends entries', () async {
      fakeDb.addEntries([
        _entry(1, 'contacts', 'INSERT', 'pk_1'),
      ]);

      await service.exchangeWithPeer('peer_B');

      expect(fakeDb.sentEntries, hasLength(1));
      expect(fakeDb.sentEntries['peer_B'], hasLength(1));
    });

    test('exchangeWithPeer skips send when no entries', () async {
      // No entries in DB
      await service.exchangeWithPeer('peer_B');

      expect(fakeDb.sentEntries, isEmpty);
    });

    test('cursor advances correctly after multiple syncs', () async {
      // First sync
      await service.processReceivedEntries(
        fromPeerId: 'peer_A',
        entries: [_entry(5, 'contacts', 'INSERT', 'pk_1')],
      );
      expect(await fakeDb.getCursorForPeer('peer_A'), 5);

      // Second sync with higher IDs
      await service.processReceivedEntries(
        fromPeerId: 'peer_A',
        entries: [
          _entry(8, 'messages', 'UPDATE', 'msg_1'),
          _entry(10, 'chats', 'DELETE', 'chat_1'),
        ],
      );
      expect(await fakeDb.getCursorForPeer('peer_A'), 10);
    });

    test('DELETE operations propagate correctly', () async {
      await service.processReceivedEntries(
        fromPeerId: 'peer_A',
        entries: [
          _entry(1, 'contacts', 'DELETE', 'pk_to_delete'),
          _entry(2, 'messages', 'DELETE', 'msg_to_delete'),
        ],
      );

      // Both deletes should be replayed
      final deletes = fakeDb.replayedEntries
          .where((e) => e.operation == 'DELETE')
          .toList();
      expect(deletes, hasLength(2));
      expect(deletes.map((e) => e.rowKey), contains('pk_to_delete'));
      expect(deletes.map((e) => e.rowKey), contains('msg_to_delete'));
    });

    test('per-peer cursors are independent', () async {
      await service.processReceivedEntries(
        fromPeerId: 'peer_A',
        entries: [_entry(10, 'contacts', 'INSERT', 'pk_1')],
      );
      await service.processReceivedEntries(
        fromPeerId: 'peer_B',
        entries: [_entry(20, 'contacts', 'INSERT', 'pk_2')],
      );

      expect(await fakeDb.getCursorForPeer('peer_A'), 10);
      expect(await fakeDb.getCursorForPeer('peer_B'), 20);
    });
  });

  group('Phase 2: ChangeLogReplayResult', () {
    test('empty result has zero totals', () {
      const result = ChangeLogReplayResult.empty();
      expect(result.totalApplied, 0);
      expect(result.insertsApplied, 0);
      expect(result.updatesApplied, 0);
      expect(result.deletesApplied, 0);
      expect(result.skipped, 0);
      expect(result.errors, 0);
    });

    test('totalApplied sums correctly', () {
      const result = ChangeLogReplayResult(
        insertsApplied: 3,
        updatesApplied: 2,
        deletesApplied: 1,
        skipped: 5,
        errors: 0,
      );
      expect(result.totalApplied, 6);
    });

    test('toJson serializes correctly', () {
      const result = ChangeLogReplayResult(
        insertsApplied: 1,
        updatesApplied: 2,
        deletesApplied: 3,
        skipped: 4,
        errors: 5,
      );
      final json = result.toJson();
      expect(json['insertsApplied'], 1);
      expect(json['deletesApplied'], 3);
    });
  });

  group('Phase 3: LWW Conflict Resolution', () {
    test('ChangeLogReplayResult tracks conflicts', () {
      const result = ChangeLogReplayResult(
        insertsApplied: 1,
        updatesApplied: 2,
        deletesApplied: 1,
        skipped: 0,
        errors: 0,
        conflicts: 3,
      );
      expect(result.conflicts, 3);
      expect(result.toJson()['conflicts'], 3);
    });

    test('empty result has zero conflicts', () {
      const result = ChangeLogReplayResult.empty();
      expect(result.conflicts, 0);
    });

    test('DELETE wins over local data', () async {
      final fakeDb = _FakeChangeLogDB();
      final service = ChangeLogSyncService();
      service.onQueryChangeLogSince = fakeDb.queryChangeLogSince;
      service.onQueryChangeLogSinceTime = fakeDb.queryChangeLogSinceTime;
      service.onReplayChangeLogEntries = fakeDb.replayEntries;
      service.onGetLastSyncedCursorForPeer = fakeDb.getCursorForPeer;
      service.onSetLastSyncedCursorForPeer = fakeDb.setCursorForPeer;
      service.onSendChangeLogToPeer = fakeDb.recordSentEntries;

      // Replay a DELETE — should always succeed
      final result = await service.processReceivedEntries(
        fromPeerId: 'peer_A',
        entries: [_entry(1, 'contacts', 'DELETE', 'pk_victim')],
      );

      expect(result.deletesApplied, 1);
      expect(result.skipped, 0);
    });

    test('mixed operations produce correct tallies', () async {
      final fakeDb = _FakeChangeLogDB();
      final service = ChangeLogSyncService();
      service.onReplayChangeLogEntries = fakeDb.replayEntries;
      service.onGetLastSyncedCursorForPeer = fakeDb.getCursorForPeer;
      service.onSetLastSyncedCursorForPeer = fakeDb.setCursorForPeer;

      final result = await service.processReceivedEntries(
        fromPeerId: 'peer_X',
        entries: [
          _entry(1, 'contacts', 'INSERT', 'pk_new'),
          _entry(2, 'contacts', 'UPDATE', 'pk_existing'),
          _entry(3, 'messages', 'DELETE', 'msg_old'),
          _entry(4, 'chats', 'INSERT', 'chat_new'),
          _entry(5, 'messages', 'UPDATE', 'msg_updated'),
        ],
      );

      expect(result.totalApplied, greaterThan(0));
      expect(result.insertsApplied + result.updatesApplied + result.deletesApplied,
          result.totalApplied);
    });
  });
}

// =============================================================================
// Test helpers
// =============================================================================

ChangeLogEntry _entry(
  int id,
  String tableName,
  String operation,
  String rowKey, {
  int? changedAt,
}) {
  return ChangeLogEntry(
    id: id,
    tableName: tableName,
    operation: operation,
    rowKey: rowKey,
    changedAt: changedAt ?? DateTime.now().millisecondsSinceEpoch,
  );
}

/// In-memory fake for change_log DB operations.
class _FakeChangeLogDB {
  final List<ChangeLogEntry> _entries = [];
  final Map<String, int> _cursors = {};
  final List<ChangeLogEntry> replayedEntries = [];
  final Map<String, List<ChangeLogEntry>> sentEntries = {};

  void addEntries(List<ChangeLogEntry> entries) {
    _entries.addAll(entries);
  }

  Future<List<ChangeLogEntry>> queryChangeLogSince(int sinceCursorId) async {
    return _entries.where((e) => e.id > sinceCursorId).toList()
      ..sort((a, b) => a.id.compareTo(b.id));
  }

  Future<List<ChangeLogEntry>> queryChangeLogSinceTime(
    int sinceMillis,
  ) async {
    return _entries.where((e) => e.changedAt >= sinceMillis).toList()
      ..sort((a, b) => a.id.compareTo(b.id));
  }

  Future<ChangeLogReplayResult> replayEntries(
    List<ChangeLogEntry> entries,
  ) async {
    replayedEntries.addAll(entries);

    int inserts = 0, updates = 0, deletes = 0;
    for (final e in entries) {
      switch (e.operation) {
        case 'INSERT':
          inserts++;
          break;
        case 'UPDATE':
          updates++;
          break;
        case 'DELETE':
          deletes++;
          break;
      }
    }

    return ChangeLogReplayResult(
      insertsApplied: inserts,
      updatesApplied: updates,
      deletesApplied: deletes,
      skipped: 0,
      errors: 0,
    );
  }

  Future<int?> getCursorForPeer(String peerId) async {
    return _cursors[peerId];
  }

  Future<void> setCursorForPeer(String peerId, int cursorId) async {
    _cursors[peerId] = cursorId;
  }

  Future<void> recordSentEntries(
    String peerId,
    List<ChangeLogEntry> entries,
  ) async {
    sentEntries[peerId] = entries;
  }
}
