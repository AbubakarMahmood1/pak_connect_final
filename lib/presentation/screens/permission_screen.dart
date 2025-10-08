import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:logging/logging.dart';
import '../providers/ble_providers.dart';
import '../widgets/import_dialog.dart';
import 'chats_screen.dart';

class PermissionScreen extends ConsumerStatefulWidget {
  const PermissionScreen({super.key});

  @override
  ConsumerState<PermissionScreen> createState() => _PermissionScreenState();
}

class _PermissionScreenState extends ConsumerState<PermissionScreen> {
  final _logger = Logger('PermissionScreen');
  bool _isRequestingPermissions = false;
  Timer? _timeoutTimer;

  @override
  void initState() {
    super.initState();
    _timeoutTimer = Timer(Duration(seconds: 10), () {
      if (mounted) {
        _showError('BLE initialization timed out. Please restart the app.');
      }
    });
  }

  @override
  void dispose() {
    _timeoutTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
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
                child: Icon(Icons.bluetooth, size: 60, color: Colors.white),
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
              Center(
                child: bleStateAsync.when(
                  data: (state) => _buildPermissionContent(context, state),
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

  Widget _buildPermissionContent(
    BuildContext context,
    BluetoothLowEnergyState state,
  ) {
    // Cancel timeout timer when BLE state is resolved
    if (state != BluetoothLowEnergyState.unknown &&
        state != BluetoothLowEnergyState.unsupported) {
      _timeoutTimer?.cancel();
      _timeoutTimer = null;
    }

    switch (state) {
      case BluetoothLowEnergyState.poweredOn:
        return Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Icon(Icons.check_circle, color: Colors.green, size: 48),
            SizedBox(height: 16),
            Text(
              'All set! Ready to chat',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            SizedBox(height: 24),
            FilledButton(
              onPressed: () => _navigateToChatsScreen(context),
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: 32, vertical: 12),
                child: Text('Start Anew'),
              ),
            ),
            SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: () => _showImportDialog(context),
              icon: Icon(Icons.upload_file),
              label: Text('Import Existing Data'),
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
              onPressed: _isRequestingPermissions
                  ? null
                  : _requestBLEPermissions,
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: 32, vertical: 12),
                child: _isRequestingPermissions
                    ? Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          ),
                          SizedBox(width: 8),
                          Text('Requesting...'),
                        ],
                      )
                    : Text('Grant Permission'),
              ),
            ),
            SizedBox(height: 12),
            OutlinedButton(
              onPressed: _openSettings,
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

  // 🆕 NEW: Proper BLE permission handling
  Future<void> _requestBLEPermissions() async {
    setState(() => _isRequestingPermissions = true);

    try {
      if (Platform.isAndroid) {
        final deviceInfo = DeviceInfoPlugin();
        final androidInfo = await deviceInfo.androidInfo;

        List<Permission> permissionsToRequest = [];

        if (androidInfo.version.sdkInt >= 31) {
          // Android 12+ - use granular BLE permissions
          permissionsToRequest = [
            Permission.bluetoothScan,
            Permission.bluetoothAdvertise,
            Permission.bluetoothConnect,
          ];
        } else {
          // Android < 12 - use location permission for BLE
          permissionsToRequest = [Permission.locationWhenInUse];
        }

        final statuses = await permissionsToRequest.request();

        final allGranted = statuses.values.every((status) => status.isGranted);

        if (allGranted) {
          _showSuccess('Permissions granted! 🎉');
          // Give a moment for user to see success, then navigate
          await Future.delayed(Duration(seconds: 1));
          if (mounted) {
            _navigateToChatsScreen(context);
          }
        } else {
          _showPermissionDeniedDialog(statuses);
        }
      } else {
        // iOS - permissions handled automatically by the system
        _navigateToChatsScreen(context);
      }
    } catch (e) {
      _showError('Permission request failed: $e');
    } finally {
      if (mounted) {
        setState(() => _isRequestingPermissions = false);
      }
    }
  }

  void _showPermissionDeniedDialog(Map<Permission, PermissionStatus> statuses) {
    final deniedPermissions = statuses.entries
        .where((entry) => !entry.value.isGranted)
        .map((entry) => _getPermissionName(entry.key))
        .join(', ');

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Permissions Required'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('The following permissions were denied:'),
            SizedBox(height: 8),
            Text(
              deniedPermissions,
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            SizedBox(height: 16),
            Text('Please grant these permissions in Settings to use the app.'),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(context);
              _openSettings();
            },
            child: Text('Open Settings'),
          ),
        ],
      ),
    );
  }

  String _getPermissionName(Permission permission) {
    switch (permission) {
      case Permission.bluetoothScan:
        return 'Nearby devices (Scan)';
      case Permission.bluetoothAdvertise:
        return 'Nearby devices (Advertise)';
      case Permission.bluetoothConnect:
        return 'Nearby devices (Connect)';
      case Permission.locationWhenInUse:
        return 'Location (for Bluetooth)';
      default:
        return permission.toString();
    }
  }

  Future<void> _openSettings() async {
    try {
      await openAppSettings();
    } catch (e) {
      _showError('Could not open settings: $e');
    }
  }

  void _showSuccess(String message) {
    _logger.info('✅ $message');
  }

  void _showError(String message) {
    _logger.warning('❌ $message');
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
            SizedBox(height: 8),
            Text('• Find nearby devices'),
            Text('• Send/receive messages'),
            Text('• Maintain connections'),
            SizedBox(height: 16),
            Container(
              padding: EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Theme.of(
                  context,
                ).colorScheme.primaryContainer.withValues(),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  Icon(Icons.security, size: 20),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Your messages never leave your devices',
                      style: TextStyle(fontWeight: FontWeight.w500),
                    ),
                  ),
                ],
              ),
            ),
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

  void _showImportDialog(BuildContext context) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => const ImportDialog(),
    );

    // If import was successful, navigate to chats screen
    if (result == true && mounted) {
      _navigateToChatsScreen(this.context);
    }
  }

  void _navigateToChatsScreen(BuildContext context) {
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(builder: (context) => ChatsScreen()),
    );
  }
}
