/// Tests for ArchiveMaintenance and ArchivePolicyEngine
/// Covers: performMaintenance all task branches, error accumulation,
/// applyPolicies filtering, validateArchiveRequest, validateRestoreRequest,
/// checkRestoreConflicts, findApplicablePolicy
library;
import 'package:flutter_test/flutter_test.dart';

import 'package:pak_connect/domain/entities/archived_chat.dart';
import 'package:pak_connect/domain/interfaces/i_archive_repository.dart';
import 'package:pak_connect/domain/models/archive_models.dart';
import 'package:pak_connect/domain/services/archive_maintenance.dart';
import 'package:pak_connect/domain/services/archive_management_models.dart';
import 'package:pak_connect/domain/services/archive_policy_engine.dart';
import 'package:pak_connect/domain/values/id_types.dart';

void main() {
 group('ArchiveMaintenance', () {
 late ArchiveMaintenance maintenance;

 setUp(() {
 maintenance = ArchiveMaintenance(archiveRepository: _FakeArchiveRepository(),
);
 });

 test('performMaintenance runs all 4 tasks by default', () async {
 final result = await maintenance.performMaintenance();
 expect(result.tasksPerformed.length, 4);
 expect(result.tasksPerformed,
 containsAll([
 ArchiveMaintenanceTask.cleanupOrphaned,
 ArchiveMaintenanceTask.rebuildIndex,
 ArchiveMaintenanceTask.compressLarge,
 ArchiveMaintenanceTask.removeExpired,
]),
);
 expect(result.totalSpaceFreed, 0);
 expect(result.totalOperationsPerformed, 0);
 expect(result.errors, isEmpty);
 });

 test('performMaintenance runs specific tasks only', () async {
 final result = await maintenance.performMaintenance(tasks: {ArchiveMaintenanceTask.cleanupOrphaned},
);
 expect(result.tasksPerformed.length, 1);
 expect(result.tasksPerformed.first, ArchiveMaintenanceTask.cleanupOrphaned);
 });

 test('performMaintenance runs subset of tasks', () async {
 final result = await maintenance.performMaintenance(tasks: {
 ArchiveMaintenanceTask.rebuildIndex,
 ArchiveMaintenanceTask.compressLarge,
 },
);
 expect(result.tasksPerformed.length, 2);
 });

 test('performMaintenance with force flag', () async {
 final result = await maintenance.performMaintenance(force: true);
 expect(result.tasksPerformed.length, 4);
 expect(result.errors, isEmpty);
 });

 test('performMaintenance result has performedAt timestamp', () async {
 final before = DateTime.now();
 final result = await maintenance.performMaintenance();
 expect(result.performedAt.isAfter(before.subtract(const Duration(seconds: 1))), isTrue);
 });

 test('performMaintenance result has results map', () async {
 final result = await maintenance.performMaintenance(tasks: {ArchiveMaintenanceTask.removeExpired},
);
 expect(result.results.containsKey('removeExpired'), isTrue);
 final taskResult = result.results['removeExpired'] as Map<String, dynamic>;
 expect(taskResult['operationsCount'], 0);
 expect(taskResult['spaceFreed'], 0);
 });
 });

 group('ArchivePolicyEngine', () {
 late ArchivePolicyEngine engine;

 setUp(() {
 engine = ArchivePolicyEngine(archiveRepository: _FakeArchiveRepository(),
);
 });

 test('applyPolicies with no policies returns empty result', () async {
 final result = await engine.applyPolicies();
 expect(result.applications, isEmpty);
 expect(result.totalChatsProcessed, 0);
 expect(result.totalChatsArchived, 0);
 expect(result.dryRun, isFalse);
 });

 test('applyPolicies with dryRun flag', () async {
 engine.policies = [
 ArchivePolicy.byContact(name: 'TestPolicy',
 contactPattern: '*',
 enabled: true,
),
];
 final result = await engine.applyPolicies(dryRun: true);
 expect(result.dryRun, isTrue);
 expect(result.applications.length, 1);
 });

 test('applyPolicies filters by specific policy names', () async {
 engine.policies = [
 ArchivePolicy.byContact(name: 'PolicyA',
 contactPattern: '*',
 enabled: true,
),
 ArchivePolicy.byContact(name: 'PolicyB',
 contactPattern: '*',
 enabled: true,
),
];
 final result = await engine.applyPolicies(specificPolicies: ['PolicyA'],
);
 expect(result.applications.length, 1);
 });

 test('applyPolicies only applies enabled policies', () async {
 engine.policies = [
 ArchivePolicy.byContact(name: 'Enabled',
 contactPattern: '*',
 enabled: true,
),
 ArchivePolicy.byContact(name: 'Disabled',
 contactPattern: '*',
 enabled: false,
),
];
 final result = await engine.applyPolicies();
 expect(result.applications.length, 1);
 });

 test('validateArchiveRequest returns valid', () async {
 final result = await engine.validateArchiveRequest(const ChatId('chat_1'),
 false,
);
 expect(result.isValid, isTrue);
 });

 test('validateArchiveRequest with force returns valid', () async {
 final result = await engine.validateArchiveRequest(const ChatId('chat_1'),
 true,
);
 expect(result.isValid, isTrue);
 });

 test('validateRestoreRequest returns valid', () async {
 final archive = _buildArchivedChat();
 final result = await engine.validateRestoreRequest(archive, false);
 expect(result.isValid, isTrue);
 });

 test('checkRestoreConflicts returns no conflicts', () async {
 final archive = _buildArchivedChat();
 final result = await engine.checkRestoreConflicts(archive,
 const ChatId('target'),
);
 expect(result.hasConflicts, isFalse);
 expect(result.warnings, isEmpty);
 });

 test('findApplicablePolicy returns null (stubbed)', () {
 final policy = engine.findApplicablePolicy(const ChatId('any'));
 expect(policy, isNull);
 });

 test('config can be set and read', () {
 engine.config = const ArchiveManagementConfig(enableCompression: false,
 maxStorageSizeBytes: 1024,
 maintenanceIntervalHours: 1,
 policyEvaluationIntervalHours: 1,
 autoCleanupEnabled: false,
 maxArchiveAgeMonths: 3,
);
 expect(engine.config.enableCompression, isFalse);
 expect(engine.config.maxArchiveAgeMonths, 3);
 });

 test('policies can be set and read', () {
 expect(engine.policies, isEmpty);
 engine.policies = [
 ArchivePolicy.byContact(name: 'Test',
 contactPattern: 'a*',
 enabled: true,
),
];
 expect(engine.policies.length, 1);
 });
 });
}

ArchivedChat _buildArchivedChat() {
 return ArchivedChat(id: const ArchiveId('arch_1'),
 originalChatId: const ChatId('chat_1'),
 contactPublicKey: 'pk1',
 contactName: 'Alice',
 archivedAt: DateTime(2026, 1, 1),
 messages: const [],
 messageCount: 0,
 metadata: const ArchiveMetadata(version: '1.0',
 reason: 'test',
 originalUnreadCount: 0,
 wasOnline: false,
 hadUnsentMessages: false,
 estimatedStorageSize: 0,
 archiveSource: 'test',
 tags: [],
),
);
}

class _FakeArchiveRepository implements IArchiveRepository {
 @override
 Future<void> initialize() async {}
 @override
 Future<ArchiveOperationResult> archiveChat({
 required String chatId,
 String? archiveReason,
 Map<String, dynamic>? customData,
 bool compressLargeArchives = true,
 }) async =>
 throw UnimplementedError();
 @override
 Future<ArchiveOperationResult> restoreChat(ArchiveId archiveId) async =>
 throw UnimplementedError();
 @override
 Future<List<ArchivedChatSummary>> getArchivedChats({
 ArchiveSearchFilter? filter,
 int? limit,
 int? offset,
 }) async =>
 [];
 @override
 Future<ArchivedChatSummary?> getArchivedChatByOriginalId(String chatId,
) async =>
 null;
 @override
 Future<ArchivedChat?> getArchivedChat(ArchiveId archiveId) async => null;
 @override
 Future<int> getArchivedChatsCount() async => 0;
 @override
 Future<ArchiveStatistics?> getArchiveStatistics() async => null;
 @override
 Future<ArchiveSearchResult> searchArchives({
 required String query,
 ArchiveSearchFilter? filter,
 int? limit,
 String? afterCursor,
 }) async =>
 throw UnimplementedError();
 @override
 Future<void> permanentlyDeleteArchive(ArchiveId archivedChatId) async {}
 @override
 void clearCache() {}
 @override
 Future<void> dispose() async {}
}
