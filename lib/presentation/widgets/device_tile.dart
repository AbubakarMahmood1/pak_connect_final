import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import '../providers/ble_providers.dart';
import 'package:pak_connect/domain/utils/string_extensions.dart';

class DeviceTile extends ConsumerWidget {
  final Peripheral device;
  final VoidCallback onTap;

  const DeviceTile({super.key, required this.device, required this.onTap});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bleService = ref.watch(connectionServiceProvider);
    final connectionInfoAsync = ref.watch(connectionInfoProvider);

    final connectionInfo = connectionInfoAsync.maybeWhen(
      data: (info) => info,
      orElse: () => null,
    );

    // Check if THIS specific device is connected
    final isThisDeviceConnected =
        bleService.isConnected &&
        bleService.connectedDevice?.uuid == device.uuid;

    // Use connection info name if this is the connected device
    final displayName =
        (isThisDeviceConnected && connectionInfo?.otherUserName != null)
        ? connectionInfo!.otherUserName!
        : 'Device ${device.uuid.toString().shortId(8)}...';

    final hasNameExchange =
        isThisDeviceConnected &&
        connectionInfo?.otherUserName != null &&
        connectionInfo!.otherUserName!.isNotEmpty;

    return Card(
      margin: EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: isThisDeviceConnected
              ? (hasNameExchange
                    ? Colors.green.withValues(alpha: 0.2)
                    : Colors.orange.withValues(alpha: 0.2))
              : Theme.of(context).colorScheme.primaryContainer,
          child: Icon(
            Icons.phone_android,
            color: isThisDeviceConnected
                ? (hasNameExchange ? Colors.green : Colors.orange)
                : Theme.of(context).colorScheme.onPrimaryContainer,
          ),
        ),
        title: Text(
          displayName,
          style: Theme.of(context).textTheme.titleMedium,
        ),
        subtitle: Text(
          _getSubtitleText(isThisDeviceConnected, hasNameExchange),
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: isThisDeviceConnected
                ? (hasNameExchange ? Colors.green : Colors.orange)
                : null,
          ),
        ),
        trailing: _buildActionButton(
          context,
          isThisDeviceConnected,
          hasNameExchange,
          device,
        ),
      ),
    );
  }

  String _getSubtitleText(bool isConnected, bool hasNameExchange) {
    if (!isConnected) return 'Tap to connect';
    if (!hasNameExchange) return 'Connected - Exchanging names...';
    return 'Ready to chat';
  }

  Widget _buildActionButton(
    BuildContext context,
    bool isConnected,
    bool hasNameExchange,
    Peripheral device,
  ) {
    if (!isConnected) {
      return TextButton(onPressed: onTap, child: Text('Connect'));
    }

    return TextButton(onPressed: onTap, child: Text('Chat'));
  }
}
