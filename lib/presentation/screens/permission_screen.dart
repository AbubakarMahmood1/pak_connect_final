import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import '../providers/ble_providers.dart';
import 'discovery_screen.dart';

class PermissionScreen extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bleStateAsync = ref.watch(bleStateProvider);

    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: EdgeInsets.all(24.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
	    crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              // App Logo/Icon area
              Container(
                width: 120,
                height: 120,
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.primary,
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  Icons.bluetooth,
                  size: 60,
                  color: Colors.white,
                ),
              ),
              
              SizedBox(height: 32),
              
              // App Title
              Text(
                'BLE Chat',
		textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
              
              SizedBox(height: 16),
              
              // Subtitle
              Text(
                'Secure offline messaging\nfor family & friends',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
              
              SizedBox(height: 48),
              
              // Permission status and button
              Center( // ADD THIS WRAPPER!
                child: bleStateAsync.when(
                  data: (state) => _buildPermissionContent(context, ref, state),
                  loading: () => CircularProgressIndicator(),
                  error: (err, stack) => Text('Error: $err'),
                ),
              ),
              
              SizedBox(height: 24),
              
              // Why is this needed? button
              Center(
                child: TextButton(
                  onPressed: () => _showPermissionExplanation(context),
                  child: Text('Why is this needed?'),
	        ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPermissionContent(BuildContext context, WidgetRef ref, BluetoothLowEnergyState state) {
    switch (state) {
      case BluetoothLowEnergyState.poweredOn:
        return Column(
	  mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Icon(
              Icons.check_circle,
              color: Colors.green,
              size: 48,
            ),
            SizedBox(height: 16),
            Text(
              'All set! Ready to chat',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            SizedBox(height: 24),
            FilledButton(
              onPressed: () => _navigateToDiscovery(context),
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: 32, vertical: 12),
                child: Text('Start Chatting'),
              ),
            ),
          ],
        );
        
      case BluetoothLowEnergyState.unauthorized:
  return Column(
    mainAxisAlignment: MainAxisAlignment.center,
    crossAxisAlignment: CrossAxisAlignment.center,
    children: [
      Icon(
        Icons.bluetooth_disabled,
        color: Theme.of(context).colorScheme.error,
        size: 48,
      ),
      SizedBox(height: 16),
      Text(
        'Bluetooth Permission Required',
        style: Theme.of(context).textTheme.titleMedium,
        textAlign: TextAlign.center,
      ),
      SizedBox(height: 8),
      Text(
        'We need Bluetooth access to find nearby devices and send messages securely.',
        textAlign: TextAlign.center,
        style: Theme.of(context).textTheme.bodyMedium,
      ),
      SizedBox(height: 24),
      FilledButton(
        onPressed: () => _requestPermission(ref),
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: 32, vertical: 12),
          child: Text('Grant Permission'),
        ),
      ),
      SizedBox(height: 12),
      OutlinedButton(
        onPressed: () => _openSettings(ref),
        child: Text('Open Settings'),
      ),
    ],
  );

case BluetoothLowEnergyState.poweredOff:
  return Column(
    mainAxisAlignment: MainAxisAlignment.center,
    crossAxisAlignment: CrossAxisAlignment.center,
    children: [
      Icon(
        Icons.bluetooth_disabled,
        color: Theme.of(context).colorScheme.error,
        size: 48,
      ),
      SizedBox(height: 16),
      Text(
        'Bluetooth is turned off',
        style: Theme.of(context).textTheme.titleMedium,
      ),
      SizedBox(height: 8),
      Text(
        'Please turn on Bluetooth in your device settings to use this app.',
        textAlign: TextAlign.center,
        style: Theme.of(context).textTheme.bodyMedium,
      ),
      SizedBox(height: 16),
      Text(
        'Settings > Bluetooth > Turn On',
        textAlign: TextAlign.center,
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
          fontStyle: FontStyle.italic,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    ],
  );
  case BluetoothLowEnergyState.unknown:
    case BluetoothLowEnergyState.unsupported:
    default:
      return Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          CircularProgressIndicator(),
          SizedBox(height: 16),
          Text(
            'Checking Bluetooth status...',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          SizedBox(height: 8),
          Text(
            'Please wait while we check your device capabilities.',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyMedium,
          ),
        ],
      );


    }
  }


  void _requestPermission(WidgetRef ref) async {
    final bleService = ref.read(bleServiceProvider);
    // Permission request is already handled in our BLE service
    // This button just gives user feedback
  }

  void _openSettings(WidgetRef ref) async {
  final bleService = ref.read(bleServiceProvider);
  try {
    await bleService.centralManager.showAppSettings();
  } catch (e) {
    print('Could not open settings: $e');
  }
}

  void _showPermissionExplanation(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Why Bluetooth Permission?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('We need Bluetooth to:'),
            SizedBox(height: 6),
            Text('• Find nearby devices'),
            Text('• Send/receive messages'),
            Text('• Maintain connections'),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text('Got it'),
          ),
        ],
      ),
    );
  }

  void _navigateToDiscovery(BuildContext context) {
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(builder: (context) => DiscoveryScreen()),
    );
  }
}