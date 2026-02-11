// Spy Mode Reveal Dialog
// Shown when user is chatting with a friend anonymously

import 'package:flutter/material.dart';
import '../../domain/models/spy_mode_info.dart';

class SpyModeRevealDialog extends StatelessWidget {
  final SpyModeInfo info;
  final VoidCallback onReveal;
  final VoidCallback onStayAnonymous;

  const SpyModeRevealDialog({
    super.key,
    required this.info,
    required this.onReveal,
    required this.onStayAnonymous,
  });

  /// Show the dialog and return user's choice
  static Future<bool?> show({
    required BuildContext context,
    required SpyModeInfo info,
  }) {
    return showDialog<bool>(
      context: context,
      barrierDismissible: false, // Force explicit choice
      builder: (context) => SpyModeRevealDialog(
        info: info,
        onReveal: () => Navigator.pop(context, true),
        onStayAnonymous: () => Navigator.pop(context, false),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return AlertDialog(
      icon: Icon(Icons.masks, size: 48, color: theme.colorScheme.primary),
      title: Text(
        '🕵️ Anonymous Session',
        style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Info card
          Container(
            padding: EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: theme.colorScheme.primaryContainer.withValues(alpha: 0.3),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: theme.colorScheme.primary.withValues(alpha: 0.5),
                width: 1,
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      Icons.person,
                      size: 16,
                      color: theme.colorScheme.primary,
                    ),
                    SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'You\'re chatting with ${info.contactName}',
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          color: theme.colorScheme.onSurface,
                        ),
                      ),
                    ),
                  ],
                ),
                SizedBox(height: 8),
                Row(
                  children: [
                    Icon(
                      Icons.visibility_off,
                      size: 16,
                      color: theme.colorScheme.primary,
                    ),
                    SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'They don\'t know it\'s you',
                        style: TextStyle(color: theme.colorScheme.onSurface),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          SizedBox(height: 16),

          // Explanation
          Text(
            'You have Spy Mode enabled (Broadcast Hints is OFF).',
            style: theme.textTheme.bodyMedium,
          ),
          SizedBox(height: 12),
          Text(
            'Would you like to reveal your identity to ${info.contactName}?',
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
      actions: [
        // Stay anonymous
        TextButton.icon(
          onPressed: onStayAnonymous,
          icon: Icon(Icons.visibility_off),
          label: Text('Stay Anonymous'),
          style: TextButton.styleFrom(
            foregroundColor: theme.colorScheme.onSurface,
          ),
        ),

        SizedBox(width: 8),

        // Reveal identity
        FilledButton.icon(
          onPressed: onReveal,
          icon: Icon(Icons.person),
          label: Text('Reveal Identity'),
          style: FilledButton.styleFrom(
            backgroundColor: theme.colorScheme.primary,
          ),
        ),
      ],
    );
  }
}
