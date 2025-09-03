import 'dart:io' show Platform;
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
  bool _navigatedToChat = false;
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
  
  if (!_hasInitialized) {
    _hasInitialized = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _initializeScreen();
    });
  } else if (!_navigatedToChat) {
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
  
  // Don't refresh if navigated to chat
  if (_navigatedToChat) {
    return;
  }
  
  setState(() {}); 
  
  // Only start scanning if truly disconnected and not already scanning
  if (!bleService.isPeripheralMode && 
      !_isScanning && 
      !bleService.isConnected &&
      !_navigatedToChat) {
    Future.delayed(Duration(milliseconds: 300), () {
      if (mounted && !_navigatedToChat && !bleService.isConnected) {
        _startScanning();
      }
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

  final connectionInfoAsync = ref.watch(connectionInfoProvider);
  final actualConnectionState = connectionInfoAsync.maybeWhen(
    data: (info) => info,
    orElse: () => null,
  );

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
      final connectionInfoAsync = ref.watch(connectionInfoProvider);

   final hasConnection = connectionInfoAsync.maybeWhen(
        data: (info) {
          // Only show connected if we're in peripheral mode AND have a real connection
          return bleService.isPeripheralMode && 
                 info.otherUserName != null && 
                 info.otherUserName!.isNotEmpty;
        },
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
              connectionInfoAsync.when(
                data: (info) => Text(
                  'Chatting with: ${info.otherUserName}',
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
  
  // Don't scan if connected
  if (bleService.isConnected) {
    _logger.info('Already connected, not starting scan');
    return;
  }
  
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
      if (mounted && _isScanning && !bleService.isConnected) {
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
  // Check if already connected to this specific device
  if (bleService.isConnected && bleService.connectedDevice?.uuid == device.uuid) {
    setState(() {
      _navigatedToChat = true;  // Set flag before navigation
    });
    
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => ChatScreen(device: device),
      ),
    );
    
    setState(() {
      _navigatedToChat = false;  // Clear flag when returning
    });
    return;
  }
  
  // Stop scanning if active
  if (_isScanning) {
    await _stopScanning();
    setState(() {
      _isScanning = false;
    });
  }
  
  // Show connecting dialog
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
    
    setState(() {});
    
    if (mounted) Navigator.pop(context);  // Close connecting dialog
    
    // Wait for identity exchange
    String? currentName = bleService.otherUserName;
    if (currentName == null || currentName.isEmpty) {
      _logger.info('Waiting for identity exchange...');
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
      setState(() {
        _navigatedToChat = true;
      });
      
      await Future.delayed(Duration(milliseconds: 500));
      
      if (mounted) {
        await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => ChatScreen(device: device),
          ),
        );
        
        // When returning from chat
        setState(() {
          _navigatedToChat = false;
        });

         final bleService = ref.read(bleServiceProvider);
    if (bleService.isConnected) {
      setState(() {});
    }
      }
    }
  } catch (e) {
    if (mounted) Navigator.pop(context);  // Close connecting dialog
    _showError('Connection failed: ${e.toString().split(':').last}');
    _logger.warning('Connection failed: $e');
  }
}

void _switchToCentralMode() async {
  try {
    _logger.info('Switching to central mode...');
    
    // CRITICAL: Clear navigation flag when switching modes
    _navigatedToChat = false;
    
    if (_isScanning) {
      _isScanning = false;
    }
    
    _connectionSubscription?.cancel();
    
    final bleService = ref.read(bleServiceProvider);
    await bleService.startAsCentral();
    
    await Future.delayed(Duration(milliseconds: 1000));
    
    if (mounted) {
      setState(() {
        _navigatedToChat = false;  // Ensure it's cleared
      });
      _showSuccess('Switched to Scanner mode');
      
      Future.delayed(Duration(milliseconds: 500), () {
        if (mounted && !bleService.isPeripheralMode && !_navigatedToChat) {
          _startScanning();
        }
      });
    }
  } catch (e) {
    _showError('Failed to switch mode: $e');
  }
}

void _switchToPeripheralMode() async {
  try {
    _logger.info('Switching to peripheral mode...');
    
    // CRITICAL: Clear navigation flag when switching modes
    _navigatedToChat = false;
    
    if (_isScanning) {
      await _stopScanning();
      _isScanning = false;
    }
    
    final bleService = ref.read(bleServiceProvider);
    await bleService.startAsPeripheral();
    
    await Future.delayed(Duration(milliseconds: 1500));
    
    _setupConnectionListener();
    
    if (mounted) {
      setState(() {
        _navigatedToChat = false;  // Ensure it's cleared
      });
      _showSuccess('Switched to Discoverable mode');
    }
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
          Row(
            children: [
              Icon(Icons.settings),
              SizedBox(width: 12),
              Text(
                'Settings',
                style: Theme.of(context).textTheme.headlineSmall,
              ),
            ],
          ),
          SizedBox(height: 24),
          ListTile(
            leading: Icon(Icons.person),
            title: Text('Your Name'),
            subtitle: Text('How others see you in chats'),
            onTap: () {
              Navigator.pop(context);
              _editDisplayName();
            },
          ),
          ListTile(
            leading: Icon(Icons.security),
            title: Text('Chat Security'),
            subtitle: Text('Manage encryption and device pairing'),
            onTap: () {
              Navigator.pop(context);
              _editPassphrase();
            },
          ),
          ListTile(
            leading: Icon(Icons.help_outline),
            title: Text('How to Connect'),
            subtitle: Text('Step-by-step pairing guide'),
            onTap: () {
              Navigator.pop(context);
              _showPairingGuide();
            },
          ),
          ListTile(
            leading: Icon(Icons.info),
            title: Text('About'),
            subtitle: Text('App version and information'),
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
        title: Text('Chat Security'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.primaryContainer.withOpacity(0.3),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.lock, size: 16, color: Theme.of(context).colorScheme.primary),
                      SizedBox(width: 8),
                      Text(
                        'Your messages are encrypted',
                        style: TextStyle(
                          fontWeight: FontWeight.w500,
                          color: Theme.of(context).colorScheme.primary,
                        ),
                      ),
                    ],
                  ),
                  SizedBox(height: 8),
                  Text(
                    'Both devices must use the same security phrase to chat together.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            SizedBox(height: 16),
            Text(
              'Current phrase:',
              style: Theme.of(context).textTheme.labelMedium,
            ),
            SizedBox(height: 4),
            Container(
              width: double.infinity,
              padding: EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceVariant,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      currentPassphrase,
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 14,
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: currentPassphrase));
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text('Phrase copied to clipboard'),
                          duration: Duration(seconds: 2),
                        ),
                      );
                    },
                    icon: Icon(Icons.copy, size: 18),
                    tooltip: 'Copy phrase',
                  ),
                ],
              ),
            ),
            SizedBox(height: 16),
            TextField(
              controller: controller,
              decoration: InputDecoration(
                labelText: 'New security phrase (optional)',
                hintText: 'Leave empty to generate new phrase',
                border: OutlineInputBorder(),
                helperText: 'Share this phrase with people you want to chat with',
              ),
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
            child: Text('Generate New'),
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
      await bleService.generateNewPassphrase();
      final newPassphrase = await bleService.getCurrentPassphrase();
      
      // Show success with sharing instructions
      showDialog(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('New Security Phrase Generated'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: double.infinity,
                padding: EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.primaryContainer,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        newPassphrase,
                        style: TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    IconButton(
                      onPressed: () {
                        Clipboard.setData(ClipboardData(text: newPassphrase));
                        Navigator.pop(context);
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text('Phrase copied!')),
                        );
                      },
                      icon: Icon(Icons.copy),
                    ),
                  ],
                ),
              ),
              SizedBox(height: 12),
              Text(
                'Share this phrase with people you want to chat with. Both devices need the same phrase.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
          actions: [
            FilledButton(
              onPressed: () => Navigator.pop(context),
              child: Text('Got it'),
            ),
          ],
        ),
      );
    } else if (result.isNotEmpty) {
      await bleService.setCustomPassphrase(result);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Security phrase updated')),
      );
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
    applicationIcon: Container(
      width: 48,
      height: 48,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.primary,
        shape: BoxShape.circle,
      ),
      child: Icon(
        Icons.bluetooth,
        color: Theme.of(context).colorScheme.onPrimary,
        size: 24,
      ),
    ),
    children: [
      SizedBox(height: 16),
      Text('Secure offline messaging for family and friends.'),
      SizedBox(height: 12),
      Text(
        'Features:',
        style: TextStyle(fontWeight: FontWeight.w600),
      ),
      Text('• Works without internet'),
      Text('• End-to-end encrypted messages'),
      Text('• Cross-platform compatibility'),
      Text('• No data collection'),
      SizedBox(height: 12),
      Text(
        'Your messages never leave your devices.',
        style: TextStyle(
          fontStyle: FontStyle.italic,
          color: Theme.of(context).colorScheme.primary,
        ),
      ),
    ],
  );
}

void _showPairingGuide() {
  showDialog(
    context: context,
    builder: (context) => AlertDialog(
      title: Row(
        children: [
          Icon(Icons.help_outline, color: Theme.of(context).colorScheme.primary),
          SizedBox(width: 12),
          Text('How to Connect Devices'),
        ],
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildGuideStep(
              context,
              '1',
              'Choose Device Roles',
              'One device should be in "Discoverable" mode, the other in "Scanner" mode.',
            ),
            _buildGuideStep(
              context,
              '2',
              'Share Security Phrase',
              'Both devices must use the same security phrase. Go to Settings > Chat Security to copy your phrase.',
            ),
            _buildGuideStep(
              context,
              '3',
              'Start Connection',
              'Scanner device will find the Discoverable device. Tap to connect.',
            ),
            _buildGuideStep(
              context,
              '4',
              'Begin Chatting',
              'Once "Ready to chat" appears, you can send messages securely.',
            ),
            SizedBox(height: 16),
            Container(
              padding: EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceVariant,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  Icon(Icons.lightbulb_outline, size: 20),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Tip: Stay within 30 feet of each other for best connection.',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.pop(context),
          child: Text('Got it'),
        ),
      ],
    ),
  );
}

Widget _buildGuideStep(BuildContext context, String number, String title, String description) {
  return Padding(
    padding: EdgeInsets.only(bottom: 16),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 24,
          height: 24,
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.primary,
            shape: BoxShape.circle,
          ),
          child: Center(
            child: Text(
              number,
              style: TextStyle(
                color: Theme.of(context).colorScheme.onPrimary,
                fontSize: 12,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ),
        SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              SizedBox(height: 4),
              Text(
                description,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ],
    ),
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