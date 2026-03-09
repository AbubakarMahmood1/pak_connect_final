/// A single entry from the `change_log` table, representing one
/// INSERT / UPDATE / DELETE operation on contacts, chats, or messages.
///
/// Used for live P2P change_log exchange during gossip sync (Phase 2).
class ChangeLogEntry {
  /// Auto-increment ID in the local database (used as sync cursor).
  final int id;

  /// Table that was modified: 'contacts', 'chats', or 'messages'.
  final String tableName;

  /// SQL operation: 'INSERT', 'UPDATE', or 'DELETE'.
  final String operation;

  /// Primary key of the affected row (e.g., contact public_key, message id).
  final String rowKey;

  /// Timestamp of the change in milliseconds since epoch.
  final int changedAt;

  const ChangeLogEntry({
    required this.id,
    required this.tableName,
    required this.operation,
    required this.rowKey,
    required this.changedAt,
  });

  /// Create from a database row map.
  factory ChangeLogEntry.fromMap(Map<String, dynamic> map) {
    return ChangeLogEntry(
      id: map['id'] as int,
      tableName: map['table_name'] as String,
      operation: map['operation'] as String,
      rowKey: map['row_key'] as String,
      changedAt: map['changed_at'] as int,
    );
  }

  /// Serialize to JSON-compatible map for BLE transport.
  Map<String, dynamic> toJson() => {
        'id': id,
        'table_name': tableName,
        'operation': operation,
        'row_key': rowKey,
        'changed_at': changedAt,
      };

  /// Deserialize from JSON map received over BLE.
  factory ChangeLogEntry.fromJson(Map<String, dynamic> json) {
    return ChangeLogEntry(
      id: json['id'] as int,
      tableName: json['table_name'] as String,
      operation: json['operation'] as String,
      rowKey: json['row_key'] as String,
      changedAt: json['changed_at'] as int,
    );
  }

  @override
  String toString() =>
      'ChangeLogEntry(id=$id, $operation on $tableName[$rowKey])';
}
