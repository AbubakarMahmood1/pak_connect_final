// Detailed contact profile with stats, security, and actions

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../domain/entities/enhanced_contact.dart';
import '../../core/services/security_manager.dart';
import '../../data/repositories/contact_repository.dart';
import '../providers/contact_provider.dart';
import '../widgets/contact_avatar.dart';
import '../widgets/security_level_badge.dart' as security_badge;
import '../widgets/trust_status_badge.dart' as trust_badge;
import 'chat_screen.dart';

class ContactDetailScreen extends ConsumerStatefulWidget {
  final String publicKey;

  const ContactDetailScreen({
    super.key,
    required this.publicKey,
  });

  @override
  ConsumerState<ContactDetailScreen> createState() => _ContactDetailScreenState();
}

class _ContactDetailScreenState extends ConsumerState<ContactDetailScreen> {
  bool _isDeleting = false;

  Future<void> _verifyContact() async {
    final messenger = ScaffoldMessenger.of(context);

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Verify Contact'),
        content: const Text(
          'Mark this contact as verified?\n\n'
          'Only do this if you\'ve confirmed their identity in person.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Verify'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    // Perform verification
    final success = await ref.read(verifyContactProvider(widget.publicKey).future);

    if (!mounted) return;

    if (success) {
      messenger.showSnackBar(
        const SnackBar(
          content: Row(
            children: [
              Icon(Icons.verified, color: Colors.white),
              SizedBox(width: 8),
              Text('Contact verified'),
            ],
          ),
          backgroundColor: Color(0xFF1976D2),
        ),
      );
      // Refresh the detail view
      ref.invalidate(contactDetailProvider(widget.publicKey));
    } else {
      messenger.showSnackBar(
        const SnackBar(
          content: Text('Failed to verify contact'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  Future<void> _deleteContact(EnhancedContact contact) async {
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Contact'),
        content: Text(
          'Delete ${contact.displayName}?\n\n'
          'This will remove the contact and all cached security data. '
          'Chat history will be preserved.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    setState(() => _isDeleting = true);

    try {
      final result = await ref.read(deleteContactProvider(widget.publicKey).future);

      if (!mounted) return;

      if (result.success) {
        messenger.showSnackBar(
          SnackBar(
            content: Text('${contact.displayName} deleted'),
            action: SnackBarAction(
              label: 'OK',
              onPressed: () {},
            ),
          ),
        );
        navigator.pop(); // Go back to contacts list
      } else {
        messenger.showSnackBar(
          SnackBar(
            content: Text('Failed to delete: ${result.message}'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isDeleting = false);
      }
    }
  }

  Future<void> _resetSecurity(EnhancedContact contact) async {
    final messenger = ScaffoldMessenger.of(context);

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Reset Security'),
        content: const Text(
          'Reset security level to Low?\n\n'
          'This will:\n'
          '• Clear all cached encryption keys\n'
          '• Reset trust status to "New"\n'
          '• Require re-pairing for secure messaging\n\n'
          'Use this if you suspect a security issue.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            child: const Text('Reset'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    try {
      final repository = ref.read(contactRepositoryProvider);
      final success = await repository.resetContactSecurity(
        widget.publicKey,
        'User-initiated security reset',
      );

      if (!mounted) return;

      if (success) {
        messenger.showSnackBar(
          const SnackBar(
            content: Text('Security reset to low level'),
          ),
        );
        // Refresh the detail view
        ref.invalidate(contactDetailProvider(widget.publicKey));
      } else {
        messenger.showSnackBar(
          const SnackBar(
            content: Text('Failed to reset security'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(
          content: Text('Error: $e'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  void _sendMessage(EnhancedContact contact) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => ChatScreen(
          contactPublicKey: contact.publicKey,
          contactName: contact.displayName,
        ),
      ),
    );
  }

  void _copyPublicKey() {
    Clipboard.setData(ClipboardData(text: widget.publicKey));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Public key copied to clipboard'),
        duration: Duration(seconds: 1),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final contactAsync = ref.watch(contactDetailProvider(widget.publicKey));

    return Scaffold(
      appBar: AppBar(
        title: const Text('Contact Details'),
        actions: [
          contactAsync.whenOrNull(
            data: (contact) => contact != null
                ? PopupMenuButton<String>(
                    onSelected: (value) {
                      switch (value) {
                        case 'verify':
                          _verifyContact();
                          break;
                        case 'reset':
                          _resetSecurity(contact);
                          break;
                        case 'copy':
                          _copyPublicKey();
                          break;
                        case 'delete':
                          _deleteContact(contact);
                          break;
                      }
                    },
                    itemBuilder: (context) => [
                      if (contact.trustStatus != TrustStatus.verified)
                        const PopupMenuItem(
                          value: 'verify',
                          child: Row(
                            children: [
                              Icon(Icons.verified),
                              SizedBox(width: 8),
                              Text('Verify Contact'),
                            ],
                          ),
                        ),
                      const PopupMenuItem(
                        value: 'copy',
                        child: Row(
                          children: [
                            Icon(Icons.copy),
                            SizedBox(width: 8),
                            Text('Copy Public Key'),
                          ],
                        ),
                      ),
                      if (contact.securityLevel != SecurityLevel.low)
                        const PopupMenuItem(
                          value: 'reset',
                          child: Row(
                            children: [
                              Icon(Icons.security),
                              SizedBox(width: 8),
                              Text('Reset Security'),
                            ],
                          ),
                        ),
                      const PopupMenuDivider(),
                      const PopupMenuItem(
                        value: 'delete',
                        child: Row(
                          children: [
                            Icon(Icons.delete, color: Colors.red),
                            SizedBox(width: 8),
                            Text('Delete Contact', style: TextStyle(color: Colors.red)),
                          ],
                        ),
                      ),
                    ],
                  )
                : null,
          ) ??
              const SizedBox.shrink(),
        ],
      ),
      body: contactAsync.when(
        data: (contact) {
          if (contact == null) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.person_off,
                    size: 64,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'Contact not found',
                    style: theme.textTheme.titleLarge,
                  ),
                  const SizedBox(height: 24),
                  FilledButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Go Back'),
                  ),
                ],
              ),
            );
          }

          return _buildContactDetail(context, contact);
        },
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, stack) => Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.error_outline,
                size: 64,
                color: theme.colorScheme.error,
              ),
              const SizedBox(height: 16),
              Text(
                'Failed to load contact',
                style: theme.textTheme.titleLarge,
              ),
              const SizedBox(height: 8),
              Text(
                error.toString(),
                style: theme.textTheme.bodySmall,
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildContactDetail(BuildContext context, EnhancedContact contact) {
    final theme = Theme.of(context);

    return SingleChildScrollView(
      child: Column(
        children: [
          const SizedBox(height: 24),

          // Avatar and name
          LargeContactAvatar(
            displayName: contact.displayName,
            heroTag: 'contact_avatar_${contact.publicKey}',
          ),
          const SizedBox(height: 16),

          Text(
            contact.displayName,
            style: theme.textTheme.headlineMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),

          // Public key
          Container(
            margin: const EdgeInsets.symmetric(horizontal: 24),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: Text(
                    'Key: ${contact.publicKey.substring(0, 32)}...',
                    style: theme.textTheme.labelSmall?.copyWith(
                      fontFamily: 'monospace',
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.copy, size: 16),
                  onPressed: _copyPublicKey,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                  tooltip: 'Copy full key',
                ),
              ],
            ),
          ),

          const SizedBox(height: 32),

          // Security Section
          _buildSection(
            context,
            title: 'Security',
            icon: Icons.security,
            child: Column(
              children: [
                _buildInfoRow(
                  context,
                  label: 'Security Level',
                  value: security_badge.SecurityLevelBadge(
                    level: contact.securityLevel,
                    style: security_badge.BadgeStyle.chip,
                  ),
                ),
                const SizedBox(height: 12),
                _buildInfoRow(
                  context,
                  label: 'Trust Status',
                  value: trust_badge.TrustStatusBadge(
                    status: contact.trustStatus,
                    style: trust_badge.BadgeStyle.chip,
                  ),
                ),
                const SizedBox(height: 12),
                _buildInfoRow(
                  context,
                  label: 'Encryption',
                  value: Text(
                    contact.securityStatusDescription,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
                if (contact.lastSecuritySync != null) ...[
                  const SizedBox(height: 12),
                  _buildInfoRow(
                    context,
                    label: 'Last Security Sync',
                    value: Text(
                      _formatDateTime(contact.lastSecuritySync!),
                      style: theme.textTheme.bodyMedium,
                    ),
                  ),
                ],
                if (contact.needsAttention) ...[
                  const SizedBox(height: 16),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.errorContainer.withValues(alpha: 0.3),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: theme.colorScheme.error.withValues(alpha: 0.3),
                      ),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Icons.warning,
                          size: 20,
                          color: theme.colorScheme.error,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            contact.attentionReason ?? 'Needs attention',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.error,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),

          // Activity Section
          _buildSection(
            context,
            title: 'Activity',
            icon: Icons.analytics,
            child: Column(
              children: [
                _buildInfoRow(
                  context,
                  label: 'Messages Exchanged',
                  value: Text(
                    '${contact.interactionCount}',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                      color: theme.colorScheme.primary,
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                _buildInfoRow(
                  context,
                  label: 'Response Time',
                  value: Text(
                    contact.responseTimeFormatted,
                    style: theme.textTheme.bodyMedium,
                  ),
                ),
                const SizedBox(height: 12),
                _buildInfoRow(
                  context,
                  label: 'First Seen',
                  value: Text(
                    _formatDateTime(contact.firstSeen),
                    style: theme.textTheme.bodyMedium,
                  ),
                ),
                const SizedBox(height: 12),
                _buildInfoRow(
                  context,
                  label: 'Last Seen',
                  value: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (contact.isRecentlyActive)
                        Container(
                          width: 8,
                          height: 8,
                          margin: const EdgeInsets.only(right: 6),
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: theme.colorScheme.primary,
                          ),
                        ),
                      Text(
                        contact.lastSeenFormatted,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: contact.isRecentlyActive
                              ? theme.colorScheme.primary
                              : null,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),

          // Groups Section (if applicable)
          if (contact.groupMemberships.isNotEmpty)
            _buildSection(
              context,
              title: 'Groups',
              icon: Icons.group,
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: contact.groupMemberships
                    .map((group) => Chip(
                          label: Text(group),
                          avatar: const Icon(Icons.group, size: 16),
                        ))
                    .toList(),
              ),
            ),

          const SizedBox(height: 32),

          // Action buttons
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                FilledButton.icon(
                  onPressed: _isDeleting ? null : () => _sendMessage(contact),
                  icon: const Icon(Icons.send),
                  label: const Text('Send Message'),
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                ),
                const SizedBox(height: 12),
                if (contact.trustStatus != TrustStatus.verified)
                  OutlinedButton.icon(
                    onPressed: _isDeleting ? null : _verifyContact,
                    icon: const Icon(Icons.verified),
                    label: const Text('Verify Contact'),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                  ),
                if (contact.trustStatus != TrustStatus.verified)
                  const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: _isDeleting ? null : () => _deleteContact(contact),
                  icon: _isDeleting
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.delete),
                  label: Text(_isDeleting ? 'Deleting...' : 'Delete Contact'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: theme.colorScheme.error,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 48),
        ],
      ),
    );
  }

  Widget _buildSection(
    BuildContext context, {
    required String title,
    required IconData icon,
    required Widget child,
  }) {
    final theme = Theme.of(context);

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 20, color: theme.colorScheme.primary),
              const SizedBox(width: 8),
              Text(
                title,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          child,
        ],
      ),
    );
  }

  Widget _buildInfoRow(
    BuildContext context, {
    required String label,
    required Widget value,
  }) {
    final theme = Theme.of(context);

    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          label,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        value,
      ],
    );
  }

  String _formatDateTime(DateTime dateTime) {
    final now = DateTime.now();
    final difference = now.difference(dateTime);

    if (difference.inDays == 0) {
      return 'Today at ${_formatTime(dateTime)}';
    } else if (difference.inDays == 1) {
      return 'Yesterday at ${_formatTime(dateTime)}';
    } else if (difference.inDays < 7) {
      return '${difference.inDays}d ago';
    } else {
      return '${dateTime.month}/${dateTime.day}/${dateTime.year}';
    }
  }

  String _formatTime(DateTime dateTime) {
    final hour = dateTime.hour > 12 ? dateTime.hour - 12 : dateTime.hour;
    final period = dateTime.hour >= 12 ? 'PM' : 'AM';
    final minute = dateTime.minute.toString().padLeft(2, '0');
    return '$hour:$minute $period';
  }
}
