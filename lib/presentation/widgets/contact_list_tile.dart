// Modern contact list tile with rich information display

import 'package:flutter/material.dart';
import '../../domain/entities/enhanced_contact.dart';
import 'contact_avatar.dart';
import 'security_level_badge.dart' as security_badge;
import 'trust_status_badge.dart' as trust_badge;

/// Beautiful list tile displaying contact information
class ContactListTile extends StatelessWidget {
  final EnhancedContact contact;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final bool showInteractionStats;
  final bool isSelected;

  const ContactListTile({
    super.key,
    required this.contact,
    required this.onTap,
    this.onLongPress,
    this.showInteractionStats = true,
    this.isSelected = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      elevation: isSelected ? 2 : 0,
      color: isSelected
          ? theme.colorScheme.primaryContainer.withValues(alpha: 0.3)
          : theme.colorScheme.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(
          color: isSelected
              ? theme.colorScheme.primary
              : theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
          width: isSelected ? 2 : 1,
        ),
      ),
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              // Avatar with hero animation support
              Hero(
                tag: 'contact_avatar_${contact.publicKey}',
                child: ContactAvatar(
                  displayName: contact.displayName,
                  radius: 24,
                ),
              ),
              const SizedBox(width: 12),

              // Contact info
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Name with attention indicator
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            contact.displayName,
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w600,
                              letterSpacing: 0.1,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (contact.needsAttention) ...[
                          const SizedBox(width: 4),
                          Tooltip(
                            message:
                                contact.attentionReason ?? 'Needs attention',
                            child: Icon(
                              Icons.error_outline,
                              size: 16,
                              color: theme.colorScheme.error,
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 6),

                    // Security and trust badges
                    Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      children: [
                        security_badge.SecurityLevelBadge(
                          level: contact.securityLevel,
                          style: security_badge.BadgeStyle.compact,
                        ),
                        trust_badge.TrustStatusBadge(
                          status: contact.trustStatus,
                          style: trust_badge.BadgeStyle.compact,
                        ),
                      ],
                    ),

                    if (showInteractionStats) ...[
                      const SizedBox(height: 6),
                      // Activity stats
                      Row(
                        children: [
                          Icon(
                            Icons.access_time,
                            size: 12,
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            contact.lastSeenFormatted,
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                          if (contact.interactionCount > 0) ...[
                            const SizedBox(width: 12),
                            Icon(
                              Icons.chat_bubble_outline,
                              size: 12,
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                            const SizedBox(width: 4),
                            Text(
                              '${contact.interactionCount} msgs',
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ],
                  ],
                ),
              ),

              // Active indicator
              if (contact.isRecentlyActive)
                Container(
                  width: 8,
                  height: 8,
                  margin: const EdgeInsets.only(left: 8),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: theme.colorScheme.primary,
                    boxShadow: [
                      BoxShadow(
                        color: theme.colorScheme.primary.withValues(alpha: 0.5),
                        blurRadius: 4,
                        spreadRadius: 1,
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Compact version for smaller spaces
class CompactContactTile extends StatelessWidget {
  final EnhancedContact contact;
  final VoidCallback onTap;

  const CompactContactTile({
    super.key,
    required this.contact,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return ListTile(
      onTap: onTap,
      leading: ContactAvatar(displayName: contact.displayName, radius: 18),
      title: Text(
        contact.displayName,
        style: theme.textTheme.bodyMedium?.copyWith(
          fontWeight: FontWeight.w500,
        ),
      ),
      subtitle: Text(
        contact.securityStatusDescription,
        style: theme.textTheme.labelSmall,
      ),
      trailing: contact.isRecentlyActive
          ? Icon(Icons.circle, size: 8, color: theme.colorScheme.primary)
          : null,
    );
  }
}
