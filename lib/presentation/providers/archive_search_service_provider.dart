import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pak_connect/domain/services/archive_search_service.dart';
import 'package:pak_connect/presentation/providers/di_providers.dart';

/// Provider for ArchiveSearchService singleton
final archiveSearchServiceProvider = Provider.autoDispose<ArchiveSearchService>((
  ref,
) {
  final service = resolveFromAppServicesOrServiceLocator<ArchiveSearchService>(
    fromServices: (services) => services.archiveSearchService,
    dependencyName: 'ArchiveSearchService',
  );
  ref.onDispose(() {
    // Note: ArchiveSearchService is a singleton, managed at app lifecycle level
  });
  return service;
});

/// Stream provider for search updates
final searchUpdatesProvider = StreamProvider.autoDispose<dynamic>((ref) async* {
  final service = ref.watch(archiveSearchServiceProvider);
  yield* service.searchUpdates;
});

/// Stream provider for suggestion updates
final suggestionUpdatesProvider = StreamProvider.autoDispose<dynamic>((
  ref,
) async* {
  final service = ref.watch(archiveSearchServiceProvider);
  yield* service.suggestionUpdates;
});
