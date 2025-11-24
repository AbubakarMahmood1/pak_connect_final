import 'package:flutter/material.dart';

import '../../../domain/services/notification_handler_factory.dart';
import '../../controllers/settings_controller.dart';

class NotificationSection extends StatelessWidget {
  const NotificationSection({
    super.key,
    required this.controller,
    required this.onShowError,
  });

  final SettingsController controller;
  final void Function(String message) onShowError;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final supportsBackgroundNotifications =
        NotificationHandlerFactory.isBackgroundNotificationSupported();

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Column(
        children: [
          SwitchListTile(
            secondary: const Icon(Icons.notifications),
            title: const Text('Enable Notifications'),
            subtitle: const Text('Receive notifications for new messages'),
            value: controller.notificationsEnabled,
            onChanged: (value) async {
              await controller.setNotificationsEnabled(value);
            },
          ),
          if (controller.notificationsEnabled) ...[
            if (supportsBackgroundNotifications) ...[
              const Divider(height: 1),
              SwitchListTile(
                secondary: const Icon(Icons.phonelink),
                title: const Text('System Notifications'),
                subtitle: const Text(
                  'Show notifications even when app is closed (Android)',
                ),
                value: controller.backgroundNotifications,
                onChanged: (value) async {
                  try {
                    await controller.setBackgroundNotifications(value);
                  } catch (e) {
                    onShowError('Failed to update notification handler: $e');
                  }
                },
              ),
            ],
            const Divider(height: 1),
            SwitchListTile(
              secondary: const Icon(Icons.volume_up),
              title: const Text('Sound'),
              subtitle: const Text('Play sound for new messages'),
              value: controller.soundEnabled,
              onChanged: (value) async {
                await controller.setSoundEnabled(value);
              },
            ),
            const Divider(height: 1),
            SwitchListTile(
              secondary: const Icon(Icons.vibration),
              title: const Text('Vibration'),
              subtitle: const Text('Vibrate for new messages'),
              value: controller.vibrationEnabled,
              onChanged: (value) async {
                await controller.setVibrationEnabled(value);
              },
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.notifications_active),
              title: const Text('Test Notification'),
              subtitle: const Text('Test current notification settings'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () async {
                try {
                  await controller.triggerTestNotification();
                } catch (e) {
                  onShowError('Failed to test notification: $e');
                }
              },
            ),
          ],
        ],
      ),
    );
  }
}
