import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import '../providers/ble_providers.dart';
import '../screens/chat_screen.dart';

class DeviceTile extends ConsumerWidget {
  final Peripheral device;
  final VoidCallback onTap;

  const DeviceTile({
    super.key,
    required this.device,
    required this.onTap,
  });

  @override
Widget build(BuildContext context, WidgetRef ref) {
  final bleService = ref.watch(bleServiceProvider);
  final connectionInfoAsync = ref.watch(connectionInfoProvider);
  
  final connectionInfo = connectionInfoAsync.maybeWhen(
    data: (info) => info,
    orElse: () => null,
  );
  
  final isConnected = bleService.isConnected && 
      (bleService.connectedDevice?.uuid == device.uuid || 
       (connectionInfo?.otherUserName != null && connectionInfo!.otherUserName!.isNotEmpty));
  
  final hasNameExchange = connectionInfo?.otherUserName != null && 
                         connectionInfo!.otherUserName!.isNotEmpty;
  
  return Card(
    margin: EdgeInsets.only(bottom: 8),
    child: ListTile(
      leading: CircleAvatar(
        backgroundColor: isConnected 
            ? (hasNameExchange ? Colors.green.withOpacity(0.2) : Colors.orange.withOpacity(0.2))
            : Theme.of(context).colorScheme.primaryContainer,
        child: Icon(
          isConnected ? Icons.phone_android : Icons.phone_android,
          color: isConnected 
              ? (hasNameExchange ? Colors.green : Colors.orange)
              : Theme.of(context).colorScheme.onPrimaryContainer,
        ),
      ),
      title: Text(
        hasNameExchange && isConnected
            ? connectionInfo!.otherUserName!
            : 'Device ${device.uuid.toString().substring(0, 8)}...',
        style: Theme.of(context).textTheme.titleMedium,
      ),
      subtitle: Text(
        _getSubtitleText(isConnected, hasNameExchange),
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
          color: isConnected ? (hasNameExchange ? Colors.green : Colors.orange) : null,
        ),
      ),
      trailing: _buildActionButton(context, isConnected, hasNameExchange, device),
    ),
  );
}

  String _getSubtitleText(bool isConnected, bool hasNameExchange) {
    if (!isConnected) return 'Tap to connect';
    if (!hasNameExchange) return 'Connected - Exchanging names...';
    return 'Ready to chat';
  }

  Widget _buildActionButton(BuildContext context, bool isConnected, bool hasNameExchange, Peripheral device) {
  if (!isConnected) {
    return TextButton(
      onPressed: onTap,
      child: Text('Connect'),
    );
  }
  
  return TextButton(
    onPressed: onTap,
    child: Text('Chat'),
  );
}
}