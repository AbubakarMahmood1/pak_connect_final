import '../models/archive_models.dart';
import '../../domain/entities/archived_chat.dart';
import '../../domain/values/id_types.dart';

class ArchiveManagementConfig {
  final bool enableCompression;
  final int maxStorageSizeBytes;
  final int maintenanceIntervalHours;
  final int policyEvaluationIntervalHours;
  final bool autoCleanupEnabled;
  final int maxArchiveAgeMonths;

  const ArchiveManagementConfig({
    required this.enableCompression,
    required this.maxStorageSizeBytes,
    required this.maintenanceIntervalHours,
    required this.policyEvaluationIntervalHours,
    required this.autoCleanupEnabled,
    required this.maxArchiveAgeMonths,
  });

  factory ArchiveManagementConfig.defaultConfig() =>
      const ArchiveManagementConfig(
        enableCompression: true,
        maxStorageSizeBytes: 100 * 1024 * 1024,
        maintenanceIntervalHours: 24,
        policyEvaluationIntervalHours: 12,
        autoCleanupEnabled: true,
        maxArchiveAgeMonths: 12,
      );

  Map<String, dynamic> toJson() => {
    'enableCompression': enableCompression,
    'maxStorageSizeBytes': maxStorageSizeBytes,
    'maintenanceIntervalHours': maintenanceIntervalHours,
    'policyEvaluationIntervalHours': policyEvaluationIntervalHours,
    'autoCleanupEnabled': autoCleanupEnabled,
    'maxArchiveAgeMonths': maxArchiveAgeMonths,
  };

  factory ArchiveManagementConfig.fromJson(Map<String, dynamic> json) =>
      ArchiveManagementConfig(
        enableCompression: json['enableCompression'],
        maxStorageSizeBytes: json['maxStorageSizeBytes'],
        maintenanceIntervalHours: json['maintenanceIntervalHours'],
        policyEvaluationIntervalHours: json['policyEvaluationIntervalHours'],
        autoCleanupEnabled: json['autoCleanupEnabled'],
        maxArchiveAgeMonths: json['maxArchiveAgeMonths'],
      );
}

class ArchivePolicy {
  final String name;
  final bool enabled;
  final Map<String, dynamic> conditions;
  final Map<String, dynamic> actions;

  const ArchivePolicy({
    required this.name,
    required this.enabled,
    required this.conditions,
    required this.actions,
  });

  factory ArchivePolicy.olderThan({
    required String name,
    required int days,
    bool requiresInactivity = false,
  }) => ArchivePolicy(
    name: name,
    enabled: true,
    conditions: {'maxAgeDays': days, 'requiresInactivity': requiresInactivity},
    actions: {'archive': true},
  );

  factory ArchivePolicy.largeChats({
    required String name,
    required int messageCountThreshold,
    bool enabled = true,
  }) => ArchivePolicy(
    name: name,
    enabled: enabled,
    conditions: {'minMessageCount': messageCountThreshold},
    actions: {'archive': true},
  );

  factory ArchivePolicy.byContact({
    required String name,
    required String contactPattern,
    bool enabled = true,
  }) => ArchivePolicy(
    name: name,
    enabled: enabled,
    conditions: {'contactPattern': contactPattern},
    actions: {'archive': true},
  );

  bool get isHealthy => enabled;

  Map<String, dynamic> toJson() => {
    'name': name,
    'enabled': enabled,
    'conditions': conditions,
    'actions': actions,
  };

  factory ArchivePolicy.fromJson(Map<String, dynamic> json) => ArchivePolicy(
    name: json['name'],
    enabled: json['enabled'],
    conditions: Map<String, dynamic>.from(json['conditions']),
    actions: Map<String, dynamic>.from(json['actions']),
  );
}

class ArchiveValidationResult {
  final bool isValid;
  final String? errorMessage;
  final List<String> warnings;

  const ArchiveValidationResult(this.isValid, this.errorMessage, this.warnings);

  factory ArchiveValidationResult.valid() =>
      const ArchiveValidationResult(true, null, []);
}

class StorageCapacityCheck {
  final bool hasCapacity;
  final int currentSize;
  final int maxSize;

  const StorageCapacityCheck(this.hasCapacity, this.currentSize, this.maxSize);
}

class RestoreConflictCheck {
  final bool hasConflicts;
  final List<String> warnings;

  const RestoreConflictCheck(this.hasConflicts, this.warnings);
}

class ArchivePolicyResult {
  final List<ArchivePolicyApplication> applications;
  final int totalChatsProcessed;
  final int totalChatsArchived;
  final int totalErrors;
  final bool dryRun;
  final DateTime appliedAt;

  const ArchivePolicyResult({
    required this.applications,
    required this.totalChatsProcessed,
    required this.totalChatsArchived,
    required this.totalErrors,
    required this.dryRun,
    required this.appliedAt,
  });

  factory ArchivePolicyResult.empty() => ArchivePolicyResult(
    applications: [],
    totalChatsProcessed: 0,
    totalChatsArchived: 0,
    totalErrors: 0,
    dryRun: true,
    appliedAt: DateTime.now(),
  );
}

class ArchivePolicyApplication {
  final String policyName;
  final int chatsProcessed;
  final int chatsArchived;
  final List<String> errors;

  const ArchivePolicyApplication({
    required this.policyName,
    required this.chatsProcessed,
    required this.chatsArchived,
    required this.errors,
  });

  factory ArchivePolicyApplication.empty(String policyName) =>
      ArchivePolicyApplication(
        policyName: policyName,
        chatsProcessed: 0,
        chatsArchived: 0,
        errors: [],
      );
}

enum ArchiveMaintenanceTask {
  cleanupOrphaned,
  rebuildIndex,
  compressLarge,
  removeExpired,
}

extension ArchiveMaintenanceTaskExt on ArchiveMaintenanceTask {
  String get name => toString().split('.').last;
}

class ArchiveMaintenanceResult {
  final List<ArchiveMaintenanceTask> tasksPerformed;
  final Map<String, dynamic> results;
  final int totalSpaceFreed;
  final int totalOperationsPerformed;
  final List<String> errors;
  final DateTime performedAt;
  final int durationMs;

  const ArchiveMaintenanceResult({
    required this.tasksPerformed,
    required this.results,
    required this.totalSpaceFreed,
    required this.totalOperationsPerformed,
    required this.errors,
    required this.performedAt,
    required this.durationMs,
  });

  factory ArchiveMaintenanceResult.empty() => ArchiveMaintenanceResult(
    tasksPerformed: [],
    results: {},
    totalSpaceFreed: 0,
    totalOperationsPerformed: 0,
    errors: [],
    performedAt: DateTime.now(),
    durationMs: 0,
  );
}

enum ArchiveAnalyticsScope { all, recent, policies }

class ArchiveAnalytics {
  final ArchiveStatistics statistics;
  final ArchiveBusinessMetrics businessMetrics;
  final ArchivePolicyMetrics policyMetrics;
  final ArchivePerformanceTrends performanceTrends;
  final ArchiveStorageMetrics storageMetrics;
  final DateTime generatedAt;
  final ArchiveAnalyticsScope scope;

  const ArchiveAnalytics({
    required this.statistics,
    required this.businessMetrics,
    required this.policyMetrics,
    required this.performanceTrends,
    required this.storageMetrics,
    required this.generatedAt,
    required this.scope,
  });

  factory ArchiveAnalytics.empty() => ArchiveAnalytics(
    statistics: ArchiveStatistics.empty(),
    businessMetrics: ArchiveBusinessMetrics.empty(),
    policyMetrics: ArchivePolicyMetrics.empty(),
    performanceTrends: ArchivePerformanceTrends.empty(),
    storageMetrics: ArchiveStorageMetrics.empty(),
    generatedAt: DateTime.now(),
    scope: ArchiveAnalyticsScope.all,
  );
}

class ArchiveBusinessMetrics {
  static ArchiveBusinessMetrics empty() => const ArchiveBusinessMetrics();
  const ArchiveBusinessMetrics();
}

class ArchivePolicyMetrics {
  static ArchivePolicyMetrics empty() => const ArchivePolicyMetrics();
  const ArchivePolicyMetrics();
}

class ArchivePerformanceTrends {
  static ArchivePerformanceTrends empty() => const ArchivePerformanceTrends();
  const ArchivePerformanceTrends();
}

class ArchiveStorageMetrics {
  static ArchiveStorageMetrics empty() => const ArchiveStorageMetrics();
  const ArchiveStorageMetrics();
}

enum ArchiveHealthLevel { healthy, warning, critical }

class ArchiveHealthStatus {
  final ArchiveHealthLevel level;
  final List<ArchiveHealthIssue> issues;
  final DateTime checkedAt;
  final ArchiveStatistics? statistics;

  const ArchiveHealthStatus({
    required this.level,
    required this.issues,
    required this.checkedAt,
    this.statistics,
  });

  factory ArchiveHealthStatus.unhealthy(String reason) => ArchiveHealthStatus(
    level: ArchiveHealthLevel.critical,
    issues: [ArchiveHealthIssue.generic(reason)],
    checkedAt: DateTime.now(),
  );
}

enum ArchiveIssueSeverity { info, warning, critical }

class ArchiveHealthIssue {
  final ArchiveIssueSeverity severity;
  final String description;
  final String? recommendation;

  const ArchiveHealthIssue({
    required this.severity,
    required this.description,
    this.recommendation,
  });

  factory ArchiveHealthIssue.storageOverLimit() => const ArchiveHealthIssue(
    severity: ArchiveIssueSeverity.critical,
    description: 'Archive storage over limit',
    recommendation: 'Clean up old archives or increase storage limit',
  );

  factory ArchiveHealthIssue.performanceDegraded() => const ArchiveHealthIssue(
    severity: ArchiveIssueSeverity.warning,
    description: 'Archive performance degraded',
    recommendation: 'Run maintenance tasks to optimize performance',
  );

  factory ArchiveHealthIssue.policyProblems(int count) => ArchiveHealthIssue(
    severity: ArchiveIssueSeverity.warning,
    description: '$count archive policies have issues',
    recommendation: 'Review and fix policy configurations',
  );

  factory ArchiveHealthIssue.generic(String description) => ArchiveHealthIssue(
    severity: ArchiveIssueSeverity.critical,
    description: description,
  );
}

class EnhancedArchiveSummary {
  final ArchivedChatSummary summary;
  final ArchiveBusinessMetadata businessData;

  const EnhancedArchiveSummary(this.summary, this.businessData);

  factory EnhancedArchiveSummary.fromSummary(
    ArchivedChatSummary summary,
    ArchiveBusinessMetadata businessData,
  ) => EnhancedArchiveSummary(summary, businessData);
}

class ArchiveBusinessMetadata {
  static ArchiveBusinessMetadata empty() => const ArchiveBusinessMetadata();
  const ArchiveBusinessMetadata();
}

class ArchivePolicyEvent {
  final DateTime timestamp;
  final ArchivePolicyEventType type;
  final String policyName;
  final bool? enabled;

  ArchivePolicyEvent.updated(this.policyName, this.enabled)
    : timestamp = DateTime.now(),
      type = ArchivePolicyEventType.updated;

  ArchivePolicyEvent.removed(this.policyName)
    : timestamp = DateTime.now(),
      type = ArchivePolicyEventType.removed,
      enabled = null;
}

enum ArchivePolicyEventType { updated, removed }

class ArchiveUpdateEvent {
  final DateTime timestamp;
  final ArchiveUpdateEventType type;
  final String chatId;
  final ArchiveId archiveId;
  final String? reason;

  ArchiveUpdateEvent.archived(this.chatId, this.archiveId, this.reason)
    : timestamp = DateTime.now(),
      type = ArchiveUpdateEventType.archived;

  ArchiveUpdateEvent.restored(this.archiveId, this.chatId)
    : timestamp = DateTime.now(),
      type = ArchiveUpdateEventType.restored,
      reason = null;
}

enum ArchiveUpdateEventType { archived, restored }

class ArchiveMaintenanceEvent {
  final DateTime timestamp;
  final ArchiveMaintenanceEventType type;
  final ArchiveMaintenanceTask task;
  final Map<String, dynamic>? result;
  final String? error;

  ArchiveMaintenanceEvent.taskStarted(this.task)
    : timestamp = DateTime.now(),
      type = ArchiveMaintenanceEventType.started,
      result = null,
      error = null;

  ArchiveMaintenanceEvent.taskCompleted(this.task, this.result)
    : timestamp = DateTime.now(),
      type = ArchiveMaintenanceEventType.completed,
      error = null;

  ArchiveMaintenanceEvent.taskFailed(this.task, this.error)
    : timestamp = DateTime.now(),
      type = ArchiveMaintenanceEventType.failed,
      result = null;
}

enum ArchiveMaintenanceEventType { started, completed, failed }
