// Empty state view for contacts list

import 'package:flutter/material.dart';

/// Beautiful empty state when no contacts exist
/// Note: Add contact action is handled by the FAB in ContactsScreen
class EmptyContactsView extends StatelessWidget {
  final String? searchQuery;

  const EmptyContactsView({
    super.key,
    this.searchQuery,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isSearchResult = searchQuery != null && searchQuery!.isNotEmpty;

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // Illustration
            Container(
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: theme.colorScheme.primaryContainer.withValues(alpha: 0.3),
              ),
              child: Icon(
                isSearchResult ? Icons.search_off : Icons.people_outline,
                size: 64,
                color: theme.colorScheme.primary,
              ),
            ),
            const SizedBox(height: 24),

            // Message - centered
            Text(
              isSearchResult ? 'No contacts found' : 'No contacts yet',
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w600,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),

            Text(
              isSearchResult
                  ? 'Try adjusting your search or filters'
                  : 'Add your first contact to start secure messaging',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
              textAlign: TextAlign.center,
            ),
            
            // Removed redundant "Add Contact via QR" button - use FAB instead
            // Removed instruction box - redundant with FAB
          ],
        ),
      ),
    );
  }
}
