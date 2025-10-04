// Empty state view for contacts list

import 'package:flutter/material.dart';

/// Beautiful empty state when no contacts exist
class EmptyContactsView extends StatelessWidget {
  final VoidCallback onAddContact;
  final String? searchQuery;

  const EmptyContactsView({
    super.key,
    required this.onAddContact,
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

            // Message
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

            if (!isSearchResult) ...[
              const SizedBox(height: 32),

              // Call to action
              FilledButton.icon(
                onPressed: onAddContact,
                icon: const Icon(Icons.qr_code_scanner),
                label: const Text('Add Contact via QR'),
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 24,
                    vertical: 12,
                  ),
                ),
              ),

              const SizedBox(height: 16),

              // Feature highlights
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Column(
                  children: [
                    _FeatureItem(
                      icon: Icons.qr_code,
                      title: 'Scan QR Code',
                      description: 'Exchange QR codes in person',
                    ),
                    const SizedBox(height: 12),
                    _FeatureItem(
                      icon: Icons.shield,
                      title: 'End-to-End Encrypted',
                      description: 'Messages are always secure',
                    ),
                    const SizedBox(height: 12),
                    _FeatureItem(
                      icon: Icons.offline_bolt,
                      title: 'Mesh Network',
                      description: 'No internet needed',
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _FeatureItem extends StatelessWidget {
  final IconData icon;
  final String title;
  final String description;

  const _FeatureItem({
    required this.icon,
    required this.title,
    required this.description,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Row(
      children: [
        Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: theme.colorScheme.primary.withValues(alpha: 0.15),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(
            icon,
            size: 20,
            color: theme.colorScheme.primary,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: theme.textTheme.labelLarge?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              Text(
                description,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
