// Spy Mode Event Listener Widget
// Listens to spy mode events and shows appropriate dialogs/notifications

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logging/logging.dart';
import '../providers/ble_providers.dart';
import '../dialogs/spy_mode_reveal_dialog.dart';
import '../../data/services/ble_state_manager.dart';

final _logger = Logger('SpyModeListener');

class SpyModeListener extends ConsumerStatefulWidget {
  final Widget child;

  const SpyModeListener({super.key, required this.child});

  @override
  ConsumerState<SpyModeListener> createState() => _SpyModeListenerState();
}

class _SpyModeListenerState extends ConsumerState<SpyModeListener> {
  @override
  Widget build(BuildContext context) {
    // Listen to spy mode detection events
    ref.listen<AsyncValue<SpyModeInfo>>(spyModeDetectedProvider, (
      previous,
      next,
    ) {
      next.whenData((info) {
        _showSpyModeRevealDialog(context, info);
      });
    });

    // Listen to identity revealed events
    ref.listen<AsyncValue<String>>(identityRevealedProvider, (previous, next) {
      next.whenData((contactName) {
        _showIdentityRevealedNotification(context, contactName);
      });
    });

    return widget.child;
  }

  /// Show spy mode reveal dialog
  Future<void> _showSpyModeRevealDialog(
    BuildContext context,
    SpyModeInfo info,
  ) async {
    final result = await SpyModeRevealDialog.show(context: context, info: info);

    if (result == true && context.mounted) {
      // User chose to reveal identity
      final bleService = ref.read(bleServiceProvider);
      final revealMessage = await bleService.stateManager
          .revealIdentityToFriend();

      if (revealMessage != null) {
        // Send the reveal message
        try {
          // Note: The reveal message will be sent via the protocol message handler
          _logger.fine('🕵️ Reveal message created: $revealMessage');

          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Row(
                  children: [
                    Icon(Icons.check_circle, color: Colors.white),
                    SizedBox(width: 12),
                    Expanded(
                      child: Text('Identity revealed to ${info.contactName}'),
                    ),
                  ],
                ),
                backgroundColor: Colors.green.shade700,
                duration: Duration(seconds: 3),
              ),
            );
          }
        } catch (e) {
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Row(
                  children: [
                    Icon(Icons.error, color: Colors.white),
                    SizedBox(width: 12),
                    Expanded(child: Text('Failed to reveal identity: $e')),
                  ],
                ),
                backgroundColor: Colors.red.shade700,
                duration: Duration(seconds: 5),
              ),
            );
          }
        }
      }
    } else if (result == false && context.mounted) {
      // User chose to stay anonymous
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Row(
            children: [
              Icon(Icons.visibility_off, color: Colors.white),
              SizedBox(width: 12),
              Expanded(
                child: Text('Staying anonymous with ${info.contactName}'),
              ),
            ],
          ),
          duration: Duration(seconds: 2),
        ),
      );
    }
  }

  /// Show identity revealed notification
  void _showIdentityRevealedNotification(
    BuildContext context,
    String contactName,
  ) {
    if (!context.mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            Icon(Icons.person, color: Colors.white),
            SizedBox(width: 12),
            Expanded(child: Text('$contactName revealed their identity!')),
          ],
        ),
        backgroundColor: Colors.blue.shade700,
        duration: Duration(seconds: 4),
        action: SnackBarAction(
          label: 'VIEW',
          textColor: Colors.white,
          onPressed: () {
            // Navigate to chat with this contact
            // TODO: Implement navigation to contact's chat
          },
        ),
      ),
    );
  }
}
