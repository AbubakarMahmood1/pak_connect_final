/// Interface for queue persistence and database operations
abstract class IQueuePersistenceManager {
  /// Create queue tables if they don't exist (idempotent)
  /// Returns true if tables were created, false if already existed
  Future<bool> createQueueTablesIfNotExist();

  /// Perform schema migrations for backward compatibility
  /// oldVersion: Current schema version in database
  /// newVersion: Target schema version
  Future<void> migrateQueueSchema({
    required int oldVersion,
    required int newVersion,
  });

  /// Get queue table statistics
  /// Returns map with keys: 'tableCount', 'rowCount', 'totalSize', 'lastVacuum'
  Future<Map<String, dynamic>> getQueueTableStats();

  /// Vacuum and optimize queue tables (defragment storage)
  /// This can be expensive (locks tables temporarily)
  /// Consider calling during maintenance windows
  Future<void> vacuumQueueTables();

  /// Backup queue data to external location
  /// Returns backup file path or null if backup failed
  Future<String?> backupQueueData();

  /// Restore queue data from backup
  /// backupPath: Path to backup file
  /// Returns true if restoration was successful
  Future<bool> restoreQueueData(String backupPath);

  /// Check queue table integrity and health
  /// Returns map with keys: 'isHealthy', 'orphanedRows', 'corruptedRows', 'issues'
  Future<Map<String, dynamic>> getQueueTableHealth();

  /// Ensure queue consistency (remove orphaned rows, fix foreign keys)
  /// Returns number of rows fixed
  Future<int> ensureQueueConsistency();
}
