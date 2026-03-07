Fail-open backup/restore allows plaintext exports on mobile - bd124d8782948191b37741e5c09036a9
Link: https://chatgpt.com/codex/security/findings/bd124d8782948191b37741e5c09036a9?sev=critical%2Chigh%2Cmedium%2Clow
Criticality: medium (attack path: medium)
Status: new

Summary:
Introduced fail-open logic in selective backup/restore: exceptions from DatabaseEncryption.getOrCreateEncryptionKey() are ignored and the database is opened without a password, allowing plaintext backups/restores on mobile.
Database encryption is intended to fail closed on mobile, but the selective backup/restore paths catch DatabaseEncryption errors and continue with a null password. This means if secure storage is unavailable (e.g., user disables device lock or keystore fails), the app will still create a backup database without encryption or will open a plaintext backup for restore. That defeats the mobile encryption-at-rest requirement and can leak all exported contacts/messages to anyone who gains access to the backup file.

Metadata:
Repo: AbubakarMahmood1/pak_connect_final
Commit: 26e0ecc
Author: 198982749+Copilot@users.noreply.github.com
Created: 07/03/2026, 15:11:03
Assignee: Unassigned
Signals: Security, Validated, Patch generated, Attack-path

Relevant lines:
/workspace/pak_connect_final/lib/data/services/export_import/selective_backup_service.dart (L45 to 67)
  Note: Backup creation ignores encryption key failures and proceeds with password: null, producing plaintext backups on mobile.
        // Get encryption key for mobile platforms
        String? encryptionKey;
        if (Platform.isAndroid || Platform.isIOS) {
          try {
            encryptionKey = await DatabaseEncryption.getOrCreateEncryptionKey();
            _logger.fine('Using encryption key for backup database');
          } catch (e) {
            _logger.warning('Failed to get encryption key for backup: $e');
            // Continue without encryption for backup
          }
        }
  
        // Open database with platform-specific options
        final backupDb = Platform.isAndroid || Platform.isIOS
            ? await factory.openDatabase(
                backupPath,
                options: sqlcipher.OpenDatabaseOptions(
                  version: 1,
                  onCreate: (db, version) async {
                    await _createSelectiveSchema(db, exportType);
                  },
                  password: encryptionKey, // Encrypt backup on mobile platforms
                ),

/workspace/pak_connect_final/lib/data/services/export_import/selective_restore_service.dart (L37 to 56)
  Note: Restore path logs encryption key failure and still opens the backup without a password, permitting unencrypted backups to be restored.
        // Get encryption key for mobile platforms
        String? encryptionKey;
        if (Platform.isAndroid || Platform.isIOS) {
          try {
            encryptionKey = await DatabaseEncryption.getOrCreateEncryptionKey();
            _logger.fine('Using encryption key to open backup database');
          } catch (e) {
            _logger.warning('Failed to get encryption key for restore: $e');
            // Try opening without encryption
          }
        }
  
        // Open database with platform-specific options
        final backupDb = Platform.isAndroid || Platform.isIOS
            ? await factory.openDatabase(
                backupPath,
                options: sqlcipher.OpenDatabaseOptions(
                  readOnly: true,
                  password: encryptionKey, // Use encryption key on mobile platforms
                ),


Validation:
Rubric:
- [x] Confirm selective backup catches encryption key failure and proceeds with null password on mobile.
- [x] Confirm selective restore catches encryption key failure and proceeds with null password on mobile.
- [x] Verify DatabaseEncryption fails closed by throwing on secure storage failure.
- [x] Verify DatabaseHelper rethrows encryption errors on mobile (intended fail-closed design).
- [ ] Demonstrate runtime reproduction (blocked: missing Dart/Flutter, valgrind, gdb).
Report:
Rubric-driven validation: runtime reproduction could not be executed because Dart/Flutter toolchain is not installed (`dart --version`/`flutter --version` returned command not found). Valgrind and gdb are also unavailable, blocking crash/valgrind/debugger attempts. Code review shows selective backup/restore paths explicitly swallow encryption key failures and proceed with a null password on mobile: SelectiveBackupService catches exceptions from DatabaseEncryption.getOrCreateEncryptionKey (selective_backup_service.dart:45-54) and still opens the SQLCipher DB with `password: encryptionKey` (line 66), which will be null if key retrieval fails. SelectiveRestoreService mirrors this fail-open behavior (selective_restore_service.dart:37-46, 50-56). This conflicts with the intended fail-closed behavior in DatabaseEncryption.getOrCreateEncryptionKey, which throws DatabaseEncryptionException on secure storage failure (database_encryption.dart:33-78), and DatabaseHelper rethrows on mobile to enforce encryption (database_helper.dart:69-78). Therefore, if secure storage is unavailable, selective backups/restores can proceed without encryption, enabling plaintext backup/restore on mobile platforms.

Proposed patch:
diff --git a/lib/data/services/export_import/selective_backup_service.dart b/lib/data/services/export_import/selective_backup_service.dart
index b1190e36989122752a70a1f2c20dd9afa5180f32..534d510d93f53a2d6e2adcaffa2cf3229ba357e4 100644
--- a/lib/data/services/export_import/selective_backup_service.dart
+++ b/lib/data/services/export_import/selective_backup_service.dart
@@ -20,64 +20,62 @@ class SelectiveBackupService {
 
       final db = await DatabaseHelper.database;
 
       // Determine backup directory
       String backupDir;
       if (customBackupDir != null) {
         backupDir = customBackupDir;
       } else {
         final dbPath = await DatabaseHelper.getDatabasePath();
         backupDir = join(dirname(dbPath), 'selective_backups');
       }
 
       await Directory(backupDir).create(recursive: true);
 
       final timestamp = DateTime.now().millisecondsSinceEpoch;
       final backupPath = join(
         backupDir,
         'selective_${exportType.name}_$timestamp.db',
       );
 
       // Create a new database with selected tables
       final factory = Platform.isAndroid || Platform.isIOS
           ? sqlcipher.databaseFactory
           : sqflite_common.databaseFactory;
 
-      // Get encryption key for mobile platforms
-      String? encryptionKey;
-      if (Platform.isAndroid || Platform.isIOS) {
-        try {
-          encryptionKey = await DatabaseEncryption.getOrCreateEncryptionKey();
-          _logger.fine('Using encryption key for backup database');
-        } catch (e) {
-          _logger.warning('Failed to get encryption key for backup: $e');
-          // Continue without encryption for backup
-        }
+      final isMobilePlatform = Platform.isAndroid || Platform.isIOS;
+
+      // Enforce fail-closed behavior on mobile: backups must always be encrypted.
+      final encryptionKey = isMobilePlatform
+          ? await DatabaseEncryption.getOrCreateEncryptionKey()
+          : null;
+      if (isMobilePlatform) {
+        _logger.fine('Using encryption key for backup database');
       }
 
       // Open database with platform-specific options
-      final backupDb = Platform.isAndroid || Platform.isIOS
+      final backupDb = isMobilePlatform
           ? await factory.openDatabase(
               backupPath,
               options: sqlcipher.SqlCipherOpenDatabaseOptions(
                 version: 1,
                 onCreate: (db, version) async {
                   await _createSelectiveSchema(db, exportType);
                 },
                 password: encryptionKey, // Encrypt backup on mobile platforms
               ),
             )
           : await factory.openDatabase(
               backupPath,
               options: sqflite_common.OpenDatabaseOptions(
                 version: 1,
                 onCreate: (db, version) async {
                   await _createSelectiveSchema(db, exportType);
                 },
                 // No password parameter for sqflite_common
               ),
             );
 
       // Copy data based on export type
       int recordCount = 0;
       switch (exportType) {
         case ExportType.contactsOnly:


diff --git a/lib/data/services/export_import/selective_restore_service.dart b/lib/data/services/export_import/selective_restore_service.dart
index 50d70d78f4e0476d13dbd38a2a46f8c462edbda2..6496276daa964f7d8fbfb6da8e11e60b880a507b 100644
--- a/lib/data/services/export_import/selective_restore_service.dart
+++ b/lib/data/services/export_import/selective_restore_service.dart
@@ -12,64 +12,62 @@ import 'export_bundle.dart';
 class SelectiveRestoreService {
   static final _logger = Logger('SelectiveRestoreService');
 
   /// Restore selective backup
   static Future<SelectiveRestoreResult> restoreSelectiveBackup({
     required String backupPath,
     required ExportType exportType,
     bool clearExistingData = false,
   }) async {
     try {
       _logger.info('Restoring selective backup: ${exportType.name}');
 
       final backupFile = File(backupPath);
       if (!await backupFile.exists()) {
         return SelectiveRestoreResult(
           success: false,
           errorMessage: 'Backup file not found: $backupPath',
         );
       }
 
       // Open backup database
       final factory = Platform.isAndroid || Platform.isIOS
           ? sqlcipher.databaseFactory
           : sqflite_common.databaseFactory;
 
-      // Get encryption key for mobile platforms
-      String? encryptionKey;
-      if (Platform.isAndroid || Platform.isIOS) {
-        try {
-          encryptionKey = await DatabaseEncryption.getOrCreateEncryptionKey();
-          _logger.fine('Using encryption key to open backup database');
-        } catch (e) {
-          _logger.warning('Failed to get encryption key for restore: $e');
-          // Try opening without encryption
-        }
+      final isMobilePlatform = Platform.isAndroid || Platform.isIOS;
+
+      // Enforce fail-closed behavior on mobile: restores require encrypted backups.
+      final encryptionKey = isMobilePlatform
+          ? await DatabaseEncryption.getOrCreateEncryptionKey()
+          : null;
+      if (isMobilePlatform) {
+        _logger.fine('Using encryption key to open backup database');
       }
 
       // Open database with platform-specific options
-      final backupDb = Platform.isAndroid || Platform.isIOS
+      final backupDb = isMobilePlatform
           ? await factory.openDatabase(
               backupPath,
               options: sqlcipher.SqlCipherOpenDatabaseOptions(
                 readOnly: true,
                 password:
                     encryptionKey, // Use encryption key on mobile platforms
               ),
             )
           : await factory.openDatabase(
               backupPath,
               options: sqflite_common.OpenDatabaseOptions(
                 readOnly: true,
                 // No password parameter for sqflite_common
               ),
             );
 
       // Get target database
       final targetDb = await DatabaseHelper.database;
 
       int recordsRestored = 0;
 
       switch (exportType) {
         case ExportType.contactsOnly:
           recordsRestored = await _restoreContactsOnly(
             backupDb,

Attack-path analysis:
Final: medium | Decider: model_decided | Matrix severity: ignore | Policy adjusted: ignore
Rationale: Impact is meaningful (plaintext disclosure of contacts/messages) and the code clearly permits it when secure storage fails, so it is a real vulnerability. However, exploitation requires a secure storage failure and local/file access to the backup, limiting likelihood. Medium severity is appropriate given confidentiality impact and constrained reachability.
Likelihood: low - Requires secure storage failure and user action to create/restore a selective backup; exploitation also needs local/file access to the backup. These preconditions reduce likelihood.
Impact: medium - If a selective backup is created without encryption, the backup file can expose message and contact data to anyone who obtains it, violating at-rest confidentiality expectations on mobile.
Assumptions:
- Selective backup/restore flows are reachable in production mobile builds (not test-only).
- Selective backups can be stored or shared in a way that an attacker with local/file access could obtain them.
- Secure storage failures (e.g., device lock disabled or keystore error) can occur at runtime on mobile.
- Android/iOS platform
- Secure storage/key retrieval failure
- User triggers selective backup or restore
Path:
n1 -> n2 -> n3 -> n4
Narrative:
Selective backup/restore swallows DatabaseEncryption failures and still opens the SQLCipher database with a null password on Android/iOS, producing or consuming plaintext backups. This contradicts the intended fail-closed behavior in DatabaseEncryption and DatabaseHelper. If secure storage is unavailable, a selective backup can be created without encryption, so any party with access to the backup file can read contacts/messages.
Evidence:
- [object Object]
- [object Object]
- [object Object]
- [object Object]
Controls:
- SQLCipher encryption on mobile for primary database
- DatabaseEncryption fail-closed design (throws on secure storage failure)
- Platform gating for encryption support
Blindspots:
- No runtime verification of whether selective backups are exposed outside app-private storage.
- UI/UX flows that invoke selective backup/restore were not reviewed in this pass.
- Platform-specific filesystem and permission behaviors were not validated.