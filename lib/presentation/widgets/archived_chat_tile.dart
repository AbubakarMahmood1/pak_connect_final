// Archived chat tile widget for displaying archived chat summaries
// Follows existing design patterns from chat tiles with archive-specific features

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../domain/entities/archived_chat.dart';
import '../../core/models/archive_models.dart';
import 'archive_context_menu.dart';

/// Widget for displaying archived chat information in a list tile format
class ArchivedChatTile extends ConsumerWidget {
  final ArchivedChatSummary archive;
  final VoidCallback? onTap;
  final VoidCallback? onRestore;
  final VoidCallback? onDelete;
  final bool isSelected;
  final bool showContextMenu;
  
  const ArchivedChatTile({
    super.key,
    required this.archive,
    this.onTap,
    this.onRestore,
    this.onDelete,
    this.isSelected = false,
    this.showContextMenu = true,
  });
  
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      elevation: isSelected ? 4 : 1,
      color: isSelected ? colorScheme.primaryContainer.withValues() : null,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              // Archive icon with status indicator
              _buildArchiveIcon(context),
              
              const SizedBox(width: 12),
              
              // Main content
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Contact name and archive status
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            archive.contactName,
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w600,
                              color: isSelected ? colorScheme.onPrimaryContainer : null,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        _buildArchiveStatusBadge(context),
                      ],
                    ),
                    
                    const SizedBox(height: 4),
                    
                    // Archive metadata row
                    Row(
                      children: [
                        // Message count
                        Icon(
                          Icons.chat_bubble_outline,
                          size: 14,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          '${archive.messageCount} messages',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                        
                        const SizedBox(width: 16),
                        
                        // Archive size
                        Icon(
                          Icons.storage_outlined,
                          size: 14,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          archive.formattedSize,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                        
                        // Compression indicator
                        if (archive.isCompressed) ...[
                          const SizedBox(width: 8),
                          Icon(
                            Icons.compress,
                            size: 12,
                            color: theme.colorScheme.primary,
                          ),
                        ],
                      ],
                    ),
                    
                    const SizedBox(height: 4),
                    
                    // Tags if available
                    if (archive.tags.isNotEmpty)
                      Wrap(
                        spacing: 4,
                        children: archive.tags.take(3).map((tag) => Chip(
                          label: Text(
                            tag,
                            style: const TextStyle(fontSize: 10),
                          ),
                          padding: const EdgeInsets.symmetric(horizontal: 4),
                          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          visualDensity: VisualDensity.compact,
                        )).toList(),
                      ),
                  ],
                ),
              ),
              
              // Trailing section with dates and actions
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  // Archive date
                  Text(
                    archive.ageDescription,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  
                  const SizedBox(height: 8),
                  
                  // Last message date (if available)
                  if (archive.lastMessageTime != null)
                    Text(
                      _formatLastMessageTime(archive.lastMessageTime!),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant.withValues(),
                        fontSize: 11,
                      ),
                    ),
                  
                  const SizedBox(height: 8),
                  
                  // Context menu button
                  if (showContextMenu)
                    ArchiveContextMenu(
                      archive: archive,
                      onRestore: onRestore,
                      onDelete: onDelete,
                      child: Icon(
                        Icons.more_vert,
                        size: 18,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
  
  Widget _buildArchiveIcon(BuildContext context) {
    final theme = Theme.of(context);
    
    return Container(
      width: 48,
      height: 48,
      decoration: BoxDecoration(
        color: theme.colorScheme.secondaryContainer.withValues(),
        shape: BoxShape.circle,
      ),
      child: Stack(
        alignment: Alignment.center,
        children: [
          Icon(
            Icons.person,
            color: theme.colorScheme.onSecondaryContainer,
            size: 24,
          ),
          // Archive indicator
          Positioned(
            right: 2,
            bottom: 2,
            child: Container(
              width: 16,
              height: 16,
              decoration: BoxDecoration(
                color: theme.colorScheme.tertiary,
                shape: BoxShape.circle,
                border: Border.all(
                  color: theme.colorScheme.surface,
                  width: 2,
                ),
              ),
              child: Icon(
                Icons.archive,
                size: 10,
                color: theme.colorScheme.onTertiary,
              ),
            ),
          ),
        ],
      ),
    );
  }
  
  Widget _buildArchiveStatusBadge(BuildContext context) {
    final theme = Theme.of(context);
    
    String statusText;
    Color statusColor;
    IconData statusIcon;
    
    if (!archive.isSearchable) {
      statusText = 'Not Indexed';
      statusColor = theme.colorScheme.error;
      statusIcon = Icons.search_off;
    } else if (archive.isCompressed) {
      statusText = 'Compressed';
      statusColor = theme.colorScheme.primary;
      statusIcon = Icons.compress;
    } else {
      statusText = 'Archived';
      statusColor = theme.colorScheme.tertiary;
      statusIcon = Icons.archive;
    }
    
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: statusColor.withValues(),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            statusIcon,
            size: 10,
            color: statusColor,
          ),
          const SizedBox(width: 4),
          Text(
            statusText,
            style: TextStyle(
              fontSize: 9,
              color: statusColor,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
  
  String _formatLastMessageTime(DateTime time) {
    final now = DateTime.now();
    final difference = now.difference(time);
    
    if (difference.inDays > 365) {
      return '${(difference.inDays / 365).round()}y ago';
    } else if (difference.inDays > 30) {
      return '${(difference.inDays / 30).round()}mo ago';
    } else if (difference.inDays > 7) {
      return '${(difference.inDays / 7).round()}w ago';
    } else if (difference.inDays > 0) {
      return '${difference.inDays}d ago';
    } else if (difference.inHours > 0) {
      return '${difference.inHours}h ago';
    } else if (difference.inMinutes > 0) {
      return '${difference.inMinutes}m ago';
    } else {
      return 'Just now';
    }
  }
}

/// Compact version of archived chat tile for dense lists
class CompactArchivedChatTile extends ConsumerWidget {
  final ArchivedChatSummary archive;
  final VoidCallback? onTap;
  final VoidCallback? onRestore;
  final bool isSelected;
  
  const CompactArchivedChatTile({
    super.key,
    required this.archive,
    this.onTap,
    this.onRestore,
    this.isSelected = false,
  });
  
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    
    return Material(
      color: isSelected ? colorScheme.primaryContainer.withValues() : Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              // Compact archive indicator
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: theme.colorScheme.tertiaryContainer.withValues(),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  Icons.archive,
                  size: 16,
                  color: theme.colorScheme.onTertiaryContainer,
                ),
              ),
              
              const SizedBox(width: 12),
              
              // Content
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      archive.contactName,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w500,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      '${archive.messageCount} msgs • ${archive.formattedSize}',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              
              // Restore button
              if (onRestore != null)
                IconButton(
                  onPressed: onRestore,
                  icon: Icon(
                    Icons.restore,
                    size: 18,
                    color: theme.colorScheme.primary,
                  ),
                  tooltip: 'Restore chat',
                  visualDensity: VisualDensity.compact,
                ),
              
              // Age indicator
              Text(
                archive.ageDescription,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Archive tile specifically for search results with highlighting
class SearchResultArchivedChatTile extends ConsumerWidget {
  final ArchivedChatSummary archive;
  final String searchQuery;
  final VoidCallback? onTap;
  final List<String>? highlights;
  
  const SearchResultArchivedChatTile({
    super.key,
    required this.archive,
    required this.searchQuery,
    this.onTap,
    this.highlights,
  });
  
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Header with contact name and search relevance
              Row(
                children: [
                  Icon(
                    Icons.archive,
                    size: 16,
                    color: theme.colorScheme.tertiary,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _highlightText(archive.contactName, searchQuery),
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  // Search relevance indicator
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.primaryContainer,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      'Archived',
                      style: TextStyle(
                        fontSize: 9,
                        color: theme.colorScheme.onPrimaryContainer,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ],
              ),
              
              const SizedBox(height: 8),
              
              // Archive info and highlights
              Row(
                children: [
                  Text(
                    '${archive.messageCount} messages',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '•',
                    style: TextStyle(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    archive.ageDescription,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
              
              // Highlights if available
              if (highlights != null && highlights!.isNotEmpty) ...[
                const SizedBox(height: 8),
                ...highlights!.take(2).map((highlight) => Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text(
                    _highlightText(highlight, searchQuery),
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontStyle: FontStyle.italic,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                )),
              ],
            ],
          ),
        ),
      ),
    );
  }
  
  String _highlightText(String text, String query) {
    // Simple highlighting - in a real implementation, this would use proper text highlighting
    return text; // For now, just return the original text
  }
}