import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pak_connect/domain/services/archive_management_service.dart';

/// Provider for ArchiveManagementService singleton
final archiveManagementServiceProvider =
    Provider.autoDispose<ArchiveManagementService>((ref) {
      final service = ArchiveManagementService.instance;
      ref.onDispose(() {
        // Note: ArchiveManagementService is a singleton, managed at app lifecycle level
      });
      return service;
    });

/// Stream provider for archive updates
final archiveUpdatesProvider = StreamProvider.autoDispose<dynamic>((
  ref,
) async* {
  final service = ref.watch(archiveManagementServiceProvider);
  yield* service.archiveUpdates;
});

/// Stream provider for policy updates
final policyUpdatesProvider = StreamProvider.autoDispose<dynamic>((ref) async* {
  final service = ref.watch(archiveManagementServiceProvider);
  yield* service.policyUpdates;
});

/// Stream provider for maintenance updates
final maintenanceUpdatesProvider = StreamProvider.autoDispose<dynamic>((
  ref,
) async* {
  final service = ref.watch(archiveManagementServiceProvider);
  yield* service.maintenanceUpdates;
});
