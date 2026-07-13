/// A single entry from the `change_log` table, representing one
/// INSERT / UPDATE / DELETE operation on contacts, chats, or messages.
///
/// Used by local export/import and by a dormant peer-replay prototype. It is
/// not a complete row payload and is not sent by the production BLE runtime.
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

  /// Serialize to a JSON-compatible map for export or prototype transport.
  Map<String, dynamic> toJson() => {
    'id': id,
    'table_name': tableName,
    'operation': operation,
    'row_key': rowKey,
    'changed_at': changedAt,
  };

  /// Deserialize from an exported or prototype-transport JSON map.
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
