import 'package:flutter/material.dart';

class PrivacySection extends StatelessWidget {
  const PrivacySection({
    super.key,
    required this.hintBroadcastEnabled,
    required this.showReadReceipts,
    required this.showOnlineStatus,
    required this.allowNewContacts,
    required this.autoConnectKnownContacts,
    required this.onHintBroadcastChanged,
    required this.onReadReceiptsChanged,
    required this.onOnlineStatusChanged,
    required this.onAllowNewContactsChanged,
    required this.onAutoConnectChanged,
    required this.onShowMessage,
  });

  final bool hintBroadcastEnabled;
  final bool showReadReceipts;
  final bool showOnlineStatus;
  final bool allowNewContacts;
  final bool autoConnectKnownContacts;
  final Future<void> Function(bool value) onHintBroadcastChanged;
  final Future<void> Function(bool value) onReadReceiptsChanged;
  final Future<void> Function(bool value) onOnlineStatusChanged;
  final Future<void> Function(bool value) onAllowNewContactsChanged;
  final Future<void> Function(bool value) onAutoConnectChanged;
  final void Function(String message) onShowMessage;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Column(
        children: [
          SwitchListTile(
            secondary: Icon(
              hintBroadcastEnabled
                  ? Icons.wifi_tethering
                  : Icons.visibility_off,
            ),
            title: const Text('Broadcast Hints'),
            subtitle: Text(
              hintBroadcastEnabled
                  ? 'Friends can see when you\'re online'
                  : '🕵️ Spy mode: Chat anonymously with friends',
              style: TextStyle(
                color: hintBroadcastEnabled
                    ? theme.textTheme.bodySmall?.color
                    : theme.colorScheme.primary,
                fontWeight: hintBroadcastEnabled
                    ? FontWeight.normal
                    : FontWeight.w600,
              ),
            ),
            value: hintBroadcastEnabled,
            onChanged: (value) async {
              await onHintBroadcastChanged(value);
              onShowMessage(
                value
                    ? 'Spy mode disabled - friends will know it\'s you'
                    : '🕵️ Spy mode enabled - chat anonymously',
              );
            },
          ),
          const Divider(height: 1),
          SwitchListTile(
            secondary: const Icon(Icons.check_circle),
            title: const Text('Read Receipts'),
            subtitle: const Text(
              'Let others know when you\'ve read their messages',
            ),
            value: showReadReceipts,
            onChanged: (value) async => onReadReceiptsChanged(value),
          ),
          const Divider(height: 1),
          SwitchListTile(
            secondary: const Icon(Icons.circle),
            title: const Text('Online Status'),
            subtitle: const Text('Show when you\'re online'),
            value: showOnlineStatus,
            onChanged: (value) async => onOnlineStatusChanged(value),
          ),
          const Divider(height: 1),
          SwitchListTile(
            secondary: const Icon(Icons.person_add),
            title: const Text('Allow New Contacts'),
            subtitle: const Text('Anyone can add you as a contact'),
            value: allowNewContacts,
            onChanged: (value) async => onAllowNewContactsChanged(value),
          ),
          const Divider(height: 1),
          SwitchListTile(
            secondary: Icon(
              autoConnectKnownContacts ? Icons.link : Icons.link_off,
              color: autoConnectKnownContacts ? Colors.green : null,
            ),
            title: const Text('Auto-Connect to Known Contacts'),
            subtitle: Text(
              autoConnectKnownContacts
                  ? 'Automatically connect when known contacts are discovered'
                  : 'Manually tap to connect to discovered contacts',
            ),
            value: autoConnectKnownContacts,
            onChanged: (value) async {
              await onAutoConnectChanged(value);
              onShowMessage(
                value
                    ? 'Auto-connect enabled - known contacts will connect automatically'
                    : 'Auto-connect disabled - tap devices to connect manually',
              );
            },
          ),
        ],
      ),
    );
  }
}
