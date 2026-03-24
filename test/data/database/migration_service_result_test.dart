// MigrationService supplementary coverage
// Targets: needsMigration branches, MigrationResult model, _getUnreadCounts,
// _getLastSeenData parsing, _createBackup, checksum helpers,
// _migrateUserPreferences, needsMigration already-migrated/no-data paths

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:pak_connect/data/database/database_helper.dart';
import 'package:pak_connect/data/database/migration_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../test_helpers/test_setup.dart';

void main() {
 TestWidgetsFlutterBinding.ensureInitialized();

 final List<LogRecord> logRecords = [];
 final Set<String> allowedSevere = {};

 setUpAll(() async {
 await TestSetup.initializeTestEnvironment(dbLabel: 'migration_service_p12',
);
 });

 setUp(() async {
 logRecords.clear();
 Logger.root.level = Level.ALL;
 Logger.root.onRecord.listen(logRecords.add);
 await TestSetup.configureTestDatabase(label: 'migration_service_p12');
 TestSetup.resetSharedPreferences();
 });

 tearDown(() async {
 final severeErrors = logRecords
 .where((log) => log.level >= Level.SEVERE)
 .where((log) =>
 !allowedSevere.any((pattern) => log.message.contains(pattern)),
)
 .toList();
 expect(severeErrors,
 isEmpty,
 reason:
 'Unexpected SEVERE errors:\n${severeErrors.map((e) => '${e.level}: ${e.message}').join('\n')}',
);
 await TestSetup.nukeDatabase();
 });

 // ─── MigrationResult model ────────────────────────────────────────

 group('MigrationResult', () {
 test('toJson serializes all fields', () {
 final result = MigrationResult(success: true,
 message: 'OK',
 migrationCounts: {'contacts': 5},
 checksums: {'contacts': 'abc123'},
 duration: const Duration(milliseconds: 1234),
 backupPath: 'backup_key',
 errors: ['err1'],
 warnings: ['warn1'],
);

 final json = result.toJson();
 expect(json['success'], isTrue);
 expect(json['message'], equals('OK'));
 expect(json['migrationCounts'], equals({'contacts': 5}));
 expect(json['checksums'], equals({'contacts': 'abc123'}));
 expect(json['durationMs'], equals(1234));
 expect(json['backupPath'], equals('backup_key'));
 expect(json['errors'], equals(['err1']));
 expect(json['warnings'], equals(['warn1']));
 });

 test('toJson handles defaults', () {
 const result = MigrationResult(success: false,
 message: 'failed',
 migrationCounts: {},
 checksums: {},
 duration: Duration.zero,
);

 final json = result.toJson();
 expect(json['backupPath'], isNull);
 expect(json['errors'], isEmpty);
 expect(json['warnings'], isEmpty);
 });
 });

 // ─── needsMigration ───────────────────────────────────────────────

 group('needsMigration', () {
 test('returns false when already migrated', () async {
 SharedPreferences.setMockInitialValues({
 'sqlite_migration_completed': true,
 });

 final result = await MigrationService.needsMigration();
 expect(result, isFalse);

 final loggedAlready = logRecords.any((r) => r.message.contains('Migration already completed'),
);
 expect(loggedAlready, isTrue);
 });

 test('returns false when no data to migrate', () async {
 SharedPreferences.setMockInitialValues({});

 final result = await MigrationService.needsMigration();
 expect(result, isFalse);

 final loggedNoData = logRecords.any((r) => r.message.contains('No data to migrate'),
);
 expect(loggedNoData, isTrue);
 });

 test('returns true when messages exist', () async {
 SharedPreferences.setMockInitialValues({
 'chat_messages': [
 jsonEncode({
 'id': 'msg-1',
 'content': 'hello',
 'chatId': 'chat-1',
 }),
],
 });

 final result = await MigrationService.needsMigration();
 expect(result, isTrue);
 });

 test('returns true when contacts exist', () async {
 SharedPreferences.setMockInitialValues({
 'enhanced_contacts_v2': [
 jsonEncode({
 'publicKey': 'pk-1',
 'displayName': 'Test',
 }),
],
 });

 final result = await MigrationService.needsMigration();
 expect(result, isTrue);
 });

 test('returns true when offline queue exists', () async {
 SharedPreferences.setMockInitialValues({
 'offline_message_queue_v2': [
 jsonEncode({
 'recipientId': 'r-1',
 'content': 'queued msg',
 }),
],
 });

 final result = await MigrationService.needsMigration();
 expect(result, isTrue);
 });
 });

 // ─── migrate — error path ─────────────────────────────────────────

 group('migrate', () {
 test('handles empty prefs gracefully', () async {
 SharedPreferences.setMockInitialValues({});

 final result = await MigrationService.migrate();
 expect(result.success, isTrue);
 expect(result.migrationCounts['contacts'], equals(0));
 expect(result.migrationCounts['messages'], equals(0));
 expect(result.backupPath, isNotNull);
 });

 test('migrates user preferences into app_preferences table', () async {
 // BUG FIX: migration_service.dart previously inserted into
 // 'user_preferences' (wrong table name). Fixed to use 'app_preferences'.
 SharedPreferences.setMockInitialValues({
 'username': 'testuser',
 'device_id': 'dev-123',
 'app_version': '1.0.0',
 });

 final result = await MigrationService.migrate();
 expect(result.success, isTrue);
 // Now correctly inserts into app_preferences
 expect(result.migrationCounts['user_prefs'], equals(3));
 });

 test('migrates deleted message IDs', () async {
 SharedPreferences.setMockInitialValues({
 'deleted_message_ids_v1': [
 'del-1',
 'del-2',
 'del-3',
],
 });

 final result = await MigrationService.migrate();
 expect(result.success, isTrue);
 expect(result.migrationCounts['deleted_ids'], equals(3));
 });

 test('migrates device mappings', () async {
 SharedPreferences.setMockInitialValues({
 'device_public_key_mapping':
 'device-uuid-1:contact-pk-1,device-uuid-2:contact-pk-2',
 });

 final result = await MigrationService.migrate();
 expect(result.success, isTrue);
 expect(result.migrationCounts['device_mappings'], equals(2));
 });

 test('migrates last seen data', () async {
 // last_seen has FK to contacts — must insert contacts first
 final db = await DatabaseHelper.database;
 final now = DateTime.now().millisecondsSinceEpoch;
 await db.insert('contacts', {
 'public_key': 'pk1',
 'display_name': 'A',
 'trust_status': 0,
 'security_level': 0,
 'first_seen': now,
 'last_seen': now,
 'created_at': now,
 'updated_at': now,
 });
 await db.insert('contacts', {
 'public_key': 'pk2',
 'display_name': 'B',
 'trust_status': 0,
 'security_level': 0,
 'first_seen': now,
 'last_seen': now,
 'created_at': now,
 'updated_at': now,
 });

 SharedPreferences.setMockInitialValues({
 'contact_last_seen': 'pk1:1700000000,pk2:1700001000',
 });

 final result = await MigrationService.migrate();
 expect(result.success, isTrue);
 expect(result.migrationCounts['last_seen'], equals(2));
 });

 test('migrates contacts with chats', () async {
 final now = DateTime.now().millisecondsSinceEpoch;
 SharedPreferences.setMockInitialValues({
 'enhanced_contacts_v2': [
 jsonEncode({
 'publicKey': 'pk-test',
 'displayName': 'Alice',
 'securityLevel': 0,
 'trustStatus': 0,
 'firstSeen': now,
 'lastSeen': now,
 }),
],
 'chat_unread_counts': 'pk-test:3',
 });

 final result = await MigrationService.migrate();
 expect(result.success, isTrue);
 expect(result.migrationCounts['contacts'], equals(1));
 });

 test('sets sqlite_migration_completed flag', () async {
 SharedPreferences.setMockInitialValues({});
 await MigrationService.migrate();

 final prefs = await SharedPreferences.getInstance();
 expect(prefs.getBool('sqlite_migration_completed'), isTrue);
 });

 test('creates checksums for contacts and chats', () async {
 SharedPreferences.setMockInitialValues({
 'enhanced_contacts_v2': [
 jsonEncode({
 'publicKey': 'pk-cs',
 'displayName': 'ChecksumTest',
 }),
],
 });

 final result = await MigrationService.migrate();
 expect(result.checksums['contacts'], isNotEmpty);
 expect(result.checksums['chats'], isNotEmpty);
 expect(result.checksums['messages'], isNotEmpty);
 });
 });
}
