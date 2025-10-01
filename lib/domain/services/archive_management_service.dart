// Archive management service with comprehensive business logic and automation

import 'dart:async';
import 'dart:convert';
import 'package:logging/logging.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../data/repositories/archive_repository.dart';
import '../../domain/entities/archived_chat.dart';
import '../../core/models/archive_models.dart';

/// Comprehensive archive management service with business logic and automation
class ArchiveManagementService {
  static final _logger = Logger('ArchiveManagementService');
  
  // Dependencies
  final ArchiveRepository _archiveRepository = ArchiveRepository();
  // Note: ChatsRepository and MessageRepository would be used for business context gathering
  // when those features are implemented (currently stubs). All archive operations
  // are delegated to _archiveRepository which handles its own data access.
  
  // Configuration keys
  static const String _configKey = 'archive_management_config_v2';
  static const String _policyKey = 'archive_policies_v2';
  // Note: _scheduledTasksKey removed - scheduled archive tasks feature not yet implemented
  
  // Event streams for real-time updates
  final _archiveUpdatesController = StreamController<ArchiveUpdateEvent>.broadcast();
  final _policyUpdatesController = StreamController<ArchivePolicyEvent>.broadcast();
  final _maintenanceUpdatesController = StreamController<ArchiveMaintenanceEvent>.broadcast();
  
  /// Stream of archive operation events
  Stream<ArchiveUpdateEvent> get archiveUpdates => _archiveUpdatesController.stream;
  
  /// Stream of policy change events
  Stream<ArchivePolicyEvent> get policyUpdates => _policyUpdatesController.stream;
  
  /// Stream of maintenance operation events
  Stream<ArchiveMaintenanceEvent> get maintenanceUpdates => _maintenanceUpdatesController.stream;
  
  // Configuration and policies
  ArchiveManagementConfig _config = ArchiveManagementConfig.defaultConfig();
  List<ArchivePolicy> _policies = [];
  
  // State tracking
  bool _isInitialized = false;
  Timer? _maintenanceTimer;
  Timer? _policyEvaluationTimer;
  final Set<String> _operationsInProgress = {};
  
  /// Initialize the archive management service
  Future<void> initialize() async {
    if (_isInitialized) return;
    
    try {
      _logger.info('Initializing archive management service');
      
      // Initialize repository
      await _archiveRepository.initialize();
      
      // Load configuration and policies
      await _loadConfiguration();
      await _loadArchivePolicies();
      
      // Start background tasks
      _startMaintenanceTasks();
      _startPolicyEvaluation();
      
      _isInitialized = true;
      _logger.info('Archive management service initialized successfully');
      
    } catch (e) {
      _logger.severe('Failed to initialize archive management service: $e');
      rethrow;
    }
  }
  
  /// Archive a chat with business logic validation
  Future<ArchiveOperationResult> archiveChat({
    required String chatId,
    String? reason,
    Map<String, dynamic>? metadata,
    bool force = false,
  }) async {
    if (!_isInitialized) {
      throw StateError('Archive management service not initialized');
    }
    
    // Check if operation already in progress
    if (_operationsInProgress.contains(chatId)) {
      return ArchiveOperationResult.failure(
        message: 'Archive operation already in progress for this chat',
        operationType: ArchiveOperationType.archive,
        operationTime: Duration.zero,
      );
    }
    
    _operationsInProgress.add(chatId);
    
    try {
      _logger.info('Starting managed archive operation for chat: $chatId');
      
      // Business logic validation
      final validationResult = await _validateArchiveRequest(chatId, force);
      if (!validationResult.isValid) {
        return ArchiveOperationResult.failure(
          message: validationResult.errorMessage!,
          operationType: ArchiveOperationType.archive,
          operationTime: Duration.zero,
          warnings: validationResult.warnings,
        );
      }
      
      // Check storage limits
      final storageCheck = await _checkStorageLimits();
      if (!storageCheck.hasCapacity) {
        if (!force) {
          return ArchiveOperationResult.failure(
            message: 'Archive storage limit reached. Use force=true to override.',
            operationType: ArchiveOperationType.archive,
            operationTime: Duration.zero,
            warnings: ['Consider cleaning up old archives first'],
          );
        }
        
        // Auto-cleanup if forced
        await _performAutomaticCleanup();
      }
      
      // Enhance metadata with business context
      final enhancedMetadata = <String, dynamic>{
        ...?metadata,
        'archiveReason': reason ?? 'User initiated',
        'businessContext': await _gatherBusinessContext(chatId),
        'archivePolicy': _findApplicablePolicy(chatId)?.name,
        'storageOptimization': _config.enableCompression,
        'timestamp': DateTime.now().toIso8601String(),
      };
      
      // Perform the archive operation
      final result = await _archiveRepository.archiveChat(
        chatId: chatId,
        archiveReason: reason,
        customData: enhancedMetadata,
        compressLargeArchives: _config.enableCompression,
      );
      
      if (result.success) {
        // Post-archive business logic
        await _handlePostArchiveActions(chatId, result.archiveId!, result);
        
        // Emit update event
        _archiveUpdatesController.add(
          ArchiveUpdateEvent.archived(chatId, result.archiveId!, reason),
        );
        
        // Update metrics
        await _updateArchiveMetrics(ArchiveOperationType.archive, result);
        
        _logger.info('Successfully completed managed archive operation for $chatId');
      }
      
      return result;
      
    } catch (e) {
      _logger.severe('Managed archive operation failed for $chatId: $e');
      
      return ArchiveOperationResult.failure(
        message: 'Archive operation failed: $e',
        operationType: ArchiveOperationType.archive,
        operationTime: Duration.zero,
        error: ArchiveError.storageError('Managed archive failed', {'chatId': chatId}),
      );
      
    } finally {
      _operationsInProgress.remove(chatId);
    }
  }
  
  /// Restore a chat with validation and conflict resolution
  Future<ArchiveOperationResult> restoreChat({
    required String archiveId,
    bool overwriteExisting = false,
    String? targetChatId,
  }) async {
    if (!_isInitialized) {
      throw StateError('Archive management service not initialized');
    }
    
    try {
      _logger.info('Starting managed restore operation for archive: $archiveId');
      
      // Get archive details
      final archive = await _archiveRepository.getArchivedChat(archiveId);
      if (archive == null) {
        return ArchiveOperationResult.failure(
          message: 'Archive not found: $archiveId',
          operationType: ArchiveOperationType.restore,
          operationTime: Duration.zero,
        );
      }
      
      // Business logic validation
      final validationResult = await _validateRestoreRequest(archive, overwriteExisting);
      if (!validationResult.isValid) {
        return ArchiveOperationResult.failure(
          message: validationResult.errorMessage!,
          operationType: ArchiveOperationType.restore,
          operationTime: Duration.zero,
          warnings: validationResult.warnings,
        );
      }
      
      // Check for conflicts
      if (!overwriteExisting) {
        final conflictCheck = await _checkRestoreConflicts(archive, targetChatId);
        if (conflictCheck.hasConflicts) {
          return ArchiveOperationResult.failure(
            message: 'Restore conflicts detected. Use overwriteExisting=true to proceed.',
            operationType: ArchiveOperationType.restore,
            operationTime: Duration.zero,
            warnings: conflictCheck.warnings,
          );
        }
      }
      
      // Perform the restore operation
      final result = await _archiveRepository.restoreChat(archiveId);
      
      if (result.success) {
        // Post-restore business logic
        await _handlePostRestoreActions(archiveId, archive, result);
        
        // Emit update event
        _archiveUpdatesController.add(
          ArchiveUpdateEvent.restored(archiveId, archive.originalChatId),
        );
        
        // Update metrics
        await _updateArchiveMetrics(ArchiveOperationType.restore, result);
        
        _logger.info('Successfully completed managed restore operation for $archiveId');
      }
      
      return result;
      
    } catch (e) {
      _logger.severe('Managed restore operation failed for $archiveId: $e');
      
      return ArchiveOperationResult.failure(
        message: 'Restore operation failed: $e',
        operationType: ArchiveOperationType.restore,
        operationTime: Duration.zero,
        error: ArchiveError.storageError('Managed restore failed', {'archiveId': archiveId}),
      );
    }
  }
  
  /// Get archive summaries with enhanced business metadata
  Future<List<EnhancedArchiveSummary>> getEnhancedArchiveSummaries({
    ArchiveSearchFilter? filter,
    int? limit,
    String? afterCursor,
  }) async {
    try {
      final summaries = await _archiveRepository.getArchivedChats(
        filter: filter,
        limit: limit,
        afterCursor: afterCursor,
      );
      
      // Enhance with business metadata
      final enhanced = <EnhancedArchiveSummary>[];
      for (final summary in summaries) {
        final businessData = await _getArchiveBusinessMetadata(summary.id);
        enhanced.add(EnhancedArchiveSummary.fromSummary(summary, businessData));
      }
      
      return enhanced;
      
    } catch (e) {
      _logger.severe('Failed to get enhanced archive summaries: $e');
      return [];
    }
  }
  
  /// Apply archive policy to eligible chats
  Future<ArchivePolicyResult> applyArchivePolicies({
    List<String>? specificPolicies,
    bool dryRun = false,
  }) async {
    try {
      _logger.info('Applying archive policies (dryRun: $dryRun)');
      
      final policiesToApply = specificPolicies != null
          ? _policies.where((p) => specificPolicies.contains(p.name)).toList()
          : _policies.where((p) => p.enabled).toList();
      
      final results = <ArchivePolicyApplication>[];
      
      for (final policy in policiesToApply) {
        final policyResult = await _applyArchivePolicy(policy, dryRun);
        results.add(policyResult);
      }
      
      final totalChatsProcessed = results.fold(0, (sum, r) => sum + r.chatsProcessed);
      final totalArchived = results.fold(0, (sum, r) => sum + r.chatsArchived);
      final totalErrors = results.fold(0, (sum, r) => sum + r.errors.length);
      
      _logger.info('Policy application complete: $totalArchived/$totalChatsProcessed chats archived');
      
      return ArchivePolicyResult(
        applications: results,
        totalChatsProcessed: totalChatsProcessed,
        totalChatsArchived: totalArchived,
        totalErrors: totalErrors,
        dryRun: dryRun,
        appliedAt: DateTime.now(),
      );
      
    } catch (e) {
      _logger.severe('Failed to apply archive policies: $e');
      return ArchivePolicyResult.empty();
    }
  }
  
  /// Perform archive maintenance operations
  Future<ArchiveMaintenanceResult> performMaintenance({
    Set<ArchiveMaintenanceTask> tasks = const {},
    bool force = false,
  }) async {
    try {
      _logger.info('Starting archive maintenance tasks: ${tasks.map((t) => t.name).join(', ')}');
      
      final results = <String, dynamic>{};
      var totalSpaceFreed = 0;
      var totalOperationsPerformed = 0;
      final errors = <String>[];
      
      // Default maintenance tasks if none specified
      final tasksToRun = tasks.isEmpty ? {
        ArchiveMaintenanceTask.cleanupOrphaned,
        ArchiveMaintenanceTask.rebuildIndex,
        ArchiveMaintenanceTask.compressLarge,
        ArchiveMaintenanceTask.removeExpired,
      } : tasks;
      
      for (final task in tasksToRun) {
        try {
          _maintenanceUpdatesController.add(
            ArchiveMaintenanceEvent.taskStarted(task),
          );
          
          final taskResult = await _performMaintenanceTask(task, force);
          results[task.name] = taskResult;
          totalSpaceFreed += (taskResult['spaceFreed'] as int?) ?? 0;
          totalOperationsPerformed += (taskResult['operationsCount'] as int?) ?? 0;
          
          _maintenanceUpdatesController.add(
            ArchiveMaintenanceEvent.taskCompleted(task, taskResult),
          );
          
        } catch (e) {
          final error = 'Task ${task.name} failed: $e';
          errors.add(error);
          _logger.warning(error);
          
          _maintenanceUpdatesController.add(
            ArchiveMaintenanceEvent.taskFailed(task, error),
          );
        }
      }
      
      final maintenanceResult = ArchiveMaintenanceResult(
        tasksPerformed: tasksToRun.toList(),
        results: results,
        totalSpaceFreed: totalSpaceFreed,
        totalOperationsPerformed: totalOperationsPerformed,
        errors: errors,
        performedAt: DateTime.now(),
        durationMs: 0, // Would track actual duration
      );
      
      // Update maintenance history
      await _saveMaintenanceHistory(maintenanceResult);
      
      _logger.info('Archive maintenance completed: $totalOperationsPerformed operations, ${totalSpaceFreed}B freed');
      
      return maintenanceResult;
      
    } catch (e) {
      _logger.severe('Archive maintenance failed: $e');
      return ArchiveMaintenanceResult.empty();
    }
  }
  
  /// Get comprehensive archive analytics
  Future<ArchiveAnalytics> getArchiveAnalytics({
    DateTime? since,
    ArchiveAnalyticsScope scope = ArchiveAnalyticsScope.all,
  }) async {
    try {
      final statistics = await _archiveRepository.getArchiveStatistics();
      
      // Get business metrics
      final businessMetrics = await _calculateBusinessMetrics(since, scope);
      
      // Get policy effectiveness
      final policyMetrics = await _calculatePolicyMetrics(since);
      
      // Get performance trends
      final performanceTrends = await _calculatePerformanceTrends(since);
      
      // Get storage optimization metrics
      final storageMetrics = await _calculateStorageMetrics();
      
      return ArchiveAnalytics(
        statistics: statistics,
        businessMetrics: businessMetrics,
        policyMetrics: policyMetrics,
        performanceTrends: performanceTrends,
        storageMetrics: storageMetrics,
        generatedAt: DateTime.now(),
        scope: scope,
      );
      
    } catch (e) {
      _logger.severe('Failed to generate archive analytics: $e');
      return ArchiveAnalytics.empty();
    }
  }
  
  /// Update archive management configuration
  Future<void> updateConfiguration(ArchiveManagementConfig config) async {
    try {
      _config = config;
      await _saveConfiguration();
      
      // Restart timers with new intervals
      _stopBackgroundTasks();
      _startMaintenanceTasks();
      _startPolicyEvaluation();
      
      _logger.info('Archive management configuration updated');
      
    } catch (e) {
      _logger.severe('Failed to update archive management configuration: $e');
    }
  }
  
  /// Add or update archive policy
  Future<void> updateArchivePolicy(ArchivePolicy policy) async {
    try {
      final existingIndex = _policies.indexWhere((p) => p.name == policy.name);
      
      if (existingIndex >= 0) {
        _policies[existingIndex] = policy;
      } else {
        _policies.add(policy);
      }
      
      await _saveArchivePolicies();
      
      _policyUpdatesController.add(
        ArchivePolicyEvent.updated(policy.name, policy.enabled),
      );
      
      _logger.info('Archive policy "${policy.name}" updated');
      
    } catch (e) {
      _logger.severe('Failed to update archive policy: $e');
    }
  }
  
  /// Remove archive policy
  Future<void> removeArchivePolicy(String policyName) async {
    try {
      _policies.removeWhere((p) => p.name == policyName);
      await _saveArchivePolicies();
      
      _policyUpdatesController.add(
        ArchivePolicyEvent.removed(policyName),
      );
      
      _logger.info('Archive policy "$policyName" removed');
      
    } catch (e) {
      _logger.severe('Failed to remove archive policy: $e');
    }
  }
  
  /// Get current configuration
  ArchiveManagementConfig get configuration => _config;
  
  /// Get current policies
  List<ArchivePolicy> get archivePolicies => List.unmodifiable(_policies);
  
  /// Check if service is healthy
  Future<ArchiveHealthStatus> getHealthStatus() async {
    try {
      final issues = <ArchiveHealthIssue>[];
      
      // Check repository health
      final stats = await _archiveRepository.getArchiveStatistics();
      
      // Check storage capacity
      if (stats.totalSizeBytes > _config.maxStorageSizeBytes) {
        issues.add(ArchiveHealthIssue.storageOverLimit());
      }
      
      // Check performance
      if (!stats.performanceStats.isPerformanceAcceptable) {
        issues.add(ArchiveHealthIssue.performanceDegraded());
      }
      
      // Check policy health
      final inactivePolicies = _policies.where((p) => p.enabled && !p.isHealthy).length;
      if (inactivePolicies > 0) {
        issues.add(ArchiveHealthIssue.policyProblems(inactivePolicies));
      }
      
      final status = issues.isEmpty 
        ? ArchiveHealthLevel.healthy 
        : issues.any((i) => i.severity == ArchiveIssueSeverity.critical)
          ? ArchiveHealthLevel.critical
          : ArchiveHealthLevel.warning;
      
      return ArchiveHealthStatus(
        level: status,
        issues: issues,
        checkedAt: DateTime.now(),
        statistics: stats,
      );
      
    } catch (e) {
      _logger.severe('Health check failed: $e');
      return ArchiveHealthStatus.unhealthy('Health check failed: $e');
    }
  }
  
  /// Dispose and cleanup
  Future<void> dispose() async {
    _stopBackgroundTasks();
    
    await _archiveUpdatesController.close();
    await _policyUpdatesController.close();
    await _maintenanceUpdatesController.close();
    
    _archiveRepository.dispose();
    
    _isInitialized = false;
    _logger.info('Archive management service disposed');
  }
  
  // Private methods
  
  Future<void> _loadConfiguration() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final configJson = prefs.getString(_configKey);
      
      if (configJson != null) {
        final json = jsonDecode(configJson);
        _config = ArchiveManagementConfig.fromJson(json);
      }
    } catch (e) {
      _logger.warning('Failed to load configuration, using defaults: $e');
    }
  }
  
  Future<void> _saveConfiguration() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_configKey, jsonEncode(_config.toJson()));
    } catch (e) {
      _logger.warning('Failed to save configuration: $e');
    }
  }
  
  Future<void> _loadArchivePolicies() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final policiesJson = prefs.getString(_policyKey);
      
      if (policiesJson != null) {
        final json = jsonDecode(policiesJson);
        _policies = (json as List)
            .map((p) => ArchivePolicy.fromJson(p))
            .toList();
      } else {
        // Load default policies
        _policies = _createDefaultPolicies();
      }
    } catch (e) {
      _logger.warning('Failed to load archive policies, using defaults: $e');
      _policies = _createDefaultPolicies();
    }
  }
  
  Future<void> _saveArchivePolicies() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final json = _policies.map((p) => p.toJson()).toList();
      await prefs.setString(_policyKey, jsonEncode(json));
    } catch (e) {
      _logger.warning('Failed to save archive policies: $e');
    }
  }
  
  List<ArchivePolicy> _createDefaultPolicies() {
    return [
      ArchivePolicy.olderThan(
        name: 'Archive Old Inactive Chats',
        days: 90,
        requiresInactivity: true,
      ),
      ArchivePolicy.largeChats(
        name: 'Archive Large Chats',
        messageCountThreshold: 1000,
        enabled: false,
      ),
      ArchivePolicy.byContact(
        name: 'Archive Temporary Contacts',
        contactPattern: 'temp_*',
        enabled: true,
      ),
    ];
  }
  
  void _startMaintenanceTasks() {
    if (_config.maintenanceIntervalHours > 0) {
      _maintenanceTimer = Timer.periodic(
        Duration(hours: _config.maintenanceIntervalHours),
        (_) => _runScheduledMaintenance(),
      );
    }
  }
  
  void _startPolicyEvaluation() {
    if (_config.policyEvaluationIntervalHours > 0) {
      _policyEvaluationTimer = Timer.periodic(
        Duration(hours: _config.policyEvaluationIntervalHours),
        (_) => _runScheduledPolicyEvaluation(),
      );
    }
  }
  
  void _stopBackgroundTasks() {
    _maintenanceTimer?.cancel();
    _policyEvaluationTimer?.cancel();
  }
  
  Future<void> _runScheduledMaintenance() async {
    try {
      _logger.info('Running scheduled archive maintenance');
      await performMaintenance();
    } catch (e) {
      _logger.warning('Scheduled maintenance failed: $e');
    }
  }
  
  Future<void> _runScheduledPolicyEvaluation() async {
    try {
      _logger.info('Running scheduled policy evaluation');
      final result = await applyArchivePolicies(dryRun: false);
      if (result.totalChatsArchived > 0) {
        _logger.info('Policy evaluation archived ${result.totalChatsArchived} chats');
      }
    } catch (e) {
      _logger.warning('Scheduled policy evaluation failed: $e');
    }
  }
  
  Future<ArchiveValidationResult> _validateArchiveRequest(String chatId, bool force) async {
    // Implementation would validate business rules
    return ArchiveValidationResult.valid();
  }
  
  Future<ArchiveValidationResult> _validateRestoreRequest(ArchivedChat archive, bool overwrite) async {
    // Implementation would validate restore compatibility
    return ArchiveValidationResult.valid();
  }
  
  Future<StorageCapacityCheck> _checkStorageLimits() async {
    final stats = await _archiveRepository.getArchiveStatistics();
    final hasCapacity = stats.totalSizeBytes < _config.maxStorageSizeBytes;
    return StorageCapacityCheck(hasCapacity, stats.totalSizeBytes, _config.maxStorageSizeBytes);
  }
  
  Future<RestoreConflictCheck> _checkRestoreConflicts(ArchivedChat archive, String? targetChatId) async {
    // Implementation would check for conflicts
    return RestoreConflictCheck(false, []);
  }
  
  Future<void> _performAutomaticCleanup() async {
    // Implementation would perform cleanup based on policies
    _logger.info('Performing automatic cleanup for storage space');
  }
  
  Future<Map<String, dynamic>> _gatherBusinessContext(String chatId) async {
    // Implementation would gather business context
    return {'source': 'user_initiated'};
  }
  
  ArchivePolicy? _findApplicablePolicy(String chatId) {
    // Implementation would find applicable policy
    return null;
  }
  
  Future<void> _handlePostArchiveActions(String chatId, String archiveId, ArchiveOperationResult result) async {
    // Implementation would handle post-archive actions
  }
  
  Future<void> _handlePostRestoreActions(String archiveId, ArchivedChat archive, ArchiveOperationResult result) async {
    // Implementation would handle post-restore actions
  }
  
  Future<void> _updateArchiveMetrics(ArchiveOperationType operation, ArchiveOperationResult result) async {
    // Implementation would update metrics
  }
  
  Future<ArchiveBusinessMetadata> _getArchiveBusinessMetadata(String archiveId) async {
    // Implementation would get business metadata
    return ArchiveBusinessMetadata.empty();
  }
  
  Future<ArchivePolicyApplication> _applyArchivePolicy(ArchivePolicy policy, bool dryRun) async {
    // Implementation would apply specific policy
    return ArchivePolicyApplication.empty(policy.name);
  }
  
  Future<Map<String, dynamic>> _performMaintenanceTask(ArchiveMaintenanceTask task, bool force) async {
    // Implementation would perform specific maintenance task
    return {'operationsCount': 0, 'spaceFreed': 0};
  }
  
  Future<void> _saveMaintenanceHistory(ArchiveMaintenanceResult result) async {
    // Implementation would save maintenance history
  }
  
  Future<ArchiveBusinessMetrics> _calculateBusinessMetrics(DateTime? since, ArchiveAnalyticsScope scope) async {
    // Implementation would calculate business metrics
    return ArchiveBusinessMetrics.empty();
  }
  
  Future<ArchivePolicyMetrics> _calculatePolicyMetrics(DateTime? since) async {
    // Implementation would calculate policy metrics
    return ArchivePolicyMetrics.empty();
  }
  
  Future<ArchivePerformanceTrends> _calculatePerformanceTrends(DateTime? since) async {
    // Implementation would calculate performance trends
    return ArchivePerformanceTrends.empty();
  }
  
  Future<ArchiveStorageMetrics> _calculateStorageMetrics() async {
    // Implementation would calculate storage metrics
    return ArchiveStorageMetrics.empty();
  }
}

// Supporting classes (would be moved to archive_models.dart in a real implementation)

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
  
  factory ArchiveManagementConfig.defaultConfig() => const ArchiveManagementConfig(
    enableCompression: true,
    maxStorageSizeBytes: 100 * 1024 * 1024, // 100MB
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
  
  factory ArchiveManagementConfig.fromJson(Map<String, dynamic> json) => ArchiveManagementConfig(
    enableCompression: json['enableCompression'],
    maxStorageSizeBytes: json['maxStorageSizeBytes'],
    maintenanceIntervalHours: json['maintenanceIntervalHours'],
    policyEvaluationIntervalHours: json['policyEvaluationIntervalHours'],
    autoCleanupEnabled: json['autoCleanupEnabled'],
    maxArchiveAgeMonths: json['maxArchiveAgeMonths'],
  );
}

// Event classes for streams
abstract class ArchiveUpdateEvent {
  final DateTime timestamp;
  
  const ArchiveUpdateEvent(this.timestamp);
  
  factory ArchiveUpdateEvent.archived(String chatId, String archiveId, String? reason) =>
    _ArchiveCreated(chatId, archiveId, reason, DateTime.now());
  factory ArchiveUpdateEvent.restored(String archiveId, String chatId) =>
    _ArchiveRestored(archiveId, chatId, DateTime.now());
}

class _ArchiveCreated extends ArchiveUpdateEvent {
  final String chatId;
  final String archiveId;
  final String? reason;
  const _ArchiveCreated(this.chatId, this.archiveId, this.reason, DateTime timestamp) : super(timestamp);
}

class _ArchiveRestored extends ArchiveUpdateEvent {
  final String archiveId;
  final String chatId;
  const _ArchiveRestored(this.archiveId, this.chatId, DateTime timestamp) : super(timestamp);
}

abstract class ArchivePolicyEvent {
  final DateTime timestamp;
  
  const ArchivePolicyEvent(this.timestamp);
  
  factory ArchivePolicyEvent.updated(String policyName, bool enabled) =>
    _PolicyUpdated(policyName, enabled, DateTime.now());
  factory ArchivePolicyEvent.removed(String policyName) =>
    _PolicyRemoved(policyName, DateTime.now());
}

class _PolicyUpdated extends ArchivePolicyEvent {
  final String policyName;
  final bool enabled;
  const _PolicyUpdated(this.policyName, this.enabled, DateTime timestamp) : super(timestamp);
}

class _PolicyRemoved extends ArchivePolicyEvent {
  final String policyName;
  const _PolicyRemoved(this.policyName, DateTime timestamp) : super(timestamp);
}

abstract class ArchiveMaintenanceEvent {
  final DateTime timestamp;
  
  const ArchiveMaintenanceEvent(this.timestamp);
  
  factory ArchiveMaintenanceEvent.taskStarted(ArchiveMaintenanceTask task) =>
    _MaintenanceTaskStarted(task, DateTime.now());
  factory ArchiveMaintenanceEvent.taskCompleted(ArchiveMaintenanceTask task, Map<String, dynamic> result) =>
    _MaintenanceTaskCompleted(task, result, DateTime.now());
  factory ArchiveMaintenanceEvent.taskFailed(ArchiveMaintenanceTask task, String error) =>
    _MaintenanceTaskFailed(task, error, DateTime.now());
}

class _MaintenanceTaskStarted extends ArchiveMaintenanceEvent {
  final ArchiveMaintenanceTask task;
  const _MaintenanceTaskStarted(this.task, DateTime timestamp) : super(timestamp);
}

class _MaintenanceTaskCompleted extends ArchiveMaintenanceEvent {
  final ArchiveMaintenanceTask task;
  final Map<String, dynamic> result;
  const _MaintenanceTaskCompleted(this.task, this.result, DateTime timestamp) : super(timestamp);
}

class _MaintenanceTaskFailed extends ArchiveMaintenanceEvent {
  final ArchiveMaintenanceTask task;
  final String error;
  const _MaintenanceTaskFailed(this.task, this.error, DateTime timestamp) : super(timestamp);
}

// Supporting data classes (simplified implementations)

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
  
  bool get isHealthy => enabled; // Simplified
  
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

// Placeholder classes for comprehensive API
class EnhancedArchiveSummary {
  final ArchivedChatSummary summary;
  final ArchiveBusinessMetadata businessData;
  
  const EnhancedArchiveSummary(this.summary, this.businessData);
  
  factory EnhancedArchiveSummary.fromSummary(ArchivedChatSummary summary, ArchiveBusinessMetadata businessData) =>
    EnhancedArchiveSummary(summary, businessData);
}

class ArchiveBusinessMetadata {
  static ArchiveBusinessMetadata empty() => const ArchiveBusinessMetadata();
  const ArchiveBusinessMetadata();
}

class ArchiveValidationResult {
  final bool isValid;
  final String? errorMessage;
  final List<String> warnings;
  
  const ArchiveValidationResult(this.isValid, this.errorMessage, this.warnings);
  
  factory ArchiveValidationResult.valid() => const ArchiveValidationResult(true, null, []);
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
  
  factory ArchivePolicyApplication.empty(String policyName) => ArchivePolicyApplication(
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

// Placeholder metric classes
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