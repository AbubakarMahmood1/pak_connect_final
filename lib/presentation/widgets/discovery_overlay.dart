import 'dart:io' show Platform;
import 'dart:async';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:bluetooth_low_energy/bluetooth_low_energy.dart' hide ConnectionState;
import 'package:bluetooth_low_energy/bluetooth_low_energy.dart' as ble;
import 'package:logging/logging.dart';
import '../../data/services/ble_service.dart';
import '../../core/models/connection_info.dart';
import '../providers/ble_providers.dart';
import '../../data/repositories/contact_repository.dart';
import 'burst_status_widget.dart';
import '../../core/security/hint_cache_manager.dart';
import '../screens/chat_screen.dart';
import '../../core/scanning/burst_scanning_controller.dart';

class DiscoveryOverlay extends ConsumerStatefulWidget {
  final VoidCallback onClose;
  final Function(Peripheral) onDeviceSelected;
  
  const DiscoveryOverlay({
    super.key,
    required this.onClose,
    required this.onDeviceSelected,
  });
  
  @override
  ConsumerState<DiscoveryOverlay> createState() => _DiscoveryOverlayState();
}

class _DiscoveryOverlayState extends ConsumerState<DiscoveryOverlay>
    with SingleTickerProviderStateMixin {
  final _logger = Logger('DiscoveryOverlay');
  bool _isScanning = false;
  late AnimationController _animationController;
  late Animation<double> _fadeAnimation;
  late Animation<double> _scaleAnimation;
  StreamSubscription? _connectionSubscription;
  final ContactRepository _contactRepository = ContactRepository();
  Map<String, Contact> _contacts = {};

  // Device list management
  static const int _maxDevices = 50;
  Timer? _deviceCleanupTimer;
  final Map<String, DateTime> _deviceLastSeen = {};
  
  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(
      duration: Duration(milliseconds: 300),
      vsync: this,
    );

    _fadeAnimation = CurvedAnimation(
      parent: _animationController,
      curve: Curves.easeInOut,
    );

    _scaleAnimation = Tween<double>(
      begin: 0.9,
      end: 1.0,
    ).animate(CurvedAnimation(
      parent: _animationController,
      curve: Curves.easeOutBack,
    ));

    _animationController.forward();
    _loadContacts();
    _updateHintCache();

    // Start device cleanup timer
    _deviceCleanupTimer = Timer.periodic(Duration(minutes: 1), _cleanupStaleDevices);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _initializeDiscovery();
    });
  }
  
  Future<void> _loadContacts() async {
    final contacts = await _contactRepository.getAllContacts();
    if (mounted) {
      setState(() => _contacts = contacts);
    }
  }
  
  Future<void> _updateHintCache() async {
    try {
      await HintCacheManager.updateCache();
      _logger.fine('✅ Hint cache updated for discovery overlay');
    } catch (e) {
      _logger.warning('Failed to update hint cache: $e');
    }
  }

  /// Get unified scanning state that considers both manual and burst scanning
  bool _getUnifiedScanningState() {
    final burstStatusAsync = ref.read(burstScanningStatusProvider);
    final isBurstActive = burstStatusAsync.value?.isBurstActive ?? false;
    return _isScanning || isBurstActive;
  }

  /// Clean up devices not seen recently
  void _cleanupStaleDevices(Timer timer) {
    final now = DateTime.now();
    final staleThreshold = Duration(minutes: 3);

    _deviceLastSeen.removeWhere((deviceId, lastSeen) {
      final isStale = now.difference(lastSeen) > staleThreshold;
      if (isStale) {
        _logger.fine('Removing stale device: $deviceId');
      }
      return isStale;
    });
  }

  /// Update device last seen timestamp
  void _updateDeviceLastSeen(String deviceId) {
    _deviceLastSeen[deviceId] = DateTime.now();
  }
  
  void _initializeDiscovery() {
    final bleService = ref.read(bleServiceProvider);

    // 🔧 FIXED: Don't auto-start scanning - let burst scanning handle timing
    // Only setup peripheral listener if needed
    if (Platform.isAndroid && bleService.isPeripheralMode) {
      _setupPeripheralListener();
    }

    // Note: Burst scanning controller will handle automatic scanning timing
    // Manual scanning is still available via the UI buttons
  }
  
  void _setupPeripheralListener() {
    final bleService = ref.read(bleServiceProvider);
    
    _connectionSubscription?.cancel();
    _connectionSubscription = bleService.peripheralManager.connectionStateChanged
      .distinct((prev, next) => 
        prev.central.uuid == next.central.uuid && prev.state == next.state)
      .listen((event) {
        if (event.state == ble.ConnectionState.connected) {
          _logger.info('Incoming connection detected');
          _handleIncomingConnection(event.central);
        }
      });
  }
  
  void _handleIncomingConnection(Central central) async {
  if (!mounted) return;
    setState(() {});
  }
  
  Future<void> _startScanning() async {
    if (_isScanning) return;
    _logger.fine('🔍 OVERLAY DEBUG: Starting manual scan request - _isScanning was $_isScanning');
    setState(() => _isScanning = true);

    try {
      // 🔧 INTEGRATION: Use burst scanning operations for better coordination
      final burstOperations = ref.read(burstScanningOperationsProvider);

      // This will trigger manual override that takes priority over burst scanning
      if (burstOperations != null) {
        await burstOperations.triggerManualScan();
      } else {
        // Fallback to direct BLE service if burst operations not available
        final bleService = ref.read(bleServiceProvider);
        await bleService.startScanning(source: ScanningSource.manual);
      }

      _logger.info('✅ MANUAL: Manual scan started via burst controller');

      // Auto-stop after 10 seconds
      Future.delayed(Duration(seconds: 10), () {
        if (mounted && _isScanning) {
          _stopScanning();
        }
      });
    } catch (e) {
      _logger.warning('Failed to start manual scanning: $e');
      if (mounted) {
        setState(() => _isScanning = false);
        _showError('Failed to start scanning');
      }
    }
  }
  
  Future<void> _stopScanning() async {
    if (!_isScanning) return;
    
    try {
      final bleService = ref.read(bleServiceProvider);
      await bleService.stopScanning();
    } finally {
      if (mounted) {
        setState(() => _isScanning = false);
      }
    }
  }
  
  Future<void> _connectToDevice(Peripheral device) async {
  await _stopScanning();
  
  if (!mounted) return;

  // Show connecting dialog
  showDialog(
    context: context,
    barrierDismissible: false,
    builder: (dialogContext) => AlertDialog(
      content: Row(
        children: [
          CircularProgressIndicator(),
          SizedBox(width: 20),
          Expanded(child: Text('Connecting to device...')),
        ],
      ),
    ),
  );
  
  try {
    final bleService = ref.read(bleServiceProvider);
    await bleService.connectToDevice(device);
    
    // Wait for identity exchange
    await Future.delayed(Duration(seconds: 2));
    
    if (mounted) {
      Navigator.pop(context);
      setState(() {});
    }
    
  } catch (e) {
    if (mounted) {
      Navigator.pop(context);
      _showError('Connection failed: ${e.toString()}');
    }
  }
}
  
  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: Theme.of(context).colorScheme.error,
      ),
    );
  }
  
  Future<void> _switchMode(bool toPeripheral) async {
    final bleService = ref.read(bleServiceProvider);
    
    try {
      if (toPeripheral) {
        await _stopScanning();
        await bleService.startAsPeripheral();
        _setupPeripheralListener();
      } else {
        _connectionSubscription?.cancel();
        await bleService.startAsCentral();
        await Future.delayed(Duration(milliseconds: 500));
        _startScanning();
      }
    } catch (e) {
      _showError('Failed to switch mode: $e');
    }
  }
  
  @override
Widget build(BuildContext context) {
  final bleService = ref.watch(bleServiceProvider);
  final connectionInfo = ref.watch(connectionInfoProvider).value;
  final discoveredDevicesAsync = ref.watch(discoveredDevicesProvider);
  final discoveryDataAsync = ref.watch(discoveryDataProvider);
  
  return Material(
    color: Colors.transparent,
    child: Stack(
      children: [
        // Background with blur effect and tap OR swipe to close
        Positioned.fill(
          child: GestureDetector(
            onTap: widget.onClose,
            onVerticalDragEnd: (details) {
              // Swipe down to close
              if (details.velocity.pixelsPerSecond.dy > 300) {
                widget.onClose();
              }
            },
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 8.0, sigmaY: 8.0),
              child: Container(
                color: Colors.black.withValues(alpha: 0.3), // 🔧 IMPROVED: Subtle overlay with blur
              ),
            ),
          ),
        ),
        
        // Content modal
        Center(
	  child: GestureDetector(
            onVerticalDragEnd: (details) {
              // Swipe down on modal to close
              if (details.velocity.pixelsPerSecond.dy > 500) {
                widget.onClose();
              }
            },
          child: FadeTransition(
            opacity: _fadeAnimation,
            child: ScaleTransition(
              scale: _scaleAnimation,
              child: GestureDetector(
                onTap: () {}, // Prevent close when tapping modal
                child: Container(
                  width: MediaQuery.of(context).size.width * 0.9,
                  constraints: BoxConstraints(
                    maxHeight: MediaQuery.of(context).size.height * 0.85, // Increased height
                    minHeight: MediaQuery.of(context).size.height * 0.5,
                  ),
                  decoration: BoxDecoration(
                    color: Theme.of(context).scaffoldBackgroundColor,
                    borderRadius: BorderRadius.circular(24),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(),
                        blurRadius: 20,
                        spreadRadius: 5,
                      ),
                    ],
                  ),
                  child: Column(
                    children: [
                      _buildHeader(context, bleService),
                      _buildModeSelector(bleService.isPeripheralMode),

                      // 🔧 REMOVED: Redundant burst status widget - now integrated into scan button

                      Expanded(
                        child: AnimatedSwitcher(
                          duration: Duration(milliseconds: 300),
                          child: bleService.isPeripheralMode
                            ? _buildPeripheralMode(connectionInfo)
                            : _buildScannerMode(
                                discoveredDevicesAsync, 
                                discoveryDataAsync
                              ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
             ),
            ),
          ),
        ),
      ],
    ),
  );
}
  
  Widget _buildHeader(BuildContext context, BLEService bleService) {
    return Container(
      padding: EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            Theme.of(context).colorScheme.primary.withValues(),
            Theme.of(context).colorScheme.primary.withValues(),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: Row(
        children: [
          Container(
            padding: EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.primary.withValues(),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(
              bleService.isPeripheralMode 
                ? Icons.wifi_tethering 
                : Icons.bluetooth_searching,
              color: Theme.of(context).colorScheme.primary,
            ),
          ),
          SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Discover Devices',
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                ),
                Text(
                  bleService.isPeripheralMode 
                    ? 'Others can find you' 
                    : 'Finding nearby devices',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            onPressed: widget.onClose,
            icon: Icon(Icons.close),
            style: IconButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
            ),
          ),
        ],
      ),
    );
  }
  
  Widget _buildModeSelector(bool isPeripheralMode) {
    return Container(
      margin: EdgeInsets.all(16),
      child: SegmentedButton<bool>(
        segments: [
          ButtonSegment(
            value: false,
            label: Text('Scanner'),
            icon: Icon(Icons.search),
          ),
          ButtonSegment(
            value: true,
            label: Text('Discoverable'),
            icon: Icon(Icons.wifi_tethering),
          ),
        ],
        selected: {isPeripheralMode},
        onSelectionChanged: (Set<bool> selection) {
          _switchMode(selection.first);
        },
      ),
    );
  }
  
Widget _buildScannerMode(
    AsyncValue<List<Peripheral>> devicesAsync,
    AsyncValue<Map<String, DiscoveredEventArgs>> discoveryDataAsync,
  ) {
    return Column(
    children: [
      // 🔧 MINIMALIST: Scanning circle with countdown instead of cluttered button
      _buildMinimalistScanningCircle(),

      SizedBox(height: 8),
      Divider(),
        
        // Device list
        Expanded(
          child: devicesAsync.when(
            data: (devices) {
              if (devices.isEmpty) {
                return _buildEmptyState();
              }

              final discoveryData = discoveryDataAsync.value ?? {};

              // Update device last seen timestamps
              for (final device in devices) {
                _updateDeviceLastSeen(device.uuid.toString());
              }

              // Filter out stale devices
              final now = DateTime.now();
              final staleThreshold = Duration(minutes: 3);
              final freshDevices = devices.where((device) {
                final lastSeen = _deviceLastSeen[device.uuid.toString()];
                return lastSeen != null &&
                    now.difference(lastSeen) <= staleThreshold;
              }).toList();

              // Categorize devices
              final newDevices = <Peripheral>[];
              final knownDevices = <Peripheral>[];

              for (final device in freshDevices) {
                // Check if this is a known contact by public key
                final isKnown = _contacts.values.any((contact) =>
                    contact.publicKey.contains(device.uuid.toString()));

                if (isKnown) {
                  knownDevices.add(device);
                } else {
                  newDevices.add(device);
                }
              }

              // Sort devices by signal strength (if available)
              knownDevices.sort((a, b) {
                final rssiA = discoveryData[a.uuid.toString()]?.rssi ?? -100;
                final rssiB = discoveryData[b.uuid.toString()]?.rssi ?? -100;
                return rssiB.compareTo(rssiA); // Higher RSSI first
              });

              newDevices.sort((a, b) {
                final rssiA = discoveryData[a.uuid.toString()]?.rssi ?? -100;
                final rssiB = discoveryData[b.uuid.toString()]?.rssi ?? -100;
                return rssiB.compareTo(rssiA); // Higher RSSI first
              });

              // Apply device limits
              final limitedKnownDevices = knownDevices.take(_maxDevices ~/ 2).toList();
              final limitedNewDevices = newDevices.take(_maxDevices ~/ 2).toList();
              final totalShown = limitedKnownDevices.length + limitedNewDevices.length;
              final totalAvailable = knownDevices.length + newDevices.length;
              
              return ListView(
                padding: EdgeInsets.symmetric(vertical: 8),
                children: [
                  // Known contacts section
                  if (limitedKnownDevices.isNotEmpty) ...[
                    _buildSectionHeader(
                        'Known Contacts',
                        Icons.people,
                        limitedKnownDevices.length,
                        knownDevices.length > limitedKnownDevices.length
                            ? '${knownDevices.length - limitedKnownDevices.length} more'
                            : null),
                    ...limitedKnownDevices.map((device) => _buildDeviceItem(
                          device,
                          discoveryData[device.uuid.toString()],
                          true,
                        )),
                  ],

                  // Separator between sections if both have devices
                  if (limitedKnownDevices.isNotEmpty && limitedNewDevices.isNotEmpty)
                    Padding(
                      padding: EdgeInsets.symmetric(vertical: 8),
                      child: Divider(),
                    ),

                  // New devices section
                  if (limitedNewDevices.isNotEmpty) ...[
                    _buildSectionHeader(
                        'New Devices',
                        Icons.devices_other,
                        limitedNewDevices.length,
                        newDevices.length > limitedNewDevices.length
                            ? '${newDevices.length - limitedNewDevices.length} more'
                            : null),
                    ...limitedNewDevices.map((device) => _buildDeviceItem(
                          device,
                          discoveryData[device.uuid.toString()],
                          false,
                        )),
                  ],

                  // Show more button if there are more devices
                  if (totalAvailable > totalShown)
                    Padding(
                      padding: EdgeInsets.all(16),
                      child: OutlinedButton.icon(
                        onPressed: () {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(
                                  'Showing $totalShown of $totalAvailable devices. Pull down to refresh for more.'),
                            ),
                          );
                        },
                        icon: Icon(Icons.expand_more),
                        label: Text(
                            '+ ${totalAvailable - totalShown} more devices'),
                      ),
                    ),

                  // Manual refresh button
                  if (totalShown > 0)
                    Padding(
                      padding: EdgeInsets.all(16),
                      child: OutlinedButton.icon(
                        onPressed: () async {
                          _deviceLastSeen.clear();
                          if (!_getUnifiedScanningState()) {
                            await _startScanning();
                          }
                        },
                        icon: Icon(Icons.refresh),
                        label: Text('Refresh Device List'),
                      ),
                    ),

                  // Bottom padding for better scroll experience
                  SizedBox(height: 80),
                ],
              );
            },
            loading: () => Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                CircularProgressIndicator(),
                SizedBox(height: 16),
                Text('Loading devices...'),
              ],
            ),
          ),
          error: (error, stack) => Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  Icons.error_outline, 
                  size: 48, 
                  color: Theme.of(context).colorScheme.error,
                ),
                SizedBox(height: 16),
                Text(
                  'Error loading devices',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                SizedBox(height: 8),
                Text(
                  error.toString(),
                  style: Theme.of(context).textTheme.bodySmall,
                  textAlign: TextAlign.center,
                ),
                SizedBox(height: 16),
                FilledButton.icon(
                  onPressed: _startScanning,
                  icon: Icon(Icons.refresh),
                  label: Text('Try Again'),
                ),
              ],
            ),
          ),
        ),
      ),
    ],
  );
}

  Widget _buildSectionHeader(String title, IconData icon, int count, [String? additionalInfo]) {
    return Container(
      padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Row(
        children: [
          Container(
            padding: EdgeInsets.all(4),
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
          SizedBox(width: 10),
          Text(
            title,
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
              color: Theme.of(context).colorScheme.primary,
              fontWeight: FontWeight.bold,
              letterSpacing: 0.5,
            ),
          ),
          SizedBox(width: 8),
          Container(
            padding: EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              '$count',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          if (additionalInfo != null) ...[
            SizedBox(width: 8),
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
  
  Widget _buildDeviceItem(
    Peripheral device,
    DiscoveredEventArgs? advertisement,
    bool isKnown,
  ) {
    // Get device name using enhanced name resolution
    String deviceName = 'Unknown Device';
    bool isContactResolved = false;
    
    // Try to resolve name from ephemeral hints in advertisement data
    if (advertisement != null && advertisement.advertisement.manufacturerSpecificData.isNotEmpty) {
      deviceName = _resolveDeviceNameFromHints(advertisement);
      isContactResolved = deviceName != 'Unknown Device';
    }
    
    // Fallback to contact system if hints didn't work
    if (!isContactResolved && isKnown) {
      final matchingContact = _contacts.values.where((contact) =>
        contact.publicKey.contains(device.uuid.toString())
      ).firstOrNull;
      
      if (matchingContact != null) {
        deviceName = matchingContact.displayName;
        isContactResolved = true;
      }
    }
    
    // Final fallback to UUID
    if (!isContactResolved) {
      deviceName = 'Device ${device.uuid.toString().substring(0, 8)}';
    }
    
    final rssi = advertisement?.rssi ?? -100;
    final signalStrength = _getSignalStrength(rssi);
    
    return Container(
      margin: EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Card(
        elevation: isContactResolved ? 2 : 1,
        child: ListTile(
          leading: Stack(
            children: [
              CircleAvatar(
                backgroundColor: isContactResolved
                  ? Theme.of(context).colorScheme.primary.withValues()
                  : Theme.of(context).colorScheme.surfaceContainerHighest,
                child: Icon(
                  isContactResolved ? Icons.person : Icons.bluetooth,
                  color: isContactResolved
                    ? Theme.of(context).colorScheme.primary
                    : Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
              if (isContactResolved)
                Positioned(
                  right: 0,
                  bottom: 0,
                  child: Container(
                    width: 12,
                    height: 12,
                    decoration: BoxDecoration(
                      color: Colors.green,
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white, width: 2),
                    ),
                  ),
                ),
            ],
          ),
          title: Text(
            deviceName,
            style: TextStyle(
              fontWeight: isContactResolved ? FontWeight.bold : FontWeight.normal,
            ),
          ),
          subtitle: Row(
            children: [
              Icon(
                _getSignalIcon(signalStrength),
                size: 16,
                color: _getSignalColor(signalStrength),
              ),
              SizedBox(width: 4),
              Text(
                'Signal: $signalStrength',
                style: TextStyle(fontSize: 12),
              ),
              if (isContactResolved) ...[
                SizedBox(width: 8),
                Container(
                  padding: EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.primary.withValues(),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    'CONTACT',
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                  ),
                ),
              ],
            ],
          ),
          trailing: Icon(Icons.chevron_right),
onTap: () {
  // Check if already connected to this device
  final bleService = ref.read(bleServiceProvider);
  if (bleService.connectedDevice?.uuid == device.uuid) {
    // Already connected - open chat
    widget.onClose();
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => ChatScreen(device: device),
      ),
    );
  } else {
    // Not connected - connect first
    _connectToDevice(device);
  }
},
        ),
      ),
    );
  }
  
  /// Resolve device name from ephemeral hints in advertisement data
  String _resolveDeviceNameFromHints(DiscoveredEventArgs advertisement) {
    try {
      // Check manufacturer specific data for ephemeral hints
      for (final manufacturerData in advertisement.advertisement.manufacturerSpecificData) {
        final data = manufacturerData.data;
        if (data.isNotEmpty) {
          // Try to decode as ephemeral hint
          final hintString = String.fromCharCodes(data);
          final contactHint = HintCacheManager.getContactFromCache(hintString);
          
          if (contactHint != null) {
            _logger.fine('✅ Resolved device name from hint: ${contactHint.contact.contact.displayName}');
            return contactHint.contact.contact.displayName;
          }
        }
      }
      
      // Also check service data
      for (final entry in advertisement.advertisement.serviceData.entries) {
        final data = entry.value;
        if (data.isNotEmpty) {
          final hintString = String.fromCharCodes(data);
          final contactHint = HintCacheManager.getContactFromCache(hintString);
          
          if (contactHint != null) {
            _logger.fine('✅ Resolved device name from service hint: ${contactHint.contact.contact.displayName}');
            return contactHint.contact.contact.displayName;
          }
        }
      }
    } catch (e) {
      _logger.warning('Error resolving device name from hints: $e');
    }
    
    return 'Unknown Device';
  }
  
  String _getSignalStrength(int rssi) {
    if (rssi >= -50) return 'Excellent';
    if (rssi >= -60) return 'Good';
    if (rssi >= -70) return 'Fair';
    return 'Poor';
  }
  
  IconData _getSignalIcon(String strength) {
    switch (strength) {
      case 'Excellent': return Icons.signal_wifi_4_bar;
      case 'Good': return Icons.network_wifi_3_bar;
      case 'Fair': return Icons.network_wifi_2_bar;
      default: return Icons.network_wifi_1_bar;
    }
  }
  
  Color _getSignalColor(String strength) {
    switch (strength) {
      case 'Excellent': return Colors.green;
      case 'Good': return Colors.lightGreen;
      case 'Fair': return Colors.orange;
      default: return Colors.red;
    }
  }
  
  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.bluetooth_disabled,
            size: 64,
            color: Theme.of(context).colorScheme.onSurfaceVariant.withValues(),
          ),
          SizedBox(height: 20),
          Text(
            'Make sure other devices are in discoverable mode',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          if (!_getUnifiedScanningState()) ...[
            SizedBox(height: 24),
            FilledButton.icon(
              onPressed: _startScanning,
              icon: Icon(Icons.refresh),
              label: Text('Scan Now'),
            ),
          ],
        ],
      ),
    );
  }
  
  Widget _buildPeripheralMode(ConnectionInfo? connectionInfo) {
    final isConnected = connectionInfo?.isConnected ?? false;
    final hasIdentity = connectionInfo?.otherUserName != null;
    
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          TweenAnimationBuilder<double>(
            tween: Tween(begin: 0.0, end: 1.0),
            duration: Duration(seconds: 2),
            builder: (context, value, child) {
              return Stack(
                alignment: Alignment.center,
                children: [
                  // Pulsing circles
                  ...List.generate(3, (index) {
                    return TweenAnimationBuilder<double>(
                      tween: Tween(begin: 0.0, end: 1.0),
                      duration: Duration(seconds: 3),
                      builder: (context, animValue, child) {
                        final delay = index * 0.3;
                        final adjustedValue = ((animValue + delay) % 1.0);
                        return Container(
                          width: 120 + (adjustedValue * 100),
                          height: 120 + (adjustedValue * 100),
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: isConnected
                                ? Colors.green.withValues()
                                : Theme.of(context).colorScheme.primary
                                    .withValues(),
                              width: 2,
                            ),
                          ),
                        );
                      },
                    );
                  }),
                  // Center icon
                  Container(
                    width: 80,
                    height: 80,
                    decoration: BoxDecoration(
                      color: isConnected 
                        ? Colors.green 
                        : Theme.of(context).colorScheme.primary,
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      isConnected ? Icons.link : Icons.wifi_tethering,
                      size: 40,
                      color: Colors.white,
                    ),
                  ),
                ],
              );
            },
          ),
          SizedBox(height: 32),
        Text(
          isConnected ? 'Connected!' : 'Discoverable Mode',
          style: Theme.of(context).textTheme.headlineMedium?.copyWith(
            fontWeight: FontWeight.bold,
            color: isConnected ? Colors.green : null,
          ),
        ),
        SizedBox(height: 8),
        Text(
          isConnected 
            ? 'You are now connected'
            : 'Your device is visible to others',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodyLarge?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
        
        // NEW: Show chat button when connected with identity
        if (isConnected && hasIdentity) ...[
          SizedBox(height: 24),
          FilledButton.icon(
            onPressed: () {
              final bleService = ref.read(bleServiceProvider);
              final central = bleService.connectedCentral;
              if (central != null) {
                widget.onClose();
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => ChatScreen(central: central),
                  ),
                );
              }
            },
            icon: Icon(Icons.chat),
            label: Text('Chat with ${connectionInfo!.otherUserName}'),
          ),
        ],
      ],
    ),
  );
}

  /// Build minimalist scanning circle with countdown
  Widget _buildMinimalistScanningCircle() {
    return Consumer(
      builder: (context, ref, child) {
        final burstStatusAsync = ref.watch(burstScanningStatusProvider);
        final burstOperations = ref.read(burstScanningOperationsProvider);

        return Container(
          margin: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              burstStatusAsync.when(
                data: (burstStatus) => _buildScanningCircleWithStatus(burstStatus, burstOperations),
                loading: () => _buildLoadingScanningCircle(),
                error: (error, stack) => _buildErrorScanningCircle(),
              ),
            ],
          ),
        );
      },
    );
  }

  /// Build scanning circle based on current burst scanning status
  Widget _buildScanningCircleWithStatus(dynamic burstStatus, dynamic operations) {
    final theme = Theme.of(context);
    final isAnyScanning = _isScanning || burstStatus.isBurstActive;

    // Calculate progress for countdown circle using actual scan interval
    double? progress;
    if (!isAnyScanning && burstStatus.secondsUntilNextScan != null && burstStatus.secondsUntilNextScan! > 0) {
      // Use actual scan interval from burst status for accurate progress
      final totalSeconds = (burstStatus.currentScanInterval / 1000).round();
      final remaining = burstStatus.secondsUntilNextScan!;
      final calculatedProgress = (totalSeconds - remaining) / totalSeconds;
      progress = calculatedProgress.clamp(0.0, 1.0); // Ensure valid range
    }

    return GestureDetector(
      onTap: isAnyScanning ? null : () async {
        // Manual scan only when idle
        if (operations != null) {
          await operations.triggerManualScan();
        } else {
          await _startScanning();
        }
      },
      child: Container(
        width: 70,
        height: 70,
        child: Stack(
          alignment: Alignment.center,
          children: [
            // Background circle
            Container(
              width: 70,
              height: 70,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: isAnyScanning
                  ? theme.colorScheme.primary.withOpacity(0.1)
                  : theme.colorScheme.surfaceContainerHighest,
                border: Border.all(
                  color: isAnyScanning
                    ? theme.colorScheme.primary
                    : theme.colorScheme.outline.withOpacity(0.5),
                  width: 2,
                ),
              ),
            ),

            // Countdown progress circle (only when waiting)
            if (progress != null && !isAnyScanning)
              SizedBox(
                width: 70,
                height: 70,
                child: CircularProgressIndicator(
                  value: progress,
                  strokeWidth: 3,
                  backgroundColor: Colors.transparent,
                  valueColor: AlwaysStoppedAnimation(Colors.blue),
                ),
              ),

            // Center content
            if (isAnyScanning)
              // Spinning indicator when scanning
              SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                  strokeWidth: 2.5,
                  valueColor: AlwaysStoppedAnimation(Colors.blue),
                ),
              )
            else if (burstStatus.secondsUntilNextScan != null && burstStatus.secondsUntilNextScan! > 0)
              // Countdown number when waiting
              Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    '${burstStatus.secondsUntilNextScan}',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: theme.colorScheme.primary,
                    ),
                  ),
                  Text(
                    'sec',
                    style: TextStyle(
                      fontSize: 10,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              )
            else
              // Scan icon when ready
              Icon(
                Icons.bluetooth_searching,
                size: 28,
                color: theme.colorScheme.primary,
              ),
          ],
        ),
      ),
    );
  }

  /// Build loading scanning circle
  Widget _buildLoadingScanningCircle() {
    final theme = Theme.of(context);
    return Container(
      width: 80,
      height: 80,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: theme.colorScheme.surfaceContainerHighest,
        border: Border.all(
          color: theme.colorScheme.outline.withOpacity(0.5),
          width: 2,
        ),
      ),
      child: Center(
        child: SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            valueColor: AlwaysStoppedAnimation(theme.colorScheme.onSurfaceVariant),
          ),
        ),
      ),
    );
  }

  /// Build error scanning circle
  Widget _buildErrorScanningCircle() {
    final theme = Theme.of(context);
    return Container(
      width: 80,
      height: 80,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: theme.colorScheme.errorContainer,
        border: Border.all(
          color: theme.colorScheme.error,
          width: 2,
        ),
      ),
      child: Icon(
        Icons.error_outline,
        size: 28,
        color: theme.colorScheme.onErrorContainer,
      ),
    );
  }

  /// Build intelligent scan button that consolidates all scanning state
  Widget _buildIntelligentScanButton() {
    return Consumer(
      builder: (context, ref, child) {
        final burstStatusAsync = ref.watch(burstScanningStatusProvider);
        final burstOperations = ref.read(burstScanningOperationsProvider);

        return Container(
          margin: EdgeInsets.symmetric(horizontal: 16),
          child: burstStatusAsync.when(
            data: (burstStatus) => _buildScanButtonWithStatus(burstStatus, burstOperations),
            loading: () => _buildLoadingScanButton(),
            error: (error, stack) => _buildErrorScanButton(),
          ),
        );
      },
    );
  }

  /// Build scan button based on current burst scanning status
  Widget _buildScanButtonWithStatus(dynamic burstStatus, dynamic operations) {
    final theme = Theme.of(context);
    final isAnyScanning = _isScanning || burstStatus.isBurstActive;

    if (isAnyScanning) {
      // Any scanning in progress
      return _buildScanButton(
        icon: SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            valueColor: AlwaysStoppedAnimation<Color>(theme.colorScheme.onPrimary),
          ),
        ),
        label: _isScanning ? 'Scanning devices...' : 'Auto scanning...',
        onPressed: null,
        isActive: true,
      );
    } else if (burstStatus.secondsUntilNextScan != null &&
               burstStatus.secondsUntilNextScan! > 0 &&
               burstStatus.secondsUntilNextScan! <= 60) {
      // Countdown to next scan
      return _buildScanButton(
        icon: Icon(Icons.schedule, size: 20, color: theme.colorScheme.primary),
        label: 'Next scan in ${burstStatus.secondsUntilNextScan}s',
        onPressed: () async {
          if (operations != null) {
            await operations.triggerManualScan();
          } else {
            await _startScanning();
          }
        },
        isActive: false,
      );
    } else {
      // Ready to scan
      return _buildScanButton(
        icon: Icon(Icons.search, size: 20, color: theme.colorScheme.primary),
        label: 'Scan for devices',
        onPressed: () async {
          if (operations != null) {
            await operations.triggerManualScan();
          } else {
            await _startScanning();
          }
        },
        isActive: false,
      );
    }
  }

  /// Build the actual scan button with consistent styling
  Widget _buildScanButton({
    required Widget icon,
    required String label,
    required VoidCallback? onPressed,
    required bool isActive,
  }) {
    final theme = Theme.of(context);

    return Container(
      height: 56,
      width: double.infinity,
      child: FilledButton.icon(
        onPressed: onPressed,
        style: FilledButton.styleFrom(
          backgroundColor: isActive
              ? theme.colorScheme.primary
              : theme.colorScheme.primaryContainer,
          foregroundColor: isActive
              ? theme.colorScheme.onPrimary
              : theme.colorScheme.onPrimaryContainer,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
        icon: icon,
        label: Text(label),
      ),
    );
  }

  /// Build loading scan button
  Widget _buildLoadingScanButton() {
    return Container(
      height: 56,
      child: OutlinedButton.icon(
        onPressed: null,
        icon: SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
        label: Text('Initializing Scanner...'),
        style: OutlinedButton.styleFrom(
          minimumSize: Size(double.infinity, 56),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      ),
    );
  }

  /// Build error scan button
  Widget _buildErrorScanButton() {
    final theme = Theme.of(context);

    return Container(
      height: 56,
      child: OutlinedButton.icon(
        onPressed: () async => await _startScanning(),
        icon: Icon(Icons.error_outline, color: theme.colorScheme.error),
        label: Text('Scanner Error • Tap to Retry'),
        style: OutlinedButton.styleFrom(
          foregroundColor: theme.colorScheme.error,
          side: BorderSide(color: theme.colorScheme.error),
          minimumSize: Size(double.infinity, 56),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _connectionSubscription?.cancel();
    _animationController.dispose();
    _deviceCleanupTimer?.cancel();
    super.dispose();
  }
}