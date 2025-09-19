import 'dart:async';
import 'dart:io' show Platform;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:bluetooth_low_energy/bluetooth_low_energy.dart' hide ConnectionState;
import 'package:bluetooth_low_energy/bluetooth_low_energy.dart' as ble;
import '../providers/ble_providers.dart';
import '../../data/repositories/chats_repository.dart';
import '../../data/repositories/user_preferences.dart';
import '../../domain/entities/chat_list_item.dart';
import '../../core/models/connection_status.dart'; 
import '../../data/services/ble_service.dart';
import '../widgets/discovery_overlay.dart';
import 'chat_screen.dart';
import 'qr_contact_screen.dart';
import '../../core/models/connection_info.dart';
import '../../core/discovery/device_deduplication_manager.dart';

class ChatsScreen extends ConsumerStatefulWidget {
  const ChatsScreen({super.key});

  @override
  ConsumerState<ChatsScreen> createState() => _ChatsScreenState();
}

class _ChatsScreenState extends ConsumerState<ChatsScreen> {
  final ChatsRepository _chatsRepository = ChatsRepository();
  final TextEditingController _searchController = TextEditingController();
  
  List<ChatListItem> _chats = [];
  bool _isLoading = true;
  String _searchQuery = '';
  Timer? _refreshTimer;
  Timer? _searchDebounceTimer;
  bool _showDiscoveryOverlay = false;
  StreamSubscription? _peripheralConnectionSubscription;

  @override
  void initState() {
    super.initState();
    _loadChats();
    _setupPeriodicRefresh();
    _setupPeripheralConnectionListener();
  }


void _loadChats() async {
  if (!mounted) return;
  setState(() => _isLoading = true);
  
  final nearbyDevices = await _getNearbyDevices();
  
  // Get discovery data with advertisements
  final discoveryDataAsync = ref.read(discoveryDataProvider);
  final discoveryData = discoveryDataAsync.maybeWhen(
    data: (data) => data,
    orElse: () => <String, DiscoveredEventArgs>{},
  );
  
  final chats = await _chatsRepository.getAllChats(
    nearbyDevices: nearbyDevices,
    discoveryData: discoveryData,
    searchQuery: _searchQuery.isEmpty ? null : _searchQuery,
  );
  
  if (!mounted) return;
  setState(() {
    _chats = chats;
    _isLoading = false;
  });
}

  Future<List<Peripheral>?> _getNearbyDevices() async {
    final devicesAsync = ref.read(discoveredDevicesProvider);
    return devicesAsync.maybeWhen(
      data: (devices) => devices,
      orElse: () => null,
    );
  }

void _setupPeriodicRefresh() {
  _refreshTimer = Timer.periodic(Duration(seconds: 10), (_) {
    if (mounted && !_isLoading) {
      _loadChats();
    }
  });
}

  @override
Widget build(BuildContext context) {
  final bleStateAsync = ref.watch(bleStateProvider);
  ref.watch(connectionInfoProvider);
  ref.watch(discoveredDevicesProvider);
  
  return Stack(
    children: [
      // Main scaffold
      Scaffold(
        appBar: AppBar(
          title: Text('Chats'),
          leading: GestureDetector(
            onTap: () => _showSettings(),
            child: Padding(
              padding: EdgeInsets.all(8.0),
              child: CircleAvatar(
                backgroundColor: Theme.of(context).colorScheme.primary,
                child: Icon(Icons.person, color: Colors.white),
              ),
            ),
          ),
          actions: [
            IconButton(
              onPressed: () => _showSearch(),
              icon: Icon(Icons.search),
            ),
          ],
        ),
        body: Column(
          children: [
            _buildBLEStatusBanner(bleStateAsync),
            if (_searchQuery.isNotEmpty) _buildSearchBar(),
            
            Expanded(
              child: _isLoading 
                ? Center(child: CircularProgressIndicator())
                : _chats.isEmpty 
                  ? _buildEmptyState()
                  : RefreshIndicator(
                      onRefresh: () async => _loadChats(),
                      child: ListView.builder(
                        itemCount: _chats.length,
                        itemBuilder: (context, index) => _buildChatTile(_chats[index]),
                      ),
                    ),
            ),
          ],
        ),
        floatingActionButton: _buildSpeedDial(),
      ),
      
      if (_showDiscoveryOverlay)
  Positioned.fill(
    child: PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) {
          setState(() => _showDiscoveryOverlay = false);
        }
      },
      child: DiscoveryOverlay(
        onClose: () => setState(() => _showDiscoveryOverlay = false),
        onDeviceSelected: _onDeviceSelected,
      ),
    ),
  ),
    ],
  );
}

Widget _buildSpeedDial() {
  return FloatingActionButton(
    onPressed: _showAddOptions,
    tooltip: 'Add contact or discover',
    child: Icon(Icons.add),
  );
}


  Widget _buildChatTile(ChatListItem chat) {
  // Get live connection status
  final connectionInfo = ref.watch(connectionInfoProvider).value;
  final bleService = ref.read(bleServiceProvider);
  final discoveredDevices = ref.watch(discoveredDevicesProvider).value ?? [];
  final discoveryData = ref.watch(discoveryDataProvider).value ?? {};
  
  ConnectionStatus connectionStatus = _determineConnectionStatus(
    chat, 
    connectionInfo, 
    bleService, 
    discoveredDevices, 
    discoveryData
  );
  
  // Determine real-time status
  if (connectionInfo != null && 
      connectionInfo.isConnected && 
      connectionInfo.otherUserName == chat.contactName) {
    connectionStatus = ConnectionStatus.connected;
  }
  else if (discoveredDevices.any((device) => 
    chat.contactPublicKey?.contains(device.uuid.toString()) ?? false)) {
    connectionStatus = ConnectionStatus.nearby;
  }
  else if (chat.isOnline) {
    connectionStatus = ConnectionStatus.nearby;
  }
  else {
    connectionStatus = ConnectionStatus.offline;
  }
  
  // Now use connectionStatus in the UI
  return Card(
    margin: EdgeInsets.symmetric(horizontal: 12, vertical: 4),
    child: ListTile(
      leading: Stack(
        children: [
          CircleAvatar(
            backgroundColor: connectionStatus.color.withValues(),
            child: Icon(
              Icons.person,
              color: connectionStatus.color,
            ),
          ),
          Positioned(
            right: 0,
            bottom: 0,
            child: Container(
              width: 12,
              height: 12,
              decoration: BoxDecoration(
                color: connectionStatus.color,
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white, width: 2),
              ),
            ),
          ),
        ],
      ),
      title: Row(
        children: [
          Expanded(
            child: Text(
              chat.contactName,
              style: TextStyle(
                fontWeight: chat.unreadCount > 0 ? FontWeight.bold : FontWeight.normal,
              ),
            ),
          ),
          Container(
            padding: EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: connectionStatus.color.withValues(),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  connectionStatus.icon,
                  size: 8,
                  color: connectionStatus.color,
                ),
                SizedBox(width: 4),
                Text(
                  connectionStatus.label,
                  style: TextStyle(
                    fontSize: 10,
                    color: connectionStatus.color,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (chat.lastMessage != null)
            Text(
              chat.lastMessage!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontWeight: chat.unreadCount > 0 ? FontWeight.w500 : FontWeight.normal,
              ),
            ),
          if (chat.hasUnsentMessages)
            Row(
              children: [
                Icon(Icons.error_outline, size: 12, color: Colors.red),
                SizedBox(width: 4),
                Text(
                  'Message failed to send',
                  style: TextStyle(fontSize: 11, color: Colors.red),
                ),
              ],
            ),
        ],
      ),
      trailing: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (chat.lastMessageTime != null)
            Text(
              _formatTime(chat.lastMessageTime!),
              style: TextStyle(fontSize: 12),
            ),
          if (chat.unreadCount > 0)
            Container(
              margin: EdgeInsets.only(top: 4),
              padding: EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.primary,
                shape: BoxShape.circle,
              ),
              child: Text(
                '${chat.unreadCount}',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 10,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
        ],
      ),
      onTap: () => _openChat(chat),
    ),
  );
}

Widget _buildEmptyState() {
  final devicesAsync = ref.watch(discoveredDevicesProvider);
  final hasNearbyDevices = devicesAsync.maybeWhen(
    data: (devices) => devices.isNotEmpty,
    orElse: () => false,
  );
  
  return Center(
    child: Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(
          Icons.chat_bubble_outline,
          size: 64,
          color: Theme.of(context).colorScheme.onSurfaceVariant.withValues(),
        ),
        SizedBox(height: 16),
        Text(
          hasNearbyDevices 
            ? 'Connect to a nearby device to start chatting'
            : 'No conversations yet',
          style: Theme.of(context).textTheme.titleLarge,
        ),
        SizedBox(height: 24),
        FilledButton.icon(
          onPressed: () => setState(() => _showDiscoveryOverlay = true),
          icon: Icon(Icons.bluetooth_searching),
          label: Text('Discover Devices'),
        ),
      ],
    ),
  );
}

  Widget _buildBLEStatusBanner(AsyncValue<BluetoothLowEnergyState> bleStateAsync) {
    return bleStateAsync.when(
      data: (state) {
        if (state != BluetoothLowEnergyState.poweredOn) {
          return Container(
            padding: EdgeInsets.all(12),
            color: Theme.of(context).colorScheme.errorContainer,
            child: Row(
              children: [
                Icon(Icons.bluetooth_disabled),
                SizedBox(width: 8),
                Text('Bluetooth ${state.name} - Allow Permission!'),
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

  Widget _buildSearchBar() {
    return Container(
      padding: EdgeInsets.all(12),
      child: TextField(
        controller: _searchController,
        decoration: InputDecoration(
          hintText: 'Search chats...',
          prefixIcon: Icon(Icons.search),
          suffixIcon: IconButton(
            onPressed: _clearSearch,
            icon: Icon(Icons.clear),
          ),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(25)),
        ),
onChanged: (query) {
  setState(() => _searchQuery = query);
  
  // Debounce search to prevent excessive calls
  _searchDebounceTimer?.cancel();
  _searchDebounceTimer = Timer(Duration(milliseconds: 300), () {
    if (mounted) _loadChats();
  });
},
      ),
    );
  }

ConnectionStatus _determineConnectionStatus(
  ChatListItem chat,
  ConnectionInfo? connectionInfo,
  BLEService bleService,
  List<Peripheral> discoveredDevices,
  Map<String, DiscoveredEventArgs> discoveryData,
) {
  // Check if this is the currently connected device
  if (connectionInfo != null && 
      connectionInfo.isConnected && 
      connectionInfo.isReady &&
      connectionInfo.otherUserName == chat.contactName) {
    return ConnectionStatus.connected;
  }
  
  // Check if currently connecting to this device
  if (connectionInfo != null && 
      connectionInfo.isConnected && 
      !connectionInfo.isReady &&
      bleService.otherDevicePersistentId == chat.contactPublicKey) {
    return ConnectionStatus.connecting;
  }
  
  // Check if device is nearby (discovered via BLE scan)
  if (chat.contactPublicKey != null) {
    // Method 1: Check via manufacturer data hash
    final isOnlineViaHash = _isContactOnlineViaHash(chat.contactPublicKey!, discoveryData.cast<String, DiscoveredDevice>());
    if (isOnlineViaHash) {
      return ConnectionStatus.nearby;
    }
    
    // Method 2: Check via device UUID mapping (fallback)
    final isNearbyViaUUID = discoveredDevices.any((device) => 
      chat.contactPublicKey!.contains(device.uuid.toString())
    );
    if (isNearbyViaUUID) {
      return ConnectionStatus.nearby;
    }
  }
  
  // Check if recently seen (within last 5 minutes)
  if (chat.lastSeen != null) {
    final timeSinceLastSeen = DateTime.now().difference(chat.lastSeen!);
    if (timeSinceLastSeen.inMinutes <= 5) {
      return ConnectionStatus.recent;
    }
  }
  
  return ConnectionStatus.offline;
}

bool _isContactOnlineViaHash(String contactPublicKey, Map<String, DiscoveredDevice> discoveryData) {
  if (discoveryData.isEmpty) return false;
  
  for (final device in discoveryData.values) {
    if (device.isKnownContact && 
        device.contactInfo?.publicKey == contactPublicKey) {
      return true;
    }
  }
  
  return false;
}

void _setupPeripheralConnectionListener() {
    if (!Platform.isAndroid) return;
    
    final bleService = ref.read(bleServiceProvider);
    
    _peripheralConnectionSubscription = bleService.peripheralManager.connectionStateChanged
      .distinct((prev, next) => 
        prev.central.uuid == next.central.uuid && prev.state == next.state)
      .where((event) => 
        bleService.isPeripheralMode && 
        event.state == ble.ConnectionState.connected)
      .listen((event) {
        _handleIncomingPeripheralConnection(event.central);
      });

  bleService.connectionInfo.listen((info) {
    if (mounted) {
      setState(() {});
    }
  });
  }
    
  void _handleIncomingPeripheralConnection(Central central) {
    if (!mounted) return;
    
    _loadChats();
  }

void _showAddOptions() {
    showModalBottomSheet(
      context: context,
      builder: (context) => Container(
        padding: EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Icon(Icons.bluetooth_searching),
              title: Text('Discover Nearby Devices'),
              subtitle: Text('Connect via Bluetooth'),
              onTap: () {
                Navigator.pop(context);
                setState(() => _showDiscoveryOverlay = true);
              },
            ),
            ListTile(
              leading: Icon(Icons.qr_code_scanner),
              title: Text('Add Contact via QR'),
              subtitle: Text('Exchange QR codes for secure contact'),
              onTap: () {
                Navigator.pop(context);
                _navigateToQRExchange();
              },
            ),
          ],
        ),
      ),
    );
  }

void _onDeviceSelected(Peripheral device) async {
  setState(() => _showDiscoveryOverlay = false);
  
  // Show a snackbar for connection progress
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Row(
        children: [
          SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              valueColor: AlwaysStoppedAnimation(Colors.white),
            ),
          ),
          SizedBox(width: 12),
          Text('Connecting to ${device.uuid.toString().substring(0, 8)}...'),
        ],
      ),
      duration: Duration(seconds: 3),
    ),
  );
  
  // The connection will be handled by the BLE service
  // The chat list will automatically update to show connection status
  // User can tap the chat when they see it's connected
  
  // Refresh the chat list after a short delay
  Future.delayed(Duration(seconds: 2), () {
    if (mounted) {
      _loadChats();
    }
  });
}

void _navigateToQRExchange() async {
  final result = await Navigator.push(
    context,
    MaterialPageRoute(builder: (context) => QRContactScreen()),
  );
  
  if (result == true) {
    _loadChats(); // Refresh to show new contact
  }
}

void _openChat(ChatListItem chat) async {
  if (!mounted) return;
  
  await _chatsRepository.markChatAsRead(chat.chatId);
  
  if (!mounted) return;
  
  Navigator.push(
    context,
    MaterialPageRoute(
      builder: (context) => ChatScreen.fromChatData(
        chatId: chat.chatId,
        contactName: chat.contactName,
        contactPublicKey: chat.contactPublicKey ?? '',
      ),
    ),
  ).then((_) {
    if (mounted) _loadChats();
  });
}

  void _showSearch() {
    setState(() {
      if (_searchQuery.isEmpty) {
        _searchQuery = ' '; // Show search bar
      } else {
        _clearSearch();
      }
    });
  }

  void _clearSearch() {
    _searchController.clear();
    setState(() => _searchQuery = '');
    _loadChats();
  }

void _showPairingGuide() {
  showDialog(
    context: context,
    builder: (context) => AlertDialog(
      title: Row(
        children: [
          Icon(Icons.help_outline, color: Theme.of(context).colorScheme.primary),
          SizedBox(width: 12),
          Text('How to....'),
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
              'Start Connection',
              'Scanner device will find the Discoverable device. Tap to connect.',
            ),
            _buildGuideStep(
              context,
              '3',
              'Begin Chatting',
              'Once connected, you can send messages with automatic encryption.',
            ),
            _buildGuideStep(
              context,
              '4',
              'Enhanced Security',
              'For better security, use pairing, or for the best, add contacts to get ECDH.',
            ),
          ],
        ),
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.pop(context),
          child: Text('Got it!'),
        ),
      ],
    ),
  );
}

Widget _buildGuideStep(BuildContext context, String step, String title, String description) {
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
              step,
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
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
              SizedBox(height: 4),
              Text(
                description,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ],
    ),
  );
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
      Text('• Three-tier security system'),
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

 void _showSettings() {
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
            title: Text('Your Name'),
            subtitle: Text('How others see you'),
            onTap: () {
              Navigator.pop(context);
              _editDisplayName();
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

void _editDisplayName() async {
  // Get the username first
  final currentName = await UserPreferences().getUserName();
  
  // Check mounted after async
  if (!mounted) return;
  
  final controller = TextEditingController(text: currentName);
  
  // Now it's safe to use context
  showDialog(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text('Edit Display Name'),
      content: TextField(
        controller: controller,
        decoration: InputDecoration(
          labelText: 'Your name',
          border: OutlineInputBorder(),
        ),
        autofocus: true,
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext), // Use dialogContext
          child: Text('Cancel'),
        ),
        FilledButton(
          onPressed: () async {
            final navigator = Navigator.of(dialogContext);
            final messenger = ScaffoldMessenger.of(context);
            final name = controller.text;
            
            navigator.pop(); // Pop first
            await UserPreferences().setUserName(name);
            
            messenger.showSnackBar(
              SnackBar(content: Text('Name updated')),
            );
          },
          child: Text('Save'),
        ),
      ],
    ),
  );
}

  String _formatTime(DateTime time) {
  final now = DateTime.now();
  final difference = now.difference(time);
  
  if (difference.inDays > 7) {
    return '${time.day}/${time.month}';
  } else if (difference.inDays > 0) {
    return '${difference.inDays}d ago';
  } else if (difference.inHours > 0) {
    return '${difference.inHours}h ago';
  } else if (difference.inMinutes > 0) {
    return '${difference.inMinutes}m ago';
  } else {
    return 'Just now';
  }
}

  @override
  void dispose() {
    _refreshTimer?.cancel();
    _searchDebounceTimer?.cancel();
    _searchController.dispose();
    _peripheralConnectionSubscription?.cancel();
    super.dispose();
  }
}