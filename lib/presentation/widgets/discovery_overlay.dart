import 'dart:io' show Platform;
import 'dart:async';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:bluetooth_low_energy/bluetooth_low_energy.dart' hide ConnectionState;
import 'package:bluetooth_low_energy/bluetooth_low_energy.dart' as ble;
import 'package:logging/logging.dart';
import '../../data/services/ble_service.dart';
import '../providers/ble_providers.dart';
import '../../data/repositories/contact_repository.dart';
import '../../core/security/hint_cache_manager.dart';
import '../../core/services/hint_advertisement_service.dart';
import '../../core/services/security_manager.dart';
import '../screens/chat_screen.dart';
import '../../core/discovery/device_deduplication_manager.dart';
import '../../data/models/ble_server_connection.dart';

enum ConnectionAttemptState {
  none,       // Never attempted
  connecting, // Currently connecting
  failed,     // Failed - can retry
  connected,  // Successfully connected
}

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
  late AnimationController _animationController;
  late Animation<double> _fadeAnimation;
  late Animation<double> _scaleAnimation;
  StreamSubscription? _connectionSubscription;
  final ContactRepository _contactRepository = ContactRepository();
  Map<String, Contact> _contacts = {};

  // 🆕 Toggle between scanner mode (discovered devices) and peripheral mode (connected centrals)
  bool _showScannerMode = true;

  // Device list management
  static const int _maxDevices = 50;
  Timer? _deviceCleanupTimer;
  final Map<String, DateTime> _deviceLastSeen = {};

  // Connection attempt tracking
  final Map<String, ConnectionAttemptState> _connectionAttempts = {};

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

  /// Get unified scanning state that considers burst scanning
  bool _getUnifiedScanningState() {
    final burstStatusAsync = ref.read(burstScanningStatusProvider);
    final burstStatus = burstStatusAsync.value;
    final isBurstActive = burstStatus?.isBurstActive ?? false;
    return isBurstActive;
  }

  /// Check if manual scan override is allowed (no scanning currently active)
  bool _canTriggerManualScan() {
    final burstStatusAsync = ref.read(burstScanningStatusProvider);
    final burstStatus = burstStatusAsync.value;

    // Prevent manual scan if burst scanning is active
    if (burstStatus?.isBurstActive ?? false) {
      return false;
    }

    // Use burst controller's canOverride logic for additional checks
    return burstStatus?.canOverride ?? true;
  }

  /// Clean up devices not seen recently
  void _cleanupStaleDevices(Timer timer) {
    final now = DateTime.now();
    final staleThreshold = Duration(minutes: 3);

    _deviceLastSeen.removeWhere((deviceId, lastSeen) {
      final isStale = now.difference(lastSeen) > staleThreshold;
      if (isStale) {
        _logger.fine('Removing stale device: $deviceId');
        // Also cleanup connection attempt states for stale devices
        _connectionAttempts.remove(deviceId);
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

  /// Trigger immediate burst scan (manual override)
  Future<void> _startScanning() async {
    if (!_canTriggerManualScan()) {
      return;
    }

    try {
      final burstOperations = ref.read(burstScanningOperationsProvider);
      if (burstOperations != null) {
        _logger.info('🔥 MANUAL: User requested immediate scan');
        await burstOperations.triggerManualScan();
      }
    } catch (e) {
      _logger.warning('Failed to trigger immediate scan: $e');
      _showError('Failed to start scanning');
    }
  }

  Future<void> _connectToDevice(Peripheral device) async {
  // No need to stop scanning - burst scans handle themselves

  if (!mounted) return;

  final deviceId = device.uuid.toString();

  // Mark as connecting
  setState(() {
    _connectionAttempts[deviceId] = ConnectionAttemptState.connecting;
  });

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

    // Mark as connected and verify connection state
    if (bleService.connectedDevice?.uuid == device.uuid) {
      setState(() {
        _connectionAttempts[deviceId] = ConnectionAttemptState.connected;
      });
    } else {
      // Connection didn't actually succeed, mark as failed
      setState(() {
        _connectionAttempts[deviceId] = ConnectionAttemptState.failed;
      });
    }

    if (mounted) {
      Navigator.pop(context);
      setState(() {});
    }

  } catch (e) {
    // Mark as failed
    setState(() {
      _connectionAttempts[deviceId] = ConnectionAttemptState.failed;
    });

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

  void _showRetryDialog(Peripheral device) {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: Text('Connection Failed'),
          content: Text(
            'The connection to this device failed. Would you like to retry?'
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.of(context).pop();
              },
              child: Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                Navigator.of(context).pop();
                _connectToDevice(device);
              },
              child: Text('Retry'),
            ),
          ],
        );
      },
    );
  }

  Widget _buildConnectionStatusBadge(Peripheral device) {
    final bleService = ref.read(bleServiceProvider);
    final deviceId = device.uuid.toString();
    final attemptState = _connectionAttempts[deviceId] ?? ConnectionAttemptState.none;
    final isActuallyConnected = bleService.connectedDevice?.uuid == device.uuid;

    String label;
    Color color;
    IconData icon;

    if (isActuallyConnected) {
      label = 'CONNECTED';
      color = Colors.green;
      icon = Icons.link;
    } else if (attemptState == ConnectionAttemptState.connecting) {
      label = 'CONNECTING';
      color = Colors.orange;
      icon = Icons.sync;
    } else if (attemptState == ConnectionAttemptState.failed) {
      label = 'RETRY';
      color = Colors.red;
      icon = Icons.refresh;
    } else {
      label = 'TAP TO CONNECT';
      color = Colors.blue;
      icon = Icons.bluetooth;
    }

    return Container(
      padding: EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            icon,
            size: 10,
            color: color,
          ),
          SizedBox(width: 2),
          Text(
            label,
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.bold,
              color: color,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTrailingIcon(Peripheral device, int rssi) {
    final bleService = ref.read(bleServiceProvider);
    final deviceId = device.uuid.toString();
    final attemptState = _connectionAttempts[deviceId] ?? ConnectionAttemptState.none;
    final isActuallyConnected = bleService.connectedDevice?.uuid == device.uuid;

    if (attemptState == ConnectionAttemptState.connecting) {
      return SizedBox(
        width: 20,
        height: 20,
        child: CircularProgressIndicator(
          strokeWidth: 2,
          valueColor: AlwaysStoppedAnimation(Colors.orange),
        ),
      );
    } else if (isActuallyConnected) {
      return Icon(Icons.chat, color: Colors.green);
    } else if (attemptState == ConnectionAttemptState.failed) {
      return Icon(Icons.refresh, color: Colors.red);
    } else {
      // Show signal strength indicator for discovered devices
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildSignalStrengthBars(rssi),
          SizedBox(width: 8),
          Icon(Icons.chevron_right, color: Colors.grey),
        ],
      );
    }
  }

  /// Build signal strength bars (like cellular signal)
  Widget _buildSignalStrengthBars(int rssi) {
    final strength = _getSignalStrengthLevel(rssi);
    final color = _getSignalStrengthColor(rssi);

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: List.generate(4, (index) {
        final isActive = index < strength;
        final barHeight = 4.0 + (index * 3.0); // Increasing height

        return Container(
          width: 3,
          height: barHeight,
          margin: EdgeInsets.only(left: index > 0 ? 2 : 0),
          decoration: BoxDecoration(
            color: isActive ? color : Colors.grey.withValues(alpha: 0.3),
            borderRadius: BorderRadius.circular(1),
          ),
        );
      }),
    );
  }

  /// Get signal strength level (0-4 bars)
  int _getSignalStrengthLevel(int rssi) {
    if (rssi >= -50) return 4; // Excellent
    if (rssi >= -60) return 3; // Good
    if (rssi >= -70) return 2; // Fair
    if (rssi >= -80) return 1; // Poor
    return 0; // Very Poor
  }

  /// Get color for signal strength
  Color _getSignalStrengthColor(int rssi) {
    if (rssi >= -50) return Colors.green;      // Excellent
    if (rssi >= -60) return Colors.lightGreen; // Good
    if (rssi >= -70) return Colors.orange;     // Fair
    if (rssi >= -80) return Colors.deepOrange; // Poor
    return Colors.red;                         // Very Poor
  }

  // 🔧 MODE SWITCHING REMOVED: Dual mode now runs automatically
  // Previously, manual mode switching was handled via UI tabs.
  // Now BLEService runs both Central and Peripheral modes simultaneously.
  // This overlay is purely a display surface for discovered devices and connection status.
  // Mode transitions are triggered automatically by the underlying BLE architecture.

  @override
Widget build(BuildContext context) {
  final bleService = ref.watch(bleServiceProvider);
  final discoveredDevicesAsync = ref.watch(discoveredDevicesProvider);
  final discoveryDataAsync = ref.watch(discoveryDataProvider);
  final deduplicatedDevicesAsync = ref.watch(deduplicatedDevicesProvider);

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
                      // Mode banner removed (redundant)

                      Expanded(
                        child: AnimatedSwitcher(
                          duration: Duration(milliseconds: 300),
                          // 🆕 Toggle between scanner mode (discovered devices) and peripheral mode (connected centrals)
                          child: _showScannerMode
                            ? _buildScannerMode(
                                discoveredDevicesAsync,
                                discoveryDataAsync,
                                deduplicatedDevicesAsync
                              )
                            : _buildPeripheralMode(bleService),
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
                  _showScannerMode ? 'Discovered Devices' : 'Connected Centrals',
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                ),

              ],
            ),
          ),
          // 🆕 Toggle button to switch between scanner and peripheral views
          IconButton(
            onPressed: () {
              setState(() {
                _showScannerMode = !_showScannerMode;
              });
            },
            icon: Icon(_showScannerMode ? Icons.swap_horiz : Icons.swap_horiz),
            tooltip: _showScannerMode ? 'Show connected centrals' : 'Show discovered devices',
            style: IconButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
            ),
          ),
          SizedBox(width: 8),
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



  /// 🆕 ENHANCEMENT 2: Connection slot indicator
  Widget _buildConnectionSlotIndicator() {
    final bleService = ref.watch(bleServiceProvider);
    final connectionManager = bleService.connectionManager;

    final currentConnections = connectionManager.clientConnectionCount;
    final maxConnections = connectionManager.maxClientConnections;
    final availableSlots = maxConnections - currentConnections;

    // 🔗 Log connection slot status for debugging
    _logger.fine('🔗 CONNECTION SLOTS: $currentConnections/$maxConnections (available: $availableSlots)');

    // Color based on availability
    Color indicatorColor;
    if (availableSlots == 0) {
      indicatorColor = Colors.red;
      _logger.warning('⚠️ CONNECTION SLOTS: FULL - No slots available!');
    } else if (availableSlots <= 2) {
      indicatorColor = Colors.orange;
      _logger.info('⚠️ CONNECTION SLOTS: LOW - Only $availableSlots slots remaining');
    } else {
      indicatorColor = Colors.green;
      _logger.fine('✅ CONNECTION SLOTS: OK - $availableSlots slots available');
    }

    return Container(
      padding: EdgeInsets.symmetric(horizontal: 12, vertical: 6),
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
          Icon(
            Icons.link,
            size: 16,
            color: indicatorColor,
          ),
          SizedBox(width: 6),
          Text(
            '$currentConnections/$maxConnections connections',
            style: TextStyle(
              fontSize: 12,
              color: indicatorColor,
              fontWeight: FontWeight.w600,
            ),
          ),
          if (availableSlots > 0) ...[
            SizedBox(width: 4),
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

Widget _buildScannerMode(
    AsyncValue<List<Peripheral>> devicesAsync,
    AsyncValue<Map<String, DiscoveredEventArgs>> discoveryDataAsync,
    AsyncValue<Map<String, DiscoveredDevice>> deduplicatedDevicesAsync,
  ) {
    return Column(
    children: [
      // 🔧 MINIMALIST: Scanning circle with countdown instead of cluttered button
      _buildMinimalistScanningCircle(),

      SizedBox(height: 8),

      // 🆕 ENHANCEMENT 2: Connection slot indicator
      _buildConnectionSlotIndicator(),

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
              final deduplicatedDevices = deduplicatedDevicesAsync.value ?? {};

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

              // 🆕 Categorize devices using deduplicated device data with contact recognition
              final newDevices = <Peripheral>[];
              final knownDevices = <Peripheral>[];

              for (final device in freshDevices) {
                final deviceId = device.uuid.toString();
                final deduplicatedDevice = deduplicatedDevices[deviceId];

                // ✅ Use isKnownContact flag from device deduplication manager
                if (deduplicatedDevice != null && deduplicatedDevice.isKnownContact) {
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

                  // Hint text for manual scanning (only show when not scanning)
                  if (totalShown > 0 && !_getUnifiedScanningState())
                    Padding(
                      padding: EdgeInsets.all(16),
                      child: Text(
                        'Tap the timer circle above to scan for more devices',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                          fontStyle: FontStyle.italic,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ),

                  // Bottom padding for better scroll experience
                  SizedBox(height: 80),
                ],
              );
            },
            loading: () => _buildBurstAwareLoadingState(),
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
    Contact? matchedContact;

    // Try to resolve name from ephemeral hints in advertisement data
    if (advertisement != null && advertisement.advertisement.manufacturerSpecificData.isNotEmpty) {
      deviceName = _resolveDeviceNameFromHints(advertisement);
      isContactResolved = deviceName != 'Unknown Device';

      // Try to find matching contact for pairing status
      if (isContactResolved) {
        matchedContact = _contacts.values.where((contact) =>
          contact.displayName == deviceName
        ).firstOrNull;
      }
    }

    // Fallback to contact system if hints didn't work
    if (!isContactResolved && isKnown) {
      matchedContact = _contacts.values.where((contact) =>
        contact.publicKey.contains(device.uuid.toString())
      ).firstOrNull;

      if (matchedContact != null) {
        deviceName = matchedContact.displayName;
        isContactResolved = true;
      }
    }

    // Final fallback to UUID
    if (!isContactResolved) {
      deviceName = 'Device ${device.uuid.toString().substring(0, 8)}';
    }

    final rssi = advertisement?.rssi ?? -100;
    final signalStrength = _getSignalStrength(rssi);

    // Determine pairing/contact status
    final isPaired = matchedContact != null;
    final isVerified = matchedContact?.trustStatus == TrustStatus.verified;
    final securityLevel = matchedContact?.securityLevel ?? SecurityLevel.low;

    // Role badges: determine if connected as central and/or peripheral
    final bleService = ref.read(bleServiceProvider);
    final isConnectedAsCentral = bleService.connectedDevice?.uuid == device.uuid;
    final isConnectedAsPeripheral = bleService.connectedCentral?.uuid.toString() == device.uuid.toString();

    return Container(
      margin: EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Card(
        elevation: isContactResolved ? 2 : 1,
        child: ListTile(
          leading: Stack(
            children: [
              CircleAvatar(
                backgroundColor: isContactResolved
                  ? (isVerified
                      ? Colors.green.withValues(alpha: 0.2)
                      : Theme.of(context).colorScheme.primary.withValues(alpha: 0.2))
                  : Theme.of(context).colorScheme.surfaceContainerHighest,
                child: Icon(
                  isContactResolved
                    ? (isVerified ? Icons.verified_user : Icons.person)
                    : Icons.bluetooth,
                  color: isContactResolved
                    ? (isVerified ? Colors.green : Theme.of(context).colorScheme.primary)
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
                      color: isVerified ? Colors.green : Colors.blue,
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
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Signal strength row
              Row(
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
                ],
              ),
              // Status badges row
              if (isContactResolved || isPaired) ...[
                SizedBox(height: 4),
                Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: [
                    if (isContactResolved)
                      Container(
                        padding: EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.15),
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
                    if (isPaired)
                      Container(
                        padding: EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: _getSecurityColor(securityLevel).withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              _getSecurityIcon(securityLevel),
                              size: 10,
                              color: _getSecurityColor(securityLevel),
                            ),
                            SizedBox(width: 2),
                            Text(
                              _getSecurityLabel(securityLevel),
                              style: TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.bold,
                                color: _getSecurityColor(securityLevel),
                              ),
                            ),
                          ],
                        ),
                      ),
                    if (isVerified)
                      Container(
                        padding: EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: Colors.green.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.verified,
                              size: 10,
                              color: Colors.green,
                            ),
                            SizedBox(width: 2),
                            Text(
                              'VERIFIED',
                              style: TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.bold,
                                color: Colors.green,
                              ),
                            ),
                          ],
                        ),
                      ),
                    // Role badge(s)
                    if (isConnectedAsCentral && isConnectedAsPeripheral)
                      Container(
                        padding: EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: Colors.purple.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          'BOTH ROLES',
                          style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Colors.purple),
                        ),
                      )
                    else if (isConnectedAsCentral)
                      Container(
                        padding: EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: Colors.blue.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          'CENTRAL',
                          style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Colors.blue),
                        ),
                      )
                    else if (isConnectedAsPeripheral)
                      Container(
                        padding: EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: Colors.amber.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          'PERIPHERAL',
                          style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Colors.amber),
                        ),
                      ),
                    // Connection status badge
                    _buildConnectionStatusBadge(device),
                  ],
                ),
              ],
              // Always show connection status and role badges for clarity
              if (!isContactResolved && !isPaired) ...[
                SizedBox(height: 4),
                Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: [
                    if (isConnectedAsCentral && isConnectedAsPeripheral)
                      Container(
                        padding: EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: Colors.purple.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          'BOTH ROLES',
                          style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Colors.purple),
                        ),
                      )
                    else if (isConnectedAsCentral)
                      Container(
                        padding: EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: Colors.blue.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          'CENTRAL',
                          style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Colors.blue),
                        ),
                      )
                    else if (isConnectedAsPeripheral)
                      Container(
                        padding: EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: Colors.amber.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          'PERIPHERAL',
                          style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Colors.amber),
                        ),
                      ),
                    _buildConnectionStatusBadge(device),
                  ],
                ),
              ],
            ],
          ),
          trailing: _buildTrailingIcon(device, rssi),
onTap: () {
  final bleService = ref.read(bleServiceProvider);
  final deviceId = device.uuid.toString();
  final attemptState = _connectionAttempts[deviceId] ?? ConnectionAttemptState.none;

  // Check actual BLE connection status first (either role)
  final isConnectedAsCentral = bleService.connectedDevice?.uuid == device.uuid;
  final isConnectedAsPeripheral = bleService.connectedCentral?.uuid.toString() == device.uuid.toString();
  final isActuallyConnected = isConnectedAsCentral || isConnectedAsPeripheral;

  if (isActuallyConnected) {
    // Already connected - open chat
    widget.onClose();
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => ChatScreen(device: device),
      ),
    );
  } else if (attemptState == ConnectionAttemptState.connecting) {
    // Currently connecting - show message and ignore tap
    _showError('Connection in progress, please wait...');
  } else if (attemptState == ConnectionAttemptState.failed) {
    // Failed previously - offer retry
    _showRetryDialog(device);
  } else {
    // First attempt or no previous state - connect
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
      for (final manufacturerData in advertisement.advertisement.manufacturerSpecificData) {
        if (manufacturerData.id != 0x2E19) continue;
        final parsed = HintAdvertisementService.parseAdvertisement(manufacturerData.data);
        if (parsed == null || parsed.isIntro) {
          continue;
        }
        final contactHint = HintCacheManager.matchBlindedHintSync(
          nonce: parsed.nonce,
          hintBytes: parsed.hintBytes,
        );
        if (contactHint != null) {
          final name = contactHint.contact.contact.displayName;
          if (name.isNotEmpty) {
            _logger.fine('✅ Resolved device name from hint: $name');
            return name;
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

  /// Get security level icon
  IconData _getSecurityIcon(SecurityLevel level) {
    switch (level) {
      case SecurityLevel.high:
        return Icons.verified_user;
      case SecurityLevel.medium:
        return Icons.lock;
      case SecurityLevel.low:
        return Icons.lock_open;
    }
  }

  /// Get security level color
  Color _getSecurityColor(SecurityLevel level) {
    switch (level) {
      case SecurityLevel.high:
        return Colors.green;
      case SecurityLevel.medium:
        return Colors.blue;
      case SecurityLevel.low:
        return Colors.orange;
    }
  }

  /// Get security level label
  String _getSecurityLabel(SecurityLevel level) {
    switch (level) {
      case SecurityLevel.high:
        return 'ECDH';
      case SecurityLevel.medium:
        return 'PAIRED';
      case SecurityLevel.low:
        return 'BASIC';
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
          SizedBox(height: 16),
          // Only show hint when not scanning
          if (!_getUnifiedScanningState())
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

  /// 🆕 Build peripheral mode view - shows devices connected TO us (we're the peripheral)
  Widget _buildPeripheralMode(BLEService bleService) {
    final serverConnections = bleService.connectionManager.serverConnections;

    return Column(
      children: [
        // Header info
        Container(
          margin: EdgeInsets.all(16),
          padding: EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            children: [
              Icon(Icons.wifi_tethering, color: Theme.of(context).colorScheme.primary),
              SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Peripheral Mode',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    Text(
                      '${serverConnections.length} device(s) connected to you',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),

        Divider(),

        // Connected centrals list
        Expanded(
          child: serverConnections.isEmpty
            ? Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.wifi_tethering, size: 64, color: Colors.grey),
                    SizedBox(height: 16),
                    Text(
                      'No devices connected',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    SizedBox(height: 8),
                    Text(
                      'Waiting for others to discover you...',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Colors.grey,
                      ),
                    ),
                  ],
                ),
              )
            : ListView.builder(
                itemCount: serverConnections.length,
                itemBuilder: (context, index) {
                  final connection = serverConnections[index];
                  return _buildServerConnectionItem(connection);
                },
              ),
        ),
      ],
    );
  }

  /// Build a single server connection item (central connected to us)
  Widget _buildServerConnectionItem(BLEServerConnection connection) {
    final duration = connection.connectedDuration;
    final durationText = duration.inMinutes > 0
      ? '${duration.inMinutes}m ${duration.inSeconds % 60}s'
      : '${duration.inSeconds}s';

    return ListTile(
      leading: Container(
        padding: EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: Colors.green.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Icon(Icons.phone_android, color: Colors.green),
      ),
      title: Text(
        connection.address.substring(0, 17), // Show MAC address
        style: TextStyle(fontWeight: FontWeight.bold),
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Connected for: $durationText'),
          if (connection.mtu != null)
            Text('MTU: ${connection.mtu} bytes'),
          Text(
            connection.isSubscribed ? 'Subscribed to notifications' : 'Not subscribed',
            style: TextStyle(
              color: connection.isSubscribed ? Colors.green : Colors.orange,
              fontSize: 12,
            ),
          ),
        ],
      ),
      trailing: Icon(Icons.chat_bubble_outline, color: Theme.of(context).colorScheme.primary),
      onTap: () {
        // Allow opening chat when we're peripheral by passing the Central
        widget.onClose();
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => ChatScreen(central: connection.central),
          ),
        );
      },
    );
  }

  /// Build clean loading state that works with countdown timer (no redundancy)
  Widget _buildBurstAwareLoadingState() {
    return Consumer(
      builder: (context, ref, child) {
        final burstStatusAsync = ref.watch(burstScanningStatusProvider);

        return burstStatusAsync.when(
          data: (burstStatus) {
            // Simple status - let the countdown timer handle timing details
            final isActuallyScanning = burstStatus.isBurstActive;
            final statusText = isActuallyScanning
              ? 'Searching for devices...'
              : 'Waiting scan - Tap timer for manual scan';

            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  // Only show progress indicator if actually scanning
                  if (isActuallyScanning) ...[
                    CircularProgressIndicator(),
                    SizedBox(height: 16),
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
              children: [
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
      },
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

  /// Build unified clickable timer circle - RED when scanning, BLUE when waiting
  Widget _buildScanningCircleWithStatus(dynamic burstStatus, dynamic operations) {
    final theme = Theme.of(context);
    final isScanning = burstStatus.isBurstActive;

    // Color scheme: RED for scanning, BLUE for waiting
    final primaryColor = isScanning ? Colors.red : Colors.blue;
    final backgroundColor = isScanning
      ? Colors.red.withValues(alpha: 0.1)
      : theme.colorScheme.surfaceContainerHighest;

    // Calculate progress and display values
    double? progress;
    int? displayNumber;
    String? displayLabel;

    if (isScanning) {
      // RED MODE: Show burst scan countdown
      if (burstStatus.burstTimeRemaining != null) {
        // Burst scan - show remaining time (20 second duration)
        final remaining = burstStatus.burstTimeRemaining!;
        final totalDuration = 20; // Burst scans last 20 seconds
        final elapsed = totalDuration - remaining;
        progress = elapsed / totalDuration;
        displayNumber = remaining;
        displayLabel = 'sec';
      } else {
        // Scanning without duration info - just show spinner
        displayNumber = null;
        displayLabel = null;
      }
    } else {
      // BLUE MODE: Show countdown to next scan
      if (burstStatus.secondsUntilNextScan != null && burstStatus.secondsUntilNextScan! > 0) {
        final totalSeconds = (burstStatus.currentScanInterval / 1000).round();
        final remaining = burstStatus.secondsUntilNextScan!;
        progress = (totalSeconds - remaining) / totalSeconds;
        displayNumber = remaining;
        displayLabel = 'sec';
      }
      // else: Ready to scan (BLUE icon, no timer)
    }

    return GestureDetector(
      onTap: () async {
        if (!isScanning) {
          // Click during waiting = trigger immediate burst scan
          if (_canTriggerManualScan()) {
            await _startScanning();
          }
        }
      },
      child: SizedBox(
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
                color: backgroundColor,
                border: Border.all(
                  color: primaryColor,
                  width: 2,
                ),
              ),
            ),

            // Progress circle (both scanning and waiting)
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

            // Center content
            if (displayNumber != null && displayLabel != null)
              // Show countdown number
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
              // Scanning without duration - show spinner
              SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                  strokeWidth: 2.5,
                  valueColor: AlwaysStoppedAnimation(primaryColor),
                ),
              )
            else
              // Ready to scan - show icon
              Icon(
                Icons.bluetooth_searching,
                size: 28,
                color: primaryColor,
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


  @override
  void dispose() {
    _connectionSubscription?.cancel();
    _animationController.dispose();
    _deviceCleanupTimer?.cancel();
    super.dispose();
  }
}
