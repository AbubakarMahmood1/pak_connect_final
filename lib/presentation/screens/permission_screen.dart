import 'dart:async';
import 'dart:io';

import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:logging/logging.dart';
import 'package:permission_handler/permission_handler.dart';

import '../providers/app_permission_providers.dart';
import '../providers/ble_providers.dart';
import '../widgets/import_dialog.dart';
import 'home_screen.dart';

class PermissionScreen extends ConsumerStatefulWidget {
  const PermissionScreen({super.key});

  @override
  ConsumerState<PermissionScreen> createState() => _PermissionScreenState();
}

class _PermissionScreenState extends ConsumerState<PermissionScreen>
    with WidgetsBindingObserver {
  final _logger = Logger('PermissionScreen');
  bool _isRequestingPermissions = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state == AppLifecycleState.resumed) {
      _refreshPermissionState();
    }
  }

  @override
  Widget build(BuildContext context) {
    // Start and observe timeout lifecycle via provider (autoDispose handles cancellation)
    ref.watch(permissionTimeoutProvider);

    ref.listen(permissionTimeoutProvider, (previous, next) {
      if (next && mounted) {
        _showError('BLE initialization timed out. Please restart the app.');
      }
    });

    final bleStateAsync = ref.watch(bleStateProvider);
    final blePermissionsAsync = ref.watch(blePermissionsGrantedProvider);

    return Scaffold(
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) => SingleChildScrollView(
            padding: EdgeInsets.all(24.0),
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: constraints.maxHeight),
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
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
                      'Set Up PakConnect',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.headlineMedium
                          ?.copyWith(fontWeight: FontWeight.bold),
                    ),

                    SizedBox(height: 16),

                    // Subtitle
                    Text(
                      'Restore a backup, finish Bluetooth access,\nor continue with a fresh local profile.',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),

                    SizedBox(height: 48),

                    Center(
                      child: bleStateAsync.when(
                        data: (state) => blePermissionsAsync.when(
                          data: (hasBlePermissions) =>
                              _buildPermissionContent(
                                context,
                                state,
                                hasBlePermissions,
                              ),
                          loading: () => const CircularProgressIndicator(),
                          error: (err, stack) => _buildPermissionContent(
                            context,
                            state,
                            false,
                          ),
                        ),
                        loading: () => const CircularProgressIndicator(),
                        error: (err, stack) => Text('Error: $err'),
                      ),
                    ),

                    SizedBox(height: 24),

                    Center(
                      child: TextButton(
                        onPressed: () => _showPermissionExplanation(context),
                        child: Text('Why does mesh need this?'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildPermissionContent(
    BuildContext context,
    BluetoothLowEnergyState state,
    bool hasBlePermissions,
  ) {
    // Cancel timeout timer when BLE state is resolved
    if (state != BluetoothLowEnergyState.unknown &&
        state != BluetoothLowEnergyState.unsupported) {
      ref.read(permissionTimeoutProvider.notifier).cancel();
    }

    final permissionsMissing =
        state == BluetoothLowEnergyState.unauthorized || !hasBlePermissions;

    switch (state) {
      case BluetoothLowEnergyState.poweredOn:
        if (permissionsMissing) {
          return _buildPermissionRequestContent(
            context,
            title: 'Nearby Devices Permission Required',
            description:
                'Bluetooth is on, but PakConnect still needs Nearby Devices access to scan, advertise, and connect securely.',
          );
        }
        return Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Icon(Icons.check_circle, color: Colors.green, size: 48),
            SizedBox(height: 16),
            Text(
              'Setup complete',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            SizedBox(height: 24),
            FilledButton(
              onPressed: () => _navigateToChatsScreen(context),
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: 32, vertical: 12),
                child: Text('Open Home'),
              ),
            ),
            SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: () => _showImportDialog(context),
              icon: Icon(Icons.upload_file),
              label: Text('Restore Backup'),
            ),
          ],
        );

      case BluetoothLowEnergyState.unauthorized:
        if (hasBlePermissions) {
          return Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              const CircularProgressIndicator(),
              const SizedBox(height: 16),
              Text(
                'Finalizing Bluetooth access...',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              Text(
                'Android permissions are granted. PakConnect is re-checking Bluetooth availability now.',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ],
          );
        }
        return _buildPermissionRequestContent(
          context,
          title: 'Bluetooth Permission Required',
          description:
              'We need Bluetooth access to find nearby devices and send messages securely.',
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
              'Turn Bluetooth back on and this setup screen will keep checking automatically.',
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
            SizedBox(height: 24),
            OutlinedButton.icon(
              onPressed: _refreshPermissionState,
              icon: const Icon(Icons.refresh),
              label: const Text('Check Again'),
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

  Widget _buildPermissionRequestContent(
    BuildContext context, {
    required String title,
    required String description,
  }) {
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
          title,
          style: Theme.of(context).textTheme.titleMedium,
          textAlign: TextAlign.center,
        ),
        SizedBox(height: 8),
        Text(
          description,
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodyMedium,
        ),
        SizedBox(height: 24),
        FilledButton(
          onPressed: _isRequestingPermissions ? null : _requestBLEPermissions,
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
  }

  Future<void> _requestBLEPermissions() async {
    setState(() => _isRequestingPermissions = true);

    try {
      if (Platform.isAndroid) {
        final permissionService = ref.read(appPermissionServiceProvider);
        final statuses = await permissionService.requestRequiredBlePermissions();
        _refreshPermissionState();

        final allGranted = statuses.values.every((status) => status.isGranted);

        if (allGranted) {
          _showSuccess('Permissions granted! 🎉');
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

  void _refreshPermissionState() {
    if (!mounted) return;
    ref.invalidate(blePermissionsGrantedProvider);
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
        title: Text('Why Mesh Permissions?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('PakConnect uses Bluetooth mesh to:'),
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
      MaterialPageRoute(builder: (context) => HomeScreen()),
    );
  }
}

/// Riverpod-managed permission timeout with lifecycle-bound timer.
class PermissionTimeoutStateNotifier extends StateNotifier<bool> {
  Timer? _timer;

  PermissionTimeoutStateNotifier() : super(false) {
    _timer = Timer(const Duration(seconds: 10), () => state = true);
  }

  void cancel() {
    _timer?.cancel();
    _timer = null;
    state = false;
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}

final permissionTimeoutProvider =
    StateNotifierProvider.autoDispose<PermissionTimeoutStateNotifier, bool>((
      ref,
    ) {
      return PermissionTimeoutStateNotifier();
    });
