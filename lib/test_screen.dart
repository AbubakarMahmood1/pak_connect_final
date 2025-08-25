import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'presentation/providers/ble_providers.dart';

class BLETestScreen extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bleService = ref.watch(bleServiceProvider);
    final bleStateAsync = ref.watch(bleStateProvider);
    final devicesAsync = ref.watch(discoveredDevicesProvider);

    return Scaffold(
      appBar: AppBar(title: Text('BLE Foundation Test')),
      body: Column(
        children: [
          // Show BLE state
          Card(
            child: Padding(
              padding: EdgeInsets.all(16),
              child: bleStateAsync.when(
                data: (state) => Text('BLE State: $state'),
                loading: () => Text('Checking BLE state...'),
                error: (err, stack) => Text('Error: $err'),
              ),
            ),
          ),
          
          // Scan button
          ElevatedButton(
            onPressed: () async {
              try {
                await bleService.startScanning();
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('Scanning started')),
                );
              } catch (e) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('Scan failed: $e')),
                );
              }
            },
            child: Text('Start Scanning'),
          ),
          
          // Show discovered devices
          Expanded(
            child: devicesAsync.when(
              data: (devices) => ListView.builder(
                itemCount: devices.length,
                itemBuilder: (context, index) {
                  final device = devices[index];
                  return ListTile(
                    title: Text('Device ${device.uuid}'),
                    subtitle: Text('Tap to test connection'),
                    onTap: () async {
                      try {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text('Connecting...')),
                        );
                        await bleService.connectToDevice(device);
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text('Connected!')),
                        );
                      } catch (e) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text('Connection failed: $e')),
                        );
                      }
                    },
                  );
                },
              ),
              loading: () => Center(child: Text('No devices discovered yet')),
              error: (err, stack) => Center(child: Text('Error: $err')),
            ),
          ),
        ],
      ),
    );
  }
}