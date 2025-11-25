import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logging/logging.dart';

import '../../../core/discovery/device_deduplication_manager.dart';
import '../../../core/interfaces/i_connection_service.dart';
import '../../controllers/discovery_overlay_controller.dart';
import '../../providers/ble_providers.dart';
import 'discovery_device_tile.dart';

class DiscoveryScannerView extends ConsumerWidget {
  const DiscoveryScannerView({
    super.key,
    required this.devicesAsync,
    required this.discoveryDataAsync,
    required this.deduplicatedDevicesAsync,
    required this.state,
    required this.controller,
    required this.maxDevices,
    required this.logger,
    required this.onStartScanning,
    required this.onConnect,
    required this.onRetry,
    required this.onOpenChat,
    required this.onError,
  });

  final AsyncValue<List<Peripheral>> devicesAsync;
  final AsyncValue<Map<String, DiscoveredEventArgs>> discoveryDataAsync;
  final AsyncValue<Map<String, DiscoveredDevice>> deduplicatedDevicesAsync;
  final DiscoveryOverlayState state;
  final DiscoveryOverlayController controller;
  final int maxDevices;
  final Logger logger;
  final Future<void> Function() onStartScanning;
  final Future<void> Function(Peripheral device) onConnect;
  final void Function(Peripheral device) onRetry;
  final void Function(Peripheral device) onOpenChat;
  final void Function(String message) onError;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final connectionService = ref.read(connectionServiceProvider);

    return Column(
      children: [
        _buildMinimalistScanningCircle(context, ref),
        const SizedBox(height: 8),
        _buildConnectionSlotIndicator(connectionService),
        const SizedBox(height: 8),
        const Divider(),
        Expanded(
          child: devicesAsync.when(
            data: (devices) =>
                _buildDeviceList(context, connectionService, devices),
            loading: () => _buildBurstAwareLoadingState(context, ref),
            error: (error, stack) => _buildErrorState(context, error),
          ),
        ),
      ],
    );
  }

  Widget _buildDeviceList(
    BuildContext context,
    IConnectionService connectionService,
    List<Peripheral> devices,
  ) {
    if (devices.isEmpty) {
      return _buildEmptyState(context);
    }

    final discoveryData = discoveryDataAsync.value ?? {};
    final deduplicatedDevices = deduplicatedDevicesAsync.value ?? {};

    for (final device in devices) {
      controller.updateDeviceLastSeen(device.uuid.toString());
    }

    final now = DateTime.now();
    const staleThreshold = Duration(minutes: 3);
    final freshDevices = devices.where((device) {
      final lastSeen = state.deviceLastSeen[device.uuid.toString()];
      return lastSeen != null && now.difference(lastSeen) <= staleThreshold;
    }).toList();

    final newDevices = <Peripheral>[];
    final knownDevices = <Peripheral>[];

    for (final device in freshDevices) {
      final deviceId = device.uuid.toString();
      final deduplicatedDevice = deduplicatedDevices[deviceId];

      if (deduplicatedDevice != null && deduplicatedDevice.isKnownContact) {
        knownDevices.add(device);
      } else {
        newDevices.add(device);
      }
    }

    knownDevices.sort((a, b) {
      final rssiA = discoveryData[a.uuid.toString()]?.rssi ?? -100;
      final rssiB = discoveryData[b.uuid.toString()]?.rssi ?? -100;
      return rssiB.compareTo(rssiA);
    });

    newDevices.sort((a, b) {
      final rssiA = discoveryData[a.uuid.toString()]?.rssi ?? -100;
      final rssiB = discoveryData[b.uuid.toString()]?.rssi ?? -100;
      return rssiB.compareTo(rssiA);
    });

    final limitedKnownDevices = knownDevices.take(maxDevices ~/ 2).toList();
    final limitedNewDevices = newDevices.take(maxDevices ~/ 2).toList();
    final totalShown = limitedKnownDevices.length + limitedNewDevices.length;
    final totalAvailable = knownDevices.length + newDevices.length;

    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: [
        if (limitedKnownDevices.isNotEmpty) ...[
          _buildSectionHeader(
            context,
            'Known Contacts',
            Icons.people,
            limitedKnownDevices.length,
            knownDevices.length > limitedKnownDevices.length
                ? '${knownDevices.length - limitedKnownDevices.length} more'
                : null,
          ),
          ...limitedKnownDevices.map(
            (device) => DiscoveryDeviceTile(
              device: device,
              advertisement: discoveryData[device.uuid.toString()],
              isKnownContact: true,
              contacts: state.contacts,
              attemptState: controller.attemptStateFor(device.uuid.toString()),
              isConnectedAsCentral:
                  connectionService.connectedDevice?.uuid == device.uuid,
              isConnectedAsPeripheral:
                  connectionService.connectedCentral?.uuid.toString() ==
                  device.uuid.toString(),
              onConnect: () => onConnect(device),
              onRetry: () => onRetry(device),
              onOpenChat: () => onOpenChat(device),
              onError: onError,
              logger: logger,
            ),
          ),
        ],
        if (limitedKnownDevices.isNotEmpty && limitedNewDevices.isNotEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: Divider(),
          ),
        if (limitedNewDevices.isNotEmpty) ...[
          _buildSectionHeader(
            context,
            'New Devices',
            Icons.devices_other,
            limitedNewDevices.length,
            newDevices.length > limitedNewDevices.length
                ? '${newDevices.length - limitedNewDevices.length} more'
                : null,
          ),
          ...limitedNewDevices.map(
            (device) => DiscoveryDeviceTile(
              device: device,
              advertisement: discoveryData[device.uuid.toString()],
              isKnownContact: false,
              contacts: state.contacts,
              attemptState: controller.attemptStateFor(device.uuid.toString()),
              isConnectedAsCentral:
                  connectionService.connectedDevice?.uuid == device.uuid,
              isConnectedAsPeripheral:
                  connectionService.connectedCentral?.uuid.toString() ==
                  device.uuid.toString(),
              onConnect: () => onConnect(device),
              onRetry: () => onRetry(device),
              onOpenChat: () => onOpenChat(device),
              onError: onError,
              logger: logger,
            ),
          ),
        ],
        if (totalAvailable > totalShown)
          Padding(
            padding: const EdgeInsets.all(16),
            child: OutlinedButton.icon(
              onPressed: () {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(
                      'Showing $totalShown of $totalAvailable devices. Pull down to refresh for more.',
                    ),
                  ),
                );
              },
              icon: const Icon(Icons.expand_more),
              label: Text('+ ${totalAvailable - totalShown} more devices'),
            ),
          ),
        if (totalShown > 0 && !controller.getUnifiedScanningState())
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              'Tap the timer circle above to scan for more devices',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                fontStyle: FontStyle.italic,
              ),
              textAlign: TextAlign.center,
            ),
          ),
        const SizedBox(height: 80),
      ],
    );
  }

  Widget _buildSectionHeader(
    BuildContext context,
    String title,
    IconData icon,
    int count, [
    String? additionalInfo,
  ]) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.primary.withValues(),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Icon(
              icon,
              size: 18,
              color: Theme.of(context).colorScheme.primary,
            ),
          ),
          const SizedBox(width: 10),
          Text(
            title,
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
              color: Theme.of(context).colorScheme.primary,
              fontWeight: FontWeight.bold,
              letterSpacing: 0.5,
            ),
          ),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              '$count',
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
            ),
          ),
          if (additionalInfo != null) ...[
            const SizedBox(width: 8),
            Text(
              '($additionalInfo)',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                fontStyle: FontStyle.italic,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildEmptyState(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.bluetooth_disabled,
            size: 64,
            color: Theme.of(context).colorScheme.onSurfaceVariant.withValues(),
          ),
          const SizedBox(height: 20),
          Text(
            'Make sure other devices are in discoverable mode',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 16),
          if (!controller.getUnifiedScanningState())
            Text(
              'Tap the timer circle above to scan manually',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                fontStyle: FontStyle.italic,
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildBurstAwareLoadingState(BuildContext context, WidgetRef ref) {
    final burstStatusAsync = ref.watch(burstScanningStatusProvider);

    return burstStatusAsync.when(
      data: (burstStatus) {
        final isActuallyScanning = burstStatus.isBurstActive;
        final statusText = isActuallyScanning
            ? 'Searching for devices...'
            : 'Waiting scan - Tap timer for manual scan';

        return Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (isActuallyScanning) ...[
                const CircularProgressIndicator(),
                const SizedBox(height: 16),
              ],
              Text(
                statusText,
                style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        );
      },
      loading: () => Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: const [
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text('Initializing...'),
          ],
        ),
      ),
      error: (error, stack) => Center(
        child: Text(
          'Ready to scan',
          style: Theme.of(context).textTheme.bodyLarge?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }

  Widget _buildErrorState(BuildContext context, Object error) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.error_outline,
            size: 48,
            color: Theme.of(context).colorScheme.error,
          ),
          const SizedBox(height: 16),
          Text(
            'Error loading devices',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          Text(
            error.toString(),
            style: Theme.of(context).textTheme.bodySmall,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: onStartScanning,
            icon: const Icon(Icons.refresh),
            label: const Text('Try Again'),
          ),
        ],
      ),
    );
  }

  Widget _buildMinimalistScanningCircle(BuildContext context, WidgetRef ref) {
    final burstStatusAsync = ref.watch(burstScanningStatusProvider);

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          burstStatusAsync.when(
            data: (burstStatus) =>
                _buildScanningCircleWithStatus(context, burstStatus),
            loading: () => _buildLoadingScanningCircle(context),
            error: (error, stack) => _buildErrorScanningCircle(context),
          ),
        ],
      ),
    );
  }

  Widget _buildScanningCircleWithStatus(
    BuildContext context,
    dynamic burstStatus,
  ) {
    final theme = Theme.of(context);
    final isScanning = burstStatus.isBurstActive;

    final primaryColor = isScanning ? Colors.red : Colors.blue;
    final backgroundColor = isScanning
        ? Colors.red.withValues(alpha: 0.1)
        : theme.colorScheme.surfaceContainerHighest;

    double? progress;
    int? displayNumber;
    String? displayLabel;

    if (isScanning) {
      if (burstStatus.burstTimeRemaining != null) {
        final remaining = burstStatus.burstTimeRemaining!;
        const totalDuration = 20;
        final elapsed = totalDuration - remaining;
        progress = elapsed / totalDuration;
        displayNumber = remaining;
        displayLabel = 'sec';
      }
    } else {
      if (burstStatus.secondsUntilNextScan != null &&
          burstStatus.secondsUntilNextScan! > 0) {
        final totalSeconds = (burstStatus.currentScanInterval / 1000).round();
        final remaining = burstStatus.secondsUntilNextScan!;
        progress = (totalSeconds - remaining) / totalSeconds;
        displayNumber = remaining;
        displayLabel = 'sec';
      }
    }

    return GestureDetector(
      onTap: () async {
        if (!isScanning && controller.canTriggerManualScan()) {
          await onStartScanning();
        }
      },
      child: SizedBox(
        width: 70,
        height: 70,
        child: Stack(
          alignment: Alignment.center,
          children: [
            Container(
              width: 70,
              height: 70,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: backgroundColor,
                border: Border.all(color: primaryColor, width: 2),
              ),
            ),
            if (progress != null)
              SizedBox(
                width: 70,
                height: 70,
                child: CircularProgressIndicator(
                  value: progress.clamp(0.0, 1.0),
                  strokeWidth: 3,
                  backgroundColor: Colors.transparent,
                  valueColor: AlwaysStoppedAnimation(primaryColor),
                ),
              ),
            if (displayNumber != null && displayLabel != null)
              Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    '$displayNumber',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: primaryColor,
                    ),
                  ),
                  Text(
                    displayLabel,
                    style: TextStyle(
                      fontSize: 10,
                      color: primaryColor.withValues(alpha: 0.7),
                    ),
                  ),
                ],
              )
            else if (isScanning)
              const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                  strokeWidth: 2.5,
                  valueColor: AlwaysStoppedAnimation(Colors.red),
                ),
              )
            else
              const Icon(
                Icons.bluetooth_searching,
                size: 28,
                color: Colors.blue,
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildLoadingScanningCircle(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: 80,
      height: 80,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: theme.colorScheme.surfaceContainerHighest,
        border: Border.all(
          color: theme.colorScheme.outline.withValues(alpha: 0.5),
          width: 2,
        ),
      ),
      child: Center(
        child: SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            valueColor: AlwaysStoppedAnimation(
              theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildErrorScanningCircle(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: 80,
      height: 80,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: theme.colorScheme.errorContainer,
        border: Border.all(color: theme.colorScheme.error, width: 2),
      ),
      child: Icon(
        Icons.error_outline,
        size: 28,
        color: theme.colorScheme.onErrorContainer,
      ),
    );
  }

  Widget _buildConnectionSlotIndicator(IConnectionService connectionService) {
    final currentConnections = connectionService.clientConnectionCount;
    final maxConnections = connectionService.maxCentralConnections;
    final availableSlots = maxConnections - currentConnections;

    Color indicatorColor;
    if (availableSlots == 0) {
      indicatorColor = Colors.red;
      logger.warning('CONNECTION SLOTS: FULL - No slots available!');
    } else if (availableSlots <= 2) {
      indicatorColor = Colors.orange;
      logger.info(
        'CONNECTION SLOTS: LOW - Only $availableSlots slots remaining',
      );
    } else {
      indicatorColor = Colors.green;
      logger.fine('CONNECTION SLOTS: OK - $availableSlots slots available');
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: indicatorColor.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: indicatorColor.withValues(alpha: 0.3),
          width: 1,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.link, size: 16, color: indicatorColor),
          const SizedBox(width: 6),
          Text(
            '$currentConnections/$maxConnections connections',
            style: TextStyle(
              fontSize: 12,
              color: indicatorColor,
              fontWeight: FontWeight.w600,
            ),
          ),
          if (availableSlots > 0) ...[
            const SizedBox(width: 4),
            Text(
              '($availableSlots available)',
              style: TextStyle(
                fontSize: 11,
                color: indicatorColor.withValues(alpha: 0.7),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
