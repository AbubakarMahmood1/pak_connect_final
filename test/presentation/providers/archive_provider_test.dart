import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pak_connect/domain/values/id_types.dart';
import 'package:pak_connect/presentation/providers/archive_provider.dart';

void main() {
  group('archive provider state models', () {
    test('ArchiveOperationsState copyWith and active-operation flag', () {
      const initial = ArchiveOperationsState();
      expect(initial.hasActiveOperation, isFalse);

      final busy = initial.copyWith(
        isArchiving: true,
        currentOperation: 'Archiving chat...',
      );
      expect(busy.hasActiveOperation, isTrue);
      expect(busy.currentOperation, 'Archiving chat...');

      final reset = busy.copyWith(isArchiving: false, currentOperation: null);
      expect(reset.hasActiveOperation, isFalse);
    });

    test('ArchiveListFilter copyWith applies overrides', () {
      const filter = ArchiveListFilter(limit: 10, ascending: false);
      final updated = filter.copyWith(limit: 25, ascending: true);

      expect(updated.limit, 25);
      expect(updated.ascending, isTrue);
      expect(updated.searchFilter, filter.searchFilter);
    });

    test('ArchiveSearchQuery copyWith/equality/hashCode are stable', () {
      const query = ArchiveSearchQuery(query: 'hello');
      final updated = query.copyWith(limit: 20);

      expect(updated.limit, 20);
      expect(query == const ArchiveSearchQuery(query: 'hello'), isTrue);
      expect(query.hashCode, const ArchiveSearchQuery(query: 'hello').hashCode);
    });

    test('ArchiveUIState copyWith updates selected fields', () {
      const state = ArchiveUIState();
      final updated = state.copyWith(
        isSearchMode: true,
        searchQuery: 'alice',
        selectedArchiveId: const ArchiveId('archive-1'),
        showStatistics: false,
      );

      expect(updated.isSearchMode, isTrue);
      expect(updated.searchQuery, 'alice');
      expect(updated.selectedArchiveId, const ArchiveId('archive-1'));
      expect(updated.showStatistics, isFalse);
    });
  });

  group('ArchiveUIStateNotifier', () {
    test('mutations update provider state', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      final notifier = container.read(archiveUIStateProvider.notifier);

      expect(container.read(archiveUIStateProvider).isSearchMode, isFalse);

      notifier.toggleSearchMode();
      notifier.updateSearchQuery('project');
      notifier.updateFilter(const ArchiveListFilter(limit: 5));
      notifier.selectArchive(const ArchiveId('archive-7'));
      notifier.toggleStatistics();

      final current = container.read(archiveUIStateProvider);
      expect(current.isSearchMode, isTrue);
      expect(current.searchQuery, 'project');
      expect(current.currentFilter?.limit, 5);
      expect(current.selectedArchiveId, const ArchiveId('archive-7'));
      expect(current.showStatistics, isFalse);

      notifier.clearSearch();
      final cleared = container.read(archiveUIStateProvider);
      expect(cleared.isSearchMode, isFalse);
      expect(cleared.searchQuery, isEmpty);
    });
  });
}
