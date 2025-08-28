import 'dart:io' show Platform;
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:bluetooth_low_energy/bluetooth_low_energy.dart' hide ConnectionState;
import 'package:bluetooth_low_energy/bluetooth_low_energy.dart' as BLE;
import 'package:logging/logging.dart';
import '../providers/ble_providers.dart';
import '../widgets/device_tile.dart';
import 'chat_screen.dart';
import '../widgets/edit_name_dialog.dart';

class DiscoveryScreen extends ConsumerStatefulWidget {
  @override
  ConsumerState<DiscoveryScreen> createState() => _DiscoveryScreenState();
}

class _DiscoveryScreenState extends ConsumerState<DiscoveryScreen> {
  bool _isScanning = false;
  final _logger = Logger('DiscoveryScreen');
  StreamSubscription? _connectionSubscription;
  bool _hasInitialized = false;

  @override
  void initState() {
    super.initState();
    _setupConnectionListener();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    
    // This runs every time we navigate TO this screen
    if (!_hasInitialized) {
      _hasInitialized = true;
      // First time setup
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _initializeScreen();
      });
    } else {
      // Returning to screen - refresh immediately
      _refreshScreen();
    }
  }

 void _initializeScreen() {
    final bleService = ref.read(bleServiceProvider);
    setState(() {}); // Fresh UI state
    
    if (!bleService.isPeripheralMode) {
      _startScanning();
    }
  }

  void _refreshScreen() {
    final bleService = ref.read(bleServiceProvider);
    
    // Clear any stale state and refresh UI
    setState(() {}); 
    
    // If we're in scanner mode and not already scanning, start fresh scan
    if (!bleService.isPeripheralMode && !_isScanning) {
      Future.delayed(Duration(milliseconds: 300), () {
        if (mounted) _startScanning();
      });
    }
  }

  void _setupConnectionListener() {
  // Cancel any existing subscription first
  _connectionSubscription?.cancel();
  
  final bleService = ref.read(bleServiceProvider);
  
  // Only set up peripheral connection listener on Android
  if (Platform.isAndroid) {
    _connectionSubscription = bleService.peripheralManager.connectionStateChanged
    .distinct((prev, next) => prev.central.uuid == next.central.uuid && prev.state == next.state)
    .listen((event) {
  _logger.info('Peripheral connection state changed: ${event.state} for ${event.central.uuid}');
  
  if (mounted && 
      bleService.isPeripheralMode && 
      event.state == BLE.ConnectionState.connected) {
    
    _logger.info('Incoming connection from central device!');
    
    // Small delay to ensure only one dialog shows
    Future.delayed(Duration(milliseconds: 500), () {
      if (mounted) {
        _showIncomingConnectionDialog(event.central);
      }
    });
  }
});
  }
}

  @override
  Widget build(BuildContext context) {
    final bleService = ref.watch(bleServiceProvider);
    final devicesAsync = ref.watch(discoveredDevicesProvider);
    final bleStateAsync = ref.watch(bleStateProvider);

    return Scaffold(
      appBar: AppBar(
        title: Text('Find Devices'),
        elevation: 0,
        leading: GestureDetector(
          onTap: () => _showSettings(context),
          child: Padding(
            padding: EdgeInsets.all(8.0),
            child: CircleAvatar(
              backgroundColor: Theme.of(context).colorScheme.primary,
              child: Icon(
                Icons.person,
                color: Colors.white,
                size: 24,
              ),
            ),
          ),
        ),
        actions: [
          IconButton(
            onPressed: _isScanning ? _stopScanning : _startScanning,
            icon: _isScanning 
              ? Icon(Icons.stop) 
              : Icon(Icons.refresh),
          ),
        ],
      ),
      body: Column(
        children: [
          // Status banner
          _buildStatusBanner(bleStateAsync),
          _buildPlatformBanner(),
          
          // Mode toggle
          Container(
            width: double.infinity,
            padding: EdgeInsets.all(16),
            color: Theme.of(context).colorScheme.secondaryContainer,
            child: Row(
              children: [
                Text(
                  'Mode: ',
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSecondaryContainer,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                Expanded(
                  child: Row(
                    children: [
                      ChoiceChip(
                        label: Text('Scanner'),
                        selected: !bleService.isPeripheralMode,
                        onSelected: (selected) {
                          if (selected) _switchToCentralMode();
                        },
                      ),
                      SizedBox(width: 8),
                      ChoiceChip(
                        label: Text('Discoverable'),
                        selected: bleService.isPeripheralMode,
                        onSelected: (selected) {
                          if (selected) _switchToPeripheralMode();
                        },
                      ),
                    ],
                  ),
                ),
                // Mode explanation
                IconButton(
                  onPressed: () => _showModeExplanation(),
                  icon: Icon(
                    Icons.help_outline,
                    color: Theme.of(context).colorScheme.onSecondaryContainer,
                  ),
                ),
              ],
            ),
          ),
          
          // Scanning indicator
          if (_isScanning && !bleService.isPeripheralMode)
            Container(
              width: double.infinity,
              padding: EdgeInsets.all(16),
              color: Theme.of(context).colorScheme.primaryContainer,
              child: Row(
                children: [
                  SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  SizedBox(width: 12),
                  Text(
                    'Scanning for nearby devices...',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onPrimaryContainer,
                    ),
                  ),
                ],
              ),
            ),
            
          // Peripheral mode indicator  
          if (bleService.isPeripheralMode)
            Container(
              width: double.infinity,
              padding: EdgeInsets.all(16),
              color: Theme.of(context).colorScheme.tertiaryContainer,
              child: Row(
                children: [
                  Icon(
                    Icons.wifi_tethering,
                    color: Theme.of(context).colorScheme.onTertiaryContainer,
                    size: 20,
                  ),
                  SizedBox(width: 12),
                  Text(
                    'Discoverable - other devices can find you',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onTertiaryContainer,
                    ),
                  ),
                ],
              ),
            ),
          
          // Device list
          Expanded(
            child: bleService.isPeripheralMode 
              ? _buildPeripheralModeContent()
              : devicesAsync.when(
                  data: (devices) => _buildDeviceList(devices, bleService),
                  loading: () => _buildEmptyState('Looking for devices...', Icons.search),
                  error: (err, stack) => _buildEmptyState('Error: $err', Icons.error),
                ),
          ),
        ],
      ),
    );
  }

  Widget _buildStatusBanner(AsyncValue<BluetoothLowEnergyState> bleStateAsync) {
    return bleStateAsync.when(
      data: (state) {
        if (state != BluetoothLowEnergyState.poweredOn) {
          return Container(
            width: double.infinity,
            padding: EdgeInsets.all(16),
            color: Theme.of(context).colorScheme.errorContainer,
            child: Row(
              children: [
                Icon(
                  Icons.warning,
                  color: Theme.of(context).colorScheme.onErrorContainer,
                ),
                SizedBox(width: 8),
                Text(
                  'Bluetooth ${state.name}',
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onErrorContainer,
                  ),
                ),
              ],
            ),
          );
        }
        return SizedBox.shrink();
      },
      loading: () => SizedBox.shrink(),
      error: (err, stack) => SizedBox.shrink(),
    );
  }

  Widget _buildDeviceList(List<Peripheral> devices, bleService) {
    if (devices.isEmpty) {
      return _buildEmptyState(
        _isScanning 
          ? 'No devices found yet...\nMake sure other devices are running the app'
          : 'Tap refresh to scan for devices',
        _isScanning ? Icons.search : Icons.bluetooth_searching,
      );
    }

    return ListView.builder(
      padding: EdgeInsets.all(16),
      itemCount: devices.length,
      itemBuilder: (context, index) {
        final device = devices[index];
        return DeviceTile(
          device: device,
          onTap: () => _connectToDevice(device, bleService),
        );
      },
    );
  }

  Widget _buildPeripheralModeContent() {
  final bleService = ref.watch(bleServiceProvider);
  
  return Consumer(
    builder: (context, ref, child) {
      // Check if there's an active connection
      final nameAsync = ref.watch(nameChangesProvider);
      final hasConnection = nameAsync.maybeWhen(
        data: (name) => name != null && name.isNotEmpty,
        orElse: () => false,
      );
      
      if (hasConnection) {
        // Show connected user with chat option
        return Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.wifi_tethering,
                size: 64,
                color: Colors.green,
              ),
              SizedBox(height: 16),
              Text(
                'Connected!',
                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  color: Colors.green,
                ),
              ),
              SizedBox(height: 8),
              nameAsync.when(
                data: (name) => Text(
                  'Chatting with: $name',
                  style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
                loading: () => Text('Loading name...'),
                error: (err, stack) => Text('Connected to unknown device'),
              ),
              SizedBox(height: 24),
              FilledButton.icon(
  onPressed: () {
    // Create a fake central object for navigation
    final fakeCentral = Central(uuid: UUID.fromString('00000000-0000-0000-0000-000000000000'));
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => ChatScreen(central: fakeCentral),
      ),
    );
  },
  icon: Icon(Icons.chat),
  label: Text('Open Chat'),
),
              SizedBox(height: 16),
              Text(
                'You are in discoverable mode',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        );
      }
      
      // Original discoverable mode content
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.wifi_tethering,
              size: 64,
              color: Theme.of(context).colorScheme.primary,
            ),
            SizedBox(height: 16),
            Text(
              'Discoverable Mode',
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                color: Theme.of(context).colorScheme.primary,
              ),
            ),
            SizedBox(height: 8),
            Text(
              'Your device is now discoverable.\nOther devices can find and connect to you.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            SizedBox(height: 24),
            Text(
              'Switch to "Scanner" mode to find other devices',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      );
    },
  );
}

  Widget _buildEmptyState(String message, IconData icon) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            icon,
            size: 64,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
          SizedBox(height: 16),
          Text(
            message,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyLarge?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPlatformBanner() {
  if (Platform.isWindows) {
    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(12),
      color: Theme.of(context).colorScheme.surfaceVariant,
      child: Row(
        children: [
          Icon(
            Icons.info_outline,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
            size: 20,
          ),
          SizedBox(width: 8),
          Text(
            'Windows: Scanner mode only',
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }
  return SizedBox.shrink();
}

  Future<void> _startScanning() async {
    if (_isScanning) return;
    
    final bleService = ref.read(bleServiceProvider);
    if (bleService.isPeripheralMode) {
      _showError('Cannot scan while in discoverable mode. Switch to Scanner mode first.');
      return;
    }
    
    try {
      await bleService.startScanning();
      setState(() {
        _isScanning = true;
      });
      
      // Auto-stop scanning after 30 seconds
      Future.delayed(Duration(seconds: 30), () {
        if (mounted && _isScanning) {
          _stopScanning();
        }
      });
    } catch (e) {
      _showError('Failed to start scanning: $e');
    }
  }

  Future<void> _stopScanning() async {
    if (!_isScanning) return;
    
    try {
      final bleService = ref.read(bleServiceProvider);
      await bleService.stopScanning();
      setState(() {
        _isScanning = false;
      });
    } catch (e) {
      _showError('Failed to stop scanning: $e');
    }
  }

void _connectToDevice(Peripheral device, bleService) async {
  if (bleService.isConnected) {
    // If connected to any device, go to chat with this device
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => ChatScreen(device: device),
      ),
    );
    return;
  }
  
  // Rest of connection logic...
  if (_isScanning) {
    await _stopScanning();
  }
  
  showDialog(
    context: context,
    barrierDismissible: false,
    builder: (context) => AlertDialog(
      content: Row(
        children: [
          CircularProgressIndicator(),
          SizedBox(width: 16),
          Text('Connecting...'),
        ],
      ),
    ),
  );

  try {
    _logger.info('Connection attempt for ${device.uuid}');
    await bleService.connectToDevice(device);
    if (_isScanning) {
  	await _stopScanning();
    }
    setState(() {});
    
    if (mounted) Navigator.pop(context);
    
       String? currentName = bleService.otherUserName;
  if (currentName == null || currentName.isEmpty) {
    _logger.info('Waiting for identity exchange...');
    // Wait up to 5 seconds for identity exchange
    for (int i = 0; i < 50; i++) {
      await Future.delayed(Duration(milliseconds: 100));
      currentName = bleService.otherUserName;
      if (currentName != null && currentName.isNotEmpty) {
        _logger.info('Identity exchange completed: $currentName');
        break;
      }
    }
  }
  
  if (mounted) {
  // Allow connection phase to stabilize before opening chat
  await Future.delayed(Duration(milliseconds: 500));
  
  if (mounted) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => ChatScreen(device: device),
      ),
    );
  }
}
} catch (e) {
    if (mounted) Navigator.pop(context);
    _showError('Connection failed: ${e.toString().split(':').last}');
    _logger.warning('Connection failed: $e');
  }
}

  void _switchToCentralMode() async {
    try {
      _logger.info('Switching to central mode...');
      
      // Cancel connection listener when switching away from peripheral
      _connectionSubscription?.cancel();
      
      final bleService = ref.read(bleServiceProvider);
      await bleService.startAsCentral();
      
      await Future.delayed(Duration(milliseconds: 1000));
      
      setState(() {});
      _showSuccess('Switched to Scanner mode - you can now discover other devices');
      
      Future.delayed(Duration(milliseconds: 500), () {
        if (mounted && !bleService.isPeripheralMode) {
          _startScanning();
        }
      });
    } catch (e) {
      _showError('Failed to switch mode: $e');
    }
  }

  void _switchToPeripheralMode() async {
    try {
      _logger.info('Switching to peripheral mode...');
      
      if (_isScanning) {
        await _stopScanning();
      }
      
      final bleService = ref.read(bleServiceProvider);
      await bleService.startAsPeripheral();
      
      await Future.delayed(Duration(milliseconds: 1500));
      
      // Re-setup connection listener for peripheral mode
      _setupConnectionListener();
      
      setState(() {});
      _showSuccess('Switched to Discoverable mode - other devices can now find you');
    } catch (e) {
      _showError('Failed to switch mode: $e');
    }
  }

  void _showModeExplanation() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Mode Explanation'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('📡 Scanner Mode:', style: TextStyle(fontWeight: FontWeight.bold)),
            Text('• Looks for nearby discoverable devices'),
            Text('• Can connect to other devices'),
            SizedBox(height: 12),
            Text('📱 Discoverable Mode:', style: TextStyle(fontWeight: FontWeight.bold)),
            Text('• Makes your device visible to others'),
            Text('• Other devices can connect to you'),
            SizedBox(height: 12),
            Text('💡 Tip: One device should be Discoverable, the other should be Scanner'),
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

 void _showIncomingConnectionDialog(Central central) {
  _logger.info('Showing incoming connection dialog for central: ${central.uuid}');
  
  if (!mounted) {
    _logger.warning('Widget not mounted, cannot show dialog');
    return;
  }
  
  // More robust dialog check
  final route = ModalRoute.of(context);
  if (route != null && !route.isCurrent) {
    _logger.warning('Another route is active, skipping dialog');
    return;
  }
  
  showDialog(
    context: context,
    barrierDismissible: false,
    builder: (context) => AlertDialog(
      title: Row(
        children: [
          Icon(Icons.chat, color: Theme.of(context).colorScheme.primary),
          SizedBox(width: 8),
          Expanded(
            child: Text('Incoming Chat Request'),
          ),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Someone wants to chat with you!'),
          SizedBox(height: 12),
          Container(
            padding: EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceVariant,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              'Device: ${central.uuid.toString().substring(0, 8)}...',
              style: TextStyle(fontFamily: 'monospace'),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () {
            _logger.info('Chat request declined');
            Navigator.pop(context);
          },
          child: Text('Decline'),
        ),
        FilledButton(
          onPressed: () {
            _logger.info('Chat request accepted');
            Navigator.pop(context);
            _openChatForIncomingConnection(central);
          },
          child: Text('Accept'),
        ),
      ],
    ),
  );
}

  void _openChatForIncomingConnection(Central central) {
  Navigator.push(
    context,
    MaterialPageRoute(
      builder: (context) => ChatScreen(central: central),
    ),
  );
}

  void _showSettings(BuildContext context) {
  showModalBottomSheet(
    context: context,
    builder: (context) => Container(
      padding: EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'Settings',
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          SizedBox(height: 24),
          ListTile(
            leading: Icon(Icons.person),
            title: Text('Display Name'),
            subtitle: Text('Change how others see you'),
            onTap: () {
              Navigator.pop(context);
              _editDisplayName();
            },
          ),
          ListTile(
            leading: Icon(Icons.lock),
            title: Text('Encryption Key'),
            subtitle: Text('View or change encryption passphrase'),
            onTap: () {
              Navigator.pop(context);
              _editPassphrase();
            },
          ),
          ListTile(
            leading: Icon(Icons.info),
            title: Text('About'),
            subtitle: Text('App version and info'),
            onTap: () {
              Navigator.pop(context);
              _showAbout();
            },
          ),
        ],
      ),
    ),
  );
}

void _editPassphrase() async {
  final bleService = ref.read(bleServiceProvider);
  final currentPassphrase = await bleService.getCurrentPassphrase();
  
  final result = await showDialog<String?>(
    context: context,
    builder: (context) {
      final controller = TextEditingController();
      return AlertDialog(
        title: Text('Encryption Passphrase'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Current: $currentPassphrase'),
            SizedBox(height: 16),
            TextField(
              controller: controller,
              decoration: InputDecoration(
                labelText: 'New Passphrase',
                hintText: 'Leave empty to auto-generate',
                border: OutlineInputBorder(),
              ),
            ),
            SizedBox(height: 8),
            Text(
              'Both devices must use the same passphrase',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, null),
            child: Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, 'AUTO_GENERATE'),
            child: Text('Auto-Generate'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: Text('Save'),
          ),
        ],
      );
    },
  );
  
  if (result != null) {
    if (result == 'AUTO_GENERATE') {
      // Auto-generate new passphrase
      await bleService.generateNewPassphrase();
      final newPassphrase = await bleService.getCurrentPassphrase();
      _showSuccess('New passphrase generated: $newPassphrase');
    } else if (result.isNotEmpty) {
      await bleService.setCustomPassphrase(result);
      _showSuccess('Passphrase updated');
    }
  }
}
void _editDisplayName() async {
  final bleService = ref.read(bleServiceProvider);
  final currentName = bleService.myUserName ?? 'User';
  
  final newName = await showDialog<String>(
    context: context,
    builder: (context) => EditNameDialog(currentName: currentName),
  );
  
  if (newName != null && newName != currentName) {
    await bleService.setMyUserName(newName);
    _showSuccess('Display name updated to "$newName"');
  }
}

  void _showAbout() {
    showAboutDialog(
      context: context,
      applicationName: 'BLE Chat',
      applicationVersion: '1.0.0',
      children: [
        Text('Secure offline messaging for family and friends.'),
      ],
    );
  }

  void _showError(String message) {
      _logger.warning('Error: $message');
  }

  void _showSuccess(String message) {
    _logger.info('Success: $message');  
  }

  @override
  void dispose() {
    _connectionSubscription?.cancel();
    if (_isScanning) {
      final bleService = ref.read(bleServiceProvider);
      bleService.stopScanning();
    }
    super.dispose();
  }
}