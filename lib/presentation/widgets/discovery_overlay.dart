import 'dart:async';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:logging/logging.dart';
import '../../core/services/security_manager.dart';
import '../../domain/entities/contact.dart';
import '../../domain/entities/enhanced_contact.dart';
import '../../data/repositories/contact_repository.dart';
import '../../core/utils/string_extensions.dart';
import '../providers/ble_providers.dart';
import '../screens/chat_screen.dart';
import '../controllers/discovery_overlay_controller.dart';
import '../../core/discovery/device_deduplication_manager.dart';
import 'discovery/discovery_header.dart';
import 'discovery/discovery_peripheral_view.dart';
import 'discovery/discovery_scanner_view.dart';
import 'discovery/discovery_types.dart';

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
  late final ProviderSubscription<AsyncValue<DiscoveryOverlayState>> _stateSub;
  late final ProviderSubscription<AsyncValue<List<Peripheral>>> _devicesSub;

  // Device list management
  static const int _maxDevices = 50;

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

    _scaleAnimation = Tween<double>(begin: 0.9, end: 1.0).animate(
      CurvedAnimation(parent: _animationController, curve: Curves.easeOutBack),
    );

    _animationController.forward();
    _stateSub = ref.listenManual<AsyncValue<DiscoveryOverlayState>>(
      discoveryOverlayControllerProvider,
      (previous, next) {
        if (mounted) setState(() {});
      },
    );
    _devicesSub = ref.listenManual<AsyncValue<List<Peripheral>>>(
      discoveredDevicesProvider,
      (previous, next) => next.whenData(_updateLastSeenForDevices),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final devices = ref.read(discoveredDevicesProvider).value;
      if (devices != null) {
        _updateLastSeenForDevices(devices);
      }
    });
    // Prime provider to start initialization.
    ref.read(discoveryOverlayControllerProvider);
  }

  /// Trigger immediate burst scan (manual override)
  Future<void> _startScanning() async {
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

    final controller = ref.read(discoveryOverlayControllerProvider.notifier);
    final deviceId = device.uuid.toString();

    // Mark as connecting
    controller.setAttemptState(deviceId, ConnectionAttemptState.connecting);

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
      final connectionService = ref.read(connectionServiceProvider);
      await connectionService.connectToDevice(device);

      // Wait for identity exchange
      await Future.delayed(Duration(seconds: 2));

      // Mark as connected and verify connection state
      if (connectionService.connectedDevice?.uuid == device.uuid) {
        controller.setAttemptState(deviceId, ConnectionAttemptState.connected);
        await _resolveCurrentConnectionName(device);
        if (mounted) {
          Navigator.pop(context);
          widget.onDeviceSelected(device);
        }
      } else {
        // Connection didn't actually succeed, mark as failed
        controller.setAttemptState(deviceId, ConnectionAttemptState.failed);
        DeviceDeduplicationManager.markRetired(deviceId);
        if (mounted) {
          Navigator.pop(context);
        }
      }
    } catch (e) {
      // Mark as failed
      controller.setAttemptState(deviceId, ConnectionAttemptState.failed);
      DeviceDeduplicationManager.markRetired(deviceId);

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
            'The connection to this device failed. Would you like to retry?',
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

  Future<void> _resolveCurrentConnectionName(Peripheral device) async {
    try {
      final connectionService = ref.read(connectionServiceProvider);
      final persistentKey =
          connectionService.theirPersistentPublicKey ??
          connectionService.theirPersistentKey ??
          connectionService.currentSessionId;
      if (persistentKey == null || persistentKey.isEmpty) return;

      final contactRepo = ContactRepository();
      final contact = await contactRepo.getContactByAnyId(persistentKey);
      final displayName =
          contact?.displayName ??
          connectionService.otherUserName ??
          'User ${persistentKey.shortId(8)}';

      final enhanced = EnhancedContact(
        contact:
            contact ??
            Contact(
              publicKey: persistentKey,
              persistentPublicKey: persistentKey,
              currentEphemeralId: null,
              displayName: displayName,
              trustStatus: TrustStatus.newContact,
              securityLevel: SecurityLevel.low,
              firstSeen: DateTime.now(),
              lastSeen: DateTime.now(),
              lastSecuritySync: null,
              noisePublicKey: null,
              noiseSessionState: null,
              lastHandshakeTime: null,
              isFavorite: false,
            ),
        lastSeenAgo: contact != null
            ? DateTime.now().difference(contact.lastSeen)
            : Duration.zero,
        isRecentlyActive: contact != null
            ? DateTime.now().difference(contact.lastSeen).inHours < 24
            : true,
        interactionCount: 0,
        averageResponseTime: const Duration(minutes: 5),
        groupMemberships: const [],
      );

      DeviceDeduplicationManager.updateResolvedContact(
        device.uuid.toString(),
        enhanced,
      );
    } catch (e, stackTrace) {
      _logger.fine('Failed to resolve connection name: $e');
      _logger.finer(stackTrace.toString());
    }
  }

  // 🔧 MODE SWITCHING REMOVED: Dual mode now runs automatically
  // Previously, manual mode switching was handled via UI tabs.
  // Now BLEService runs both Central and Peripheral modes simultaneously.
  // This overlay is purely a display surface for discovered devices and connection status.
  // Mode transitions are triggered automatically by the underlying BLE architecture.

  void _updateLastSeenForDevices(List<Peripheral> devices) {
    if (!mounted) return;
    final controller = ref.read(discoveryOverlayControllerProvider.notifier);
    for (final device in devices) {
      controller.updateDeviceLastSeen(device.uuid.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    final overlayAsync = ref.watch(discoveryOverlayControllerProvider);
    final overlayState =
        overlayAsync.asData?.value ?? DiscoveryOverlayState.initial();
    final overlayController = ref.read(
      discoveryOverlayControllerProvider.notifier,
    );
    final bleService = ref.watch(connectionServiceProvider);
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
                  color: Colors.black.withValues(
                    alpha: 0.3,
                  ), // 🔧 IMPROVED: Subtle overlay with blur
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
                        maxHeight:
                            MediaQuery.of(context).size.height *
                            0.85, // Increased height
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
                          DiscoveryHeader(
                            showScannerMode: overlayState.showScannerMode,
                            isPeripheralMode: bleService.isPeripheralMode,
                            onToggleMode: () =>
                                overlayController.setShowScannerMode(
                                  !overlayState.showScannerMode,
                                ),
                            onClose: widget.onClose,
                          ),

                          Expanded(
                            child: AnimatedSwitcher(
                              duration: Duration(milliseconds: 300),
                              child: overlayState.showScannerMode
                                  ? DiscoveryScannerView(
                                      devicesAsync: discoveredDevicesAsync,
                                      discoveryDataAsync: discoveryDataAsync,
                                      deduplicatedDevicesAsync:
                                          deduplicatedDevicesAsync,
                                      state: overlayState,
                                      controller: overlayController,
                                      maxDevices: _maxDevices,
                                      logger: _logger,
                                      onStartScanning: _startScanning,
                                      onConnect: _connectToDevice,
                                      onRetry: _showRetryDialog,
                                      onOpenChat: (device) {
                                        widget.onClose();
                                        Navigator.push(
                                          context,
                                          MaterialPageRoute(
                                            builder: (context) =>
                                                ChatScreen(device: device),
                                          ),
                                        );
                                      },
                                      onError: _showError,
                                    )
                                  : DiscoveryPeripheralView(
                                      serverConnections:
                                          bleService.serverConnections,
                                      onOpenChat: (central) {
                                        widget.onClose();
                                        Navigator.push(
                                          context,
                                          MaterialPageRoute(
                                            builder: (context) =>
                                                ChatScreen(central: central),
                                          ),
                                        );
                                      },
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

  @override
  void dispose() {
    _animationController.dispose();
    _stateSub.close();
    _devicesSub.close();
    super.dispose();
  }
}
