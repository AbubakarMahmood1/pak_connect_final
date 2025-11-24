import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:flutter/material.dart';

import '../../../core/models/ble_server_connection.dart';
import '../../../core/utils/string_extensions.dart';

class DiscoveryPeripheralView extends StatelessWidget {
  const DiscoveryPeripheralView({
    super.key,
    required this.serverConnections,
    required this.onOpenChat,
  });

  final List<BLEServerConnection> serverConnections;
  final void Function(Central central) onOpenChat;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Container(
          margin: const EdgeInsets.all(16),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            children: [
              Icon(
                Icons.wifi_tethering,
                color: Theme.of(context).colorScheme.primary,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Peripheral Mode',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    Text(
                      '${serverConnections.length} device(s) connected to you',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),

        const Divider(),

        Expanded(
          child: serverConnections.isEmpty
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(
                        Icons.wifi_tethering,
                        size: 64,
                        color: Colors.grey,
                      ),
                      const SizedBox(height: 16),
                      Text(
                        'No devices connected',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Waiting for others to discover you...',
                        style: Theme.of(
                          context,
                        ).textTheme.bodySmall?.copyWith(color: Colors.grey),
                      ),
                    ],
                  ),
                )
              : ListView.builder(
                  itemCount: serverConnections.length,
                  itemBuilder: (context, index) {
                    final connection = serverConnections[index];
                    return _buildServerConnectionItem(connection, context);
                  },
                ),
        ),
      ],
    );
  }

  Widget _buildServerConnectionItem(
    BLEServerConnection connection,
    BuildContext context,
  ) {
    final duration = connection.connectedDuration;
    final durationText = duration.inMinutes > 0
        ? '${duration.inMinutes}m ${duration.inSeconds % 60}s'
        : '${duration.inSeconds}s';

    return ListTile(
      leading: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: Colors.green.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(8),
        ),
        child: const Icon(Icons.phone_android, color: Colors.green),
      ),
      title: Text(
        connection.address.shortId(17),
        style: const TextStyle(fontWeight: FontWeight.bold),
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Connected for: $durationText'),
          if (connection.mtu != null) Text('MTU: ${connection.mtu} bytes'),
          Text(
            connection.isSubscribed
                ? 'Subscribed to notifications'
                : 'Not subscribed',
            style: TextStyle(
              color: connection.isSubscribed ? Colors.green : Colors.orange,
              fontSize: 12,
            ),
          ),
        ],
      ),
      trailing: Icon(
        Icons.chat_bubble_outline,
        color: Theme.of(context).colorScheme.primary,
      ),
      onTap: () => onOpenChat(connection.central),
    );
  }
}
