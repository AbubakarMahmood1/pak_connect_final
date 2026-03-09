// Live peer-to-peer change_log exchange service (Phase 2).
//
// Bridges the gap between the change_log table (which only served
// file-based export/import) and live BLE gossip sync. During each
// sync round, peers exchange change_log entries since their last
// sync cursor so that contacts, chats, and message status changes
// propagate across the mesh.
//
// This service is callback-driven — actual DB and BLE operations are
// injected so it stays in the domain layer.
import 'package:logging/logging.dart';
import 'package:pak_connect/domain/models/change_log_entry.dart';
import 'package:pak_connect/domain/utils/string_extensions.dart';

/// Primary-key column name per table, matching the DB schema.
const Map<String, String> pkColumnByTable = {
  'contacts': 'public_key',
  'chats': 'chat_id',
  'messages': 'id',
};

class ChangeLogSyncService {
  static final _logger = Logger('ChangeLogSyncService');

  /// Maximum entries to exchange per sync round (prevents BLE overload).
  static const int maxEntriesPerSync = 500;

  /// Default age limit for first-sync (no cursor): last 30 days.
  static const Duration firstSyncWindow = Duration(days: 30);

  // ─── Callbacks (wired by the coordinator / runtime helper) ───────

  /// Query local change_log for entries with id > cursor.
  /// Returns entries ordered by id ASC, capped at [maxEntriesPerSync].
  Future<List<ChangeLogEntry>> Function(int sinceCursorId)?
      onQueryChangeLogSince;

  /// Query local change_log for entries changed after [sinceMillis].
  /// Used for first-sync when no cursor exists.
  Future<List<ChangeLogEntry>> Function(int sinceMillis)?
      onQueryChangeLogSinceTime;

  /// Replay a list of received change_log entries against the local DB.
  /// Handles INSERT/UPDATE → upsert, DELETE → delete.
  Future<ChangeLogReplayResult> Function(List<ChangeLogEntry> entries)?
      onReplayChangeLogEntries;

  /// Get the last synced change_log ID for a specific peer.
  Future<int?> Function(String peerId)? onGetLastSyncedCursorForPeer;

  /// Update the last synced change_log ID for a specific peer.
  Future<void> Function(String peerId, int cursorId)?
      onSetLastSyncedCursorForPeer;

  /// Send change_log entries to a peer over BLE.
  Future<void> Function(String peerId, List<ChangeLogEntry> entries)?
      onSendChangeLogToPeer;

  // ─── Core sync logic ─────────────────────────────────────────────

  /// Build change_log payload for a specific peer.
  ///
  /// Queries entries since the peer's cursor (or last 30 days for first sync).
  Future<List<ChangeLogEntry>> getEntriesForPeer(String peerId) async {
    final cursor = await onGetLastSyncedCursorForPeer?.call(peerId);

    if (cursor != null && cursor > 0) {
      // Incremental sync: entries since last synced cursor
      final entries = await onQueryChangeLogSince?.call(cursor) ?? [];
      _logger.fine(
        '🔄 Change_log for ${peerId.shortId(8)}...: ${entries.length} entries since cursor $cursor',
      );
      return entries;
    }

    // First sync: exchange entries from the last 30 days
    final sinceMillis =
        DateTime.now().subtract(firstSyncWindow).millisecondsSinceEpoch;
    final entries = await onQueryChangeLogSinceTime?.call(sinceMillis) ?? [];
    _logger.info(
      '🔄 First sync with ${peerId.shortId(8)}...: ${entries.length} change_log entries (last ${firstSyncWindow.inDays} days)',
    );
    return entries;
  }

  /// Process received change_log entries from a peer.
  ///
  /// Replays entries against local DB and updates the peer's cursor.
  Future<ChangeLogReplayResult> processReceivedEntries({
    required String fromPeerId,
    required List<ChangeLogEntry> entries,
  }) async {
    if (entries.isEmpty) {
      return const ChangeLogReplayResult.empty();
    }

    _logger.info(
      '📥 Processing ${entries.length} change_log entries from ${fromPeerId.shortId(8)}...',
    );

    // Replay entries against local DB
    final result =
        await onReplayChangeLogEntries?.call(entries) ??
        const ChangeLogReplayResult.empty();

    // Update cursor to the highest received entry ID
    final maxId = entries.fold<int>(0, (max, e) => e.id > max ? e.id : max);
    if (maxId > 0) {
      await onSetLastSyncedCursorForPeer?.call(fromPeerId, maxId);
    }

    _logger.info(
      '✅ Change_log replay from ${fromPeerId.shortId(8)}...: '
      '${result.insertsApplied} inserts, ${result.updatesApplied} updates, '
      '${result.deletesApplied} deletes, ${result.skipped} skipped',
    );

    return result;
  }

  /// Perform a full change_log exchange with a peer.
  ///
  /// Call this after the hash-based message sync completes.
  Future<void> exchangeWithPeer(String peerId) async {
    try {
      // Get our entries for this peer
      final outgoing = await getEntriesForPeer(peerId);

      // Send to peer if we have entries
      if (outgoing.isNotEmpty) {
        _logger.info(
          '📤 Sending ${outgoing.length} change_log entries to ${peerId.shortId(8)}...',
        );
        await onSendChangeLogToPeer?.call(peerId, outgoing);
      }
    } catch (e) {
      _logger.warning(
        '⚠️ Change_log exchange failed with ${peerId.shortId(8)}...: $e',
      );
    }
  }
}

/// Result of replaying change_log entries.
class ChangeLogReplayResult {
  final int insertsApplied;
  final int updatesApplied;
  final int deletesApplied;
  final int skipped;
  final int errors;
  /// Phase 3: Count of LWW conflicts detected (remote was newer).
  final int conflicts;

  const ChangeLogReplayResult({
    required this.insertsApplied,
    required this.updatesApplied,
    required this.deletesApplied,
    required this.skipped,
    required this.errors,
    this.conflicts = 0,
  });

  const ChangeLogReplayResult.empty()
      : insertsApplied = 0,
        updatesApplied = 0,
        deletesApplied = 0,
        skipped = 0,
        errors = 0,
        conflicts = 0;

  int get totalApplied => insertsApplied + updatesApplied + deletesApplied;

  Map<String, dynamic> toJson() => {
        'insertsApplied': insertsApplied,
        'updatesApplied': updatesApplied,
        'deletesApplied': deletesApplied,
        'skipped': skipped,
        'errors': errors,
        'conflicts': conflicts,
      };
}
