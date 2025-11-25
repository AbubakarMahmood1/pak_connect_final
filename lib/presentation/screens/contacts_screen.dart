// Modern contacts management screen with search, filter, and sort

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../domain/entities/enhanced_contact.dart';
import '../../domain/services/contact_management_service.dart';
import '../../data/repositories/contact_repository.dart';
import '../../core/services/security_manager.dart';
import '../providers/contact_provider.dart';
import '../widgets/contact_list_tile.dart';
import '../widgets/empty_contacts_view.dart';
import 'contact_detail_screen.dart';
import 'qr_contact_screen.dart';

class ContactsScreen extends ConsumerStatefulWidget {
  const ContactsScreen({super.key});

  @override
  ConsumerState<ContactsScreen> createState() => _ContactsScreenState();
}

class _ContactsScreenState extends ConsumerState<ContactsScreen> {
  final _searchController = TextEditingController();
  final _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
  }

  @override
  void dispose() {
    _searchController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _clearSearch() {
    _searchController.clear();
    ref.read(contactSearchStateProvider.notifier).setQuery('');
  }

  Future<void> _navigateToAddContact() async {
    final result = await Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => const QRContactScreen()),
    );

    if (result == true && mounted) {
      // Refresh contacts list
      ref.invalidate(contactsProvider);
      ref.invalidate(filteredContactsProvider);
    }
  }

  void _openContactDetail(EnhancedContact contact) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => ContactDetailScreen(publicKey: contact.publicKey),
      ),
    );
  }

  void _showFilterBottomSheet() {
    final currentFilter = ref.read(contactSearchStateProvider).filter;

    showModalBottomSheet(
      context: context,
      builder: (context) => _FilterBottomSheet(
        currentFilter: currentFilter,
        onApply: (filter) {
          ref.read(contactSearchStateProvider.notifier).setFilter(filter);
          Navigator.pop(context);
        },
      ),
    );
  }

  void _showSortBottomSheet() {
    final currentState = ref.read(contactSearchStateProvider);

    showModalBottomSheet(
      context: context,
      builder: (context) => _SortBottomSheet(
        currentSortBy: currentState.sortBy,
        currentAscending: currentState.ascending,
        onApply: (sortBy, ascending) {
          ref
              .read(contactSearchStateProvider.notifier)
              .setSortOption(sortBy, ascending: ascending);
          Navigator.pop(context);
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final searchState = ref.watch(contactSearchStateProvider);
    final contactsAsync = ref.watch(filteredContactsProvider);
    final statsAsync = ref.watch(contactStatsProvider);

    final hasActiveFilter =
        searchState.filter != null ||
        searchState.query.isNotEmpty ||
        searchState.sortBy != ContactSortOption.name;

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Contacts'),
            statsAsync.when(
              data: (stats) => Text(
                '${stats.totalContacts} total • ${stats.verifiedContacts} verified',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              loading: () => const SizedBox.shrink(),
              error: (error, stackTrace) => const SizedBox.shrink(),
            ),
          ],
        ),
        actions: [
          // Filter button
          Stack(
            children: [
              IconButton(
                icon: const Icon(Icons.filter_list),
                onPressed: _showFilterBottomSheet,
                tooltip: 'Filter contacts',
              ),
              if (searchState.filter != null)
                Positioned(
                  right: 8,
                  top: 8,
                  child: Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: theme.colorScheme.primary,
                    ),
                  ),
                ),
            ],
          ),
          // Sort button
          IconButton(
            icon: const Icon(Icons.sort),
            onPressed: _showSortBottomSheet,
            tooltip: 'Sort contacts',
          ),
        ],
      ),
      body: Column(
        children: [
          // Search bar
          Padding(
            padding: const EdgeInsets.all(16),
            child: TextField(
              controller: _searchController,
              decoration: InputDecoration(
                hintText: 'Search contacts...',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _searchController.text.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear),
                        onPressed: _clearSearch,
                      )
                    : null,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(16),
                  borderSide: BorderSide(color: theme.colorScheme.outline),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(16),
                  borderSide: BorderSide(color: theme.colorScheme.outline),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(16),
                  borderSide: BorderSide(
                    color: theme.colorScheme.primary,
                    width: 2,
                  ),
                ),
                filled: true,
                fillColor: theme.colorScheme.surfaceContainerHighest,
              ),
              onChanged: (value) => ref
                  .read(contactSearchStateProvider.notifier)
                  .debouncedQuery(value),
            ),
          ),

          // Active filter/sort chips
          if (hasActiveFilter)
            Container(
              height: 48,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: ListView(
                scrollDirection: Axis.horizontal,
                children: [
                  if (searchState.filter?.securityLevel != null)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: Chip(
                        label: Text(
                          'Security: ${searchState.filter!.securityLevel!.name}',
                        ),
                        deleteIcon: const Icon(Icons.close, size: 18),
                        onDeleted: () {
                          final currentFilter = searchState.filter!;
                          ref
                              .read(contactSearchStateProvider.notifier)
                              .setFilter(
                                ContactSearchFilter(
                                  trustStatus: currentFilter.trustStatus,
                                  onlyRecentlyActive:
                                      currentFilter.onlyRecentlyActive,
                                  minInteractions:
                                      currentFilter.minInteractions,
                                ),
                              );
                        },
                      ),
                    ),
                  if (searchState.filter?.trustStatus != null)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: Chip(
                        label: Text(
                          'Trust: ${searchState.filter!.trustStatus!.name}',
                        ),
                        deleteIcon: const Icon(Icons.close, size: 18),
                        onDeleted: () {
                          final currentFilter = searchState.filter!;
                          ref
                              .read(contactSearchStateProvider.notifier)
                              .setFilter(
                                ContactSearchFilter(
                                  securityLevel: currentFilter.securityLevel,
                                  onlyRecentlyActive:
                                      currentFilter.onlyRecentlyActive,
                                  minInteractions:
                                      currentFilter.minInteractions,
                                ),
                              );
                        },
                      ),
                    ),
                  if (searchState.filter?.onlyRecentlyActive ?? false)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: Chip(
                        label: const Text('Recently Active'),
                        deleteIcon: const Icon(Icons.close, size: 18),
                        onDeleted: () {
                          final currentFilter = searchState.filter!;
                          ref
                              .read(contactSearchStateProvider.notifier)
                              .setFilter(
                                ContactSearchFilter(
                                  securityLevel: currentFilter.securityLevel,
                                  trustStatus: currentFilter.trustStatus,
                                  onlyRecentlyActive: false,
                                  minInteractions:
                                      currentFilter.minInteractions,
                                ),
                              );
                        },
                      ),
                    ),
                  if (searchState.sortBy != ContactSortOption.name)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: Chip(
                        avatar: Icon(
                          searchState.ascending
                              ? Icons.arrow_upward
                              : Icons.arrow_downward,
                          size: 16,
                        ),
                        label: Text(
                          'Sort: ${_getSortLabel(searchState.sortBy)}',
                        ),
                      ),
                    ),
                  if (hasActiveFilter)
                    TextButton.icon(
                      onPressed: () {
                        ref.read(contactSearchStateProvider.notifier).reset();
                        _clearSearch();
                      },
                      icon: const Icon(Icons.clear_all, size: 18),
                      label: const Text('Clear all'),
                    ),
                ],
              ),
            ),

          // Contacts list
          Expanded(
            child: contactsAsync.when(
              data: (result) {
                if (result.contacts.isEmpty) {
                  return EmptyContactsView(searchQuery: searchState.query);
                }

                return RefreshIndicator(
                  onRefresh: () async {
                    ref.invalidate(contactsProvider);
                    ref.invalidate(filteredContactsProvider);
                  },
                  child: ListView.builder(
                    controller: _scrollController,
                    padding: const EdgeInsets.only(bottom: 80),
                    itemCount: result.contacts.length,
                    itemBuilder: (context, index) {
                      final contact = result.contacts[index];
                      return ContactListTile(
                        contact: contact,
                        onTap: () => _openContactDetail(contact),
                      );
                    },
                  ),
                );
              },
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (error, stack) => Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      Icons.error_outline,
                      size: 48,
                      color: theme.colorScheme.error,
                    ),
                    const SizedBox(height: 16),
                    Text(
                      'Failed to load contacts',
                      style: theme.textTheme.titleMedium,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      error.toString(),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _navigateToAddContact,
        icon: const Icon(Icons.qr_code_scanner),
        label: const Text('Add Contact'),
      ),
    );
  }

  String _getSortLabel(ContactSortOption option) {
    switch (option) {
      case ContactSortOption.name:
        return 'Name';
      case ContactSortOption.lastSeen:
        return 'Last Seen';
      case ContactSortOption.securityLevel:
        return 'Security';
      case ContactSortOption.interactions:
        return 'Messages';
      case ContactSortOption.dateAdded:
        return 'Date Added';
    }
  }
}

/// Filter bottom sheet
class _FilterBottomSheet extends StatefulWidget {
  final ContactSearchFilter? currentFilter;
  final Function(ContactSearchFilter?) onApply;

  const _FilterBottomSheet({
    required this.currentFilter,
    required this.onApply,
  });

  @override
  State<_FilterBottomSheet> createState() => _FilterBottomSheetState();
}

class _FilterBottomSheetState extends State<_FilterBottomSheet> {
  SecurityLevel? _selectedSecurity;
  TrustStatus? _selectedTrust;
  bool _onlyRecentlyActive = false;
  int? _minInteractions;

  @override
  void initState() {
    super.initState();
    _selectedSecurity = widget.currentFilter?.securityLevel;
    _selectedTrust = widget.currentFilter?.trustStatus;
    _onlyRecentlyActive = widget.currentFilter?.onlyRecentlyActive ?? false;
    _minInteractions = widget.currentFilter?.minInteractions;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Filter Contacts',
            style: theme.textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 24),

          // Security level filter
          Text('Security Level', style: theme.textTheme.titleSmall),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: [
              ChoiceChip(
                label: const Text('All'),
                selected: _selectedSecurity == null,
                onSelected: (_) => setState(() => _selectedSecurity = null),
              ),
              ...SecurityLevel.values.map(
                (level) => ChoiceChip(
                  label: Text(level.name),
                  selected: _selectedSecurity == level,
                  onSelected: (_) => setState(() => _selectedSecurity = level),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),

          // Trust status filter
          Text('Trust Status', style: theme.textTheme.titleSmall),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: [
              ChoiceChip(
                label: const Text('All'),
                selected: _selectedTrust == null,
                onSelected: (_) => setState(() => _selectedTrust = null),
              ),
              ...TrustStatus.values.map(
                (status) => ChoiceChip(
                  label: Text(status.name),
                  selected: _selectedTrust == status,
                  onSelected: (_) => setState(() => _selectedTrust = status),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),

          // Recently active switch
          SwitchListTile(
            title: const Text('Only Recently Active'),
            subtitle: const Text('Seen in the last 7 days'),
            value: _onlyRecentlyActive,
            onChanged: (value) => setState(() => _onlyRecentlyActive = value),
            contentPadding: EdgeInsets.zero,
          ),

          const SizedBox(height: 24),

          // Action buttons
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: () => widget.onApply(null),
                child: const Text('Clear'),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: () {
                  final filter =
                      (_selectedSecurity == null &&
                          _selectedTrust == null &&
                          !_onlyRecentlyActive &&
                          _minInteractions == null)
                      ? null
                      : ContactSearchFilter(
                          securityLevel: _selectedSecurity,
                          trustStatus: _selectedTrust,
                          onlyRecentlyActive: _onlyRecentlyActive,
                          minInteractions: _minInteractions,
                        );
                  widget.onApply(filter);
                },
                child: const Text('Apply'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Sort bottom sheet
class _SortBottomSheet extends StatefulWidget {
  final ContactSortOption currentSortBy;
  final bool currentAscending;
  final Function(ContactSortOption, bool) onApply;

  const _SortBottomSheet({
    required this.currentSortBy,
    required this.currentAscending,
    required this.onApply,
  });

  @override
  State<_SortBottomSheet> createState() => _SortBottomSheetState();
}

class _SortBottomSheetState extends State<_SortBottomSheet> {
  late ContactSortOption _selectedSort;
  late bool _ascending;

  @override
  void initState() {
    super.initState();
    _selectedSort = widget.currentSortBy;
    _ascending = widget.currentAscending;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Sort Contacts',
            style: theme.textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 16),

          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: ContactSortOption.values.map((option) {
              final label = _getSortLabel(option);
              return ChoiceChip(
                label: Text(label),
                selected: _selectedSort == option,
                onSelected: (_) => setState(() => _selectedSort = option),
              );
            }).toList(),
          ),

          const SizedBox(height: 16),
          SwitchListTile(
            title: const Text('Ascending Order'),
            value: _ascending,
            onChanged: (value) => setState(() => _ascending = value),
            contentPadding: EdgeInsets.zero,
          ),

          const SizedBox(height: 24),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              FilledButton(
                onPressed: () => widget.onApply(_selectedSort, _ascending),
                child: const Text('Apply'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  String _getSortLabel(ContactSortOption option) {
    switch (option) {
      case ContactSortOption.name:
        return 'Name';
      case ContactSortOption.lastSeen:
        return 'Last Seen';
      case ContactSortOption.securityLevel:
        return 'Security Level';
      case ContactSortOption.interactions:
        return 'Message Count';
      case ContactSortOption.dateAdded:
        return 'Date Added';
    }
  }
}
