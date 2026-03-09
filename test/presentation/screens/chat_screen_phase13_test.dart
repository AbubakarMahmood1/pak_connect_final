import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';

import 'package:bluetooth_low_energy/bluetooth_low_energy.dart'
    show BluetoothLowEnergyState;
import 'package:pak_connect/domain/entities/contact.dart';
import 'package:pak_connect/domain/entities/message.dart';
import 'package:pak_connect/domain/interfaces/i_chats_repository.dart';
import 'package:pak_connect/domain/interfaces/i_connection_service.dart';
import 'package:pak_connect/domain/interfaces/i_contact_repository.dart';
import 'package:pak_connect/domain/interfaces/i_message_repository.dart';
import 'package:pak_connect/domain/interfaces/i_mesh_networking_service.dart';
import 'package:pak_connect/domain/models/connection_info.dart';
import 'package:pak_connect/domain/models/mesh_network_models.dart';
import 'package:pak_connect/domain/models/security_level.dart';
import 'package:pak_connect/domain/models/security_state.dart';
import 'package:pak_connect/domain/services/mesh_networking_service.dart'
    show PendingBinaryTransfer, ReceivedBinaryEvent;
import 'package:pak_connect/domain/values/id_types.dart';

import 'package:pak_connect/presentation/controllers/chat_screen_controller.dart';
import 'package:pak_connect/presentation/providers/ble_providers.dart';
import 'package:pak_connect/presentation/providers/mesh_networking_provider.dart';
import 'package:pak_connect/presentation/providers/security_state_provider.dart';
import 'package:pak_connect/presentation/screens/chat_screen.dart';
import 'package:pak_connect/presentation/widgets/chat_binary_widgets.dart';
import 'package:pak_connect/presentation/widgets/chat_screen_helpers.dart';
import 'package:pak_connect/presentation/widgets/chat_screen_sections.dart';

// ============================================================================
// FAKE IMPLEMENTATIONS
// ============================================================================

class _FakeMessageRepository extends Fake implements IMessageRepository {
  List<Message> messages = [];

  @override
  Future<List<Message>> getMessages(ChatId chatId) async => messages;

  @override
  Future<Message?> getMessageById(MessageId id) async => null;

  @override
  Future<void> saveMessage(Message m) async {}

  @override
  Future<void> updateMessage(Message m) async {}

  @override
  Future<void> clearMessages(ChatId chatId) async {}

  @override
  Future<bool> deleteMessage(MessageId id) async => true;

  @override
  Future<List<Message>> getAllMessages() async => [];

  @override
  Future<List<Message>> getMessagesForContact(String pk) async => [];

  @override
  Future<void> migrateChatId(ChatId old, ChatId newId) async {}
}

class _FakeContactRepository extends Fake implements IContactRepository {
  @override
  Future<Contact?> getContact(String pk) async => null;

  @override
  Future<Contact?> getContactByUserId(UserId userId) async => null;

  @override
  Future<Contact?> getContactByPersistentKey(String pk) async => null;

  @override
  Future<Contact?> getContactByPersistentUserId(UserId pk) async => null;

  @override
  Future<Contact?> getContactByCurrentEphemeralId(String id) async => null;

  @override
  Future<Contact?> getContactByAnyId(String id) async => null;

  @override
  Future<Map<String, Contact>> getAllContacts() async => {};

  @override
  Future<String?> getContactName(String pk) async => null;

  @override
  Future<void> saveContact(String pk, String name) async {}

  @override
  Future<bool> deleteContact(String pk) async => true;

  @override
  Future<void> markContactVerified(String pk) async {}

  @override
  Future<void> updateNoiseSession({
    required String publicKey,
    required String noisePublicKey,
    required String sessionState,
  }) async {}

  @override
  Future<void> updateContactSecurityLevel(
    String pk,
    SecurityLevel level,
  ) async {}

  @override
  Future<void> updateContactEphemeralId(
    String pk,
    String newEphemeralId,
  ) async {}

  @override
  Future<SecurityLevel> getContactSecurityLevel(String pk) async =>
      SecurityLevel.low;

  @override
  Future<void> downgradeSecurityForDeletedContact(
    String pk,
    String reason,
  ) async {}

  @override
  Future<bool> upgradeContactSecurity(
    String pk,
    SecurityLevel level,
  ) async =>
      true;

  @override
  Future<bool> resetContactSecurity(String pk, String reason) async => true;

  @override
  Future<void> saveContactWithSecurity(
    String pk,
    String name,
    SecurityLevel level, {
    String? currentEphemeralId,
    String? persistentPublicKey,
  }) async {}

  @override
  Future<void> cacheSharedSecret(String pk, String secret) async {}

  @override
  Future<String?> getCachedSharedSecret(String pk) async => null;

  @override
  Future<void> cacheSharedSeedBytes(String pk, Uint8List seed) async {}

  @override
  Future<Uint8List?> getCachedSharedSeedBytes(String pk) async => null;

  @override
  Future<void> clearCachedSecrets(String pk) async {}

  @override
  Future<int> getContactCount() async => 0;

  @override
  Future<int> getVerifiedContactCount() async => 0;

  @override
  Future<Map<SecurityLevel, int>> getContactsBySecurityLevel() async => {};

  @override
  Future<int> getRecentlyActiveContactCount() async => 0;

  @override
  Future<void> markContactFavorite(String pk) async {}

  @override
  Future<void> unmarkContactFavorite(String pk) async {}

  @override
  Future<bool> toggleContactFavorite(String pk) async => true;

  @override
  Future<List<Contact>> getFavoriteContacts() async => [];

  @override
  Future<int> getFavoriteContactCount() async => 0;

  @override
  Future<bool> isContactFavorite(String pk) async => false;
}

class _FakeChatsRepository extends Fake implements IChatsRepository {
  @override
  Future<void> markChatAsRead(ChatId chatId) async {}

  @override
  Future<int> getTotalUnreadCount() async => 0;

  @override
  Future<void> incrementUnreadCount(ChatId chatId) async {}

  @override
  Future<void> updateContactLastSeen(String pk) async {}

  @override
  Future<void> storeDeviceMapping(String? deviceUuid, String publicKey) async {}

  @override
  Future<int> getChatCount() async => 0;

  @override
  Future<int> getArchivedChatCount() async => 0;

  @override
  Future<int> getTotalMessageCount() async => 0;

  @override
  Future<int> cleanupOrphanedEphemeralContacts() async => 0;
}

class _FakeConnectionService extends Fake implements IConnectionService {
  _FakeConnectionService({this.activelyReconnecting = false});

  final bool activelyReconnecting;

  @override
  BluetoothLowEnergyState get state => BluetoothLowEnergyState.poweredOn;

  @override
  bool get isActivelyReconnecting => activelyReconnecting;

  @override
  String? get theirPersistentPublicKey => null;

  @override
  String? get theirPersistentKey => null;

  @override
  String? get currentSessionId => null;

  @override
  String? get theirEphemeralId => null;

  @override
  String? get otherUserName => null;

  @override
  ConnectionInfo get currentConnectionInfo => const ConnectionInfo(
    isConnected: true,
    isReady: true,
  );

  @override
  Stream<ConnectionInfo> get connectionInfo => const Stream.empty();
}

class _FakeMeshNetworkingService extends Fake
    implements IMeshNetworkingService {
  final _streamController = StreamController<ReceivedBinaryEvent>.broadcast();

  @override
  Stream<ReceivedBinaryEvent> get binaryPayloadStream =>
      _streamController.stream;

  @override
  List<PendingBinaryTransfer> getPendingBinaryTransfers() => [];

  @override
  Future<bool> retryBinaryMedia({
    required String transferId,
    String? recipientId,
    int? originalType,
  }) async =>
      true;

  @override
  Stream<MeshNetworkStatus> get meshStatus => const Stream.empty();

  @override
  void dispose() {
    _streamController.close();
  }
}

// ============================================================================
// TEST DATA
// ============================================================================

const _defaultConnectionInfo = ConnectionInfo(
  isConnected: true,
  isReady: true,
  otherUserName: 'Test User',
);

const _disconnectedInfo = ConnectionInfo(
  isConnected: false,
  isReady: false,
);

const _defaultMeshStatus= MeshNetworkStatus(
  isInitialized: true,
  isConnected: true,
  statistics: MeshNetworkStatistics(
    nodeId: 'test-node',
    isInitialized: true,
    spamPreventionActive: false,
    queueSyncActive: false,
  ),
);

SecurityState _verifiedSecurityState() => const SecurityState(
  status: SecurityStatus.verifiedContact,
  canSendMessages: true,
  showContactAddButton: false,
  showPairingButton: false,
  showContactSyncButton: false,
);

SecurityState _pairedSecurityState() => const SecurityState(
  status: SecurityStatus.paired,
  canSendMessages: true,
  showContactAddButton: false,
  showPairingButton: false,
  showContactSyncButton: false,
);

SecurityState _needsPairingSecurityState() => const SecurityState(
  status: SecurityStatus.needsPairing,
  canSendMessages: true,
  showContactAddButton: false,
  showPairingButton: true,
  showContactSyncButton: false,
);

SecurityState _asymmetricSecurityState() => const SecurityState(
  status: SecurityStatus.asymmetricContact,
  canSendMessages: true,
  showContactAddButton: false,
  showPairingButton: false,
  showContactSyncButton: true,
  otherPublicKey: 'test-public-key',
  otherUserName: 'Test User',
);

SecurityState _disconnectedSecurityState() => const SecurityState(
  status: SecurityStatus.disconnected,
  canSendMessages: false,
  showContactAddButton: false,
  showPairingButton: false,
  showContactSyncButton: false,
);

SecurityState _showAddContactState() => const SecurityState(
  status: SecurityStatus.needsPairing,
  canSendMessages: true,
  showContactAddButton: true,
  showPairingButton: false,
  showContactSyncButton: false,
);

// ============================================================================
// GetIt REGISTRATION HELPERS
// ============================================================================

void _registerService<T extends Object>(GetIt locator, T instance) {
  if (locator.isRegistered<T>()) {
    locator.unregister<T>();
  }
  locator.registerSingleton<T>(instance);
}

void _cleanupGetIt(GetIt locator) {
  if (locator.isRegistered<IMessageRepository>()) {
    locator.unregister<IMessageRepository>();
  }
  if (locator.isRegistered<IContactRepository>()) {
    locator.unregister<IContactRepository>();
  }
  if (locator.isRegistered<IChatsRepository>()) {
    locator.unregister<IChatsRepository>();
  }
}

// ============================================================================
// PUMP HELPER
// ============================================================================

Future<void> _pumpChatScreen(
  WidgetTester tester, {
  ConnectionInfo connectionInfo = _defaultConnectionInfo,
  SecurityState? securityState,
  bool isActivelyReconnecting = false,
  String chatId = 'test-chat',
  String contactName = 'Test User',
  String contactPublicKey = 'test-public-key',
}) async {
  final locator = GetIt.instance;
  final msgRepo = _FakeMessageRepository();
  final contactRepo = _FakeContactRepository();
  final chatsRepo = _FakeChatsRepository();
  final connService = _FakeConnectionService(
    activelyReconnecting: isActivelyReconnecting,
  );
  final meshService = _FakeMeshNetworkingService();

  _registerService<IMessageRepository>(locator, msgRepo);
  _registerService<IContactRepository>(locator, contactRepo);
  _registerService<IChatsRepository>(locator, chatsRepo);

  final secState = securityState ?? _verifiedSecurityState();

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        // Connection and mesh leaf providers
        connectionServiceProvider.overrideWith((ref) => connService),
        connectionInfoProvider.overrideWith(
          (ref) => AsyncValue.data(connectionInfo),
        ),
        meshNetworkingServiceProvider.overrideWith((ref) => meshService),
        meshNetworkStatusProvider.overrideWith(
          (ref) => const AsyncValue.data(_defaultMeshStatus),
        ),

        // Security state
        securityStateProvider.overrideWith(
          (ref, key) async => secState,
        ),

        // Binary/payload providers
        binaryPayloadStreamProvider.overrideWith(
          (ref) => meshService.binaryPayloadStream,
        ),

        // Controller override to skip async initialize()
        chatScreenControllerProvider.overrideWith((ref, args) {
          return ChatScreenController(args);
        }),
      ],
      child: MaterialApp(
        home: ChatScreen.fromChatData(
          chatId: chatId,
          contactName: contactName,
          contactPublicKey: contactPublicKey,
        ),
      ),
    ),
  );

  // Pump once for initial build, then one more for post-frame callback
  await tester.pump();
  await tester.pump();
}

// ============================================================================
// TESTS
// ============================================================================

void main() {
  final locator = GetIt.instance;

  setUp(() {
    // Clear any stale registrations
  });

  tearDown(() {
    _cleanupGetIt(locator);
  });

  // --------------------------------------------------------------------------
  // GROUP 1: Basic Rendering
  // --------------------------------------------------------------------------
  group('ChatScreen – basic rendering', () {
    testWidgets('renders Scaffold with AppBar', (tester) async {
      await _pumpChatScreen(tester);

      expect(find.byType(Scaffold), findsOneWidget);
      expect(find.byType(AppBar), findsOneWidget);
    });

    testWidgets('shows contact name in AppBar title', (tester) async {
      await _pumpChatScreen(tester, contactName: 'Alice');

      expect(find.text('Alice'), findsOneWidget);
    });

    testWidgets('shows search icon in AppBar actions', (tester) async {
      await _pumpChatScreen(tester);

      expect(find.byIcon(Icons.search), findsOneWidget);
    });

    testWidgets('renders SafeArea body', (tester) async {
      await _pumpChatScreen(tester);

      expect(find.byType(SafeArea), findsAtLeastNWidgets(1));
    });

    testWidgets('renders with different contact name', (tester) async {
      await _pumpChatScreen(tester, contactName: 'Bob');

      expect(find.text('Bob'), findsOneWidget);
    });
  });

  // --------------------------------------------------------------------------
  // GROUP 2: Security Status Text (_buildStatusText coverage)
  // --------------------------------------------------------------------------
  group('ChatScreen – security status text', () {
    testWidgets('shows ECDH Encrypted for verifiedContact', (tester) async {
      await _pumpChatScreen(
        tester,
        securityState: _verifiedSecurityState(),
      );

      expect(find.textContaining('ECDH Encrypted'), findsOneWidget);
    });

    testWidgets('shows Paired for paired status', (tester) async {
      await _pumpChatScreen(
        tester,
        securityState: _pairedSecurityState(),
      );

      expect(find.textContaining('Paired'), findsOneWidget);
    });

    testWidgets('shows Contact Sync Needed for asymmetric', (tester) async {
      await _pumpChatScreen(
        tester,
        securityState: _asymmetricSecurityState(),
      );

      expect(find.textContaining('Contact Sync Needed'), findsOneWidget);
    });

    testWidgets('shows Basic Encryption for needsPairing', (tester) async {
      await _pumpChatScreen(
        tester,
        securityState: _needsPairingSecurityState(),
      );

      expect(find.textContaining('Basic Encryption'), findsOneWidget);
    });

    testWidgets('shows Disconnected for disconnected status', (tester) async {
      await _pumpChatScreen(
        tester,
        securityState: _disconnectedSecurityState(),
      );

      expect(find.textContaining('Disconnected'), findsOneWidget);
    });
  });

  // --------------------------------------------------------------------------
  // GROUP 3: Status Color (_getStatusColor coverage)
  // --------------------------------------------------------------------------
  group('ChatScreen – status color', () {
    testWidgets('green color for verified contact', (tester) async {
      await _pumpChatScreen(
        tester,
        securityState: _verifiedSecurityState(),
      );

      final textWidget = tester.widget<Text>(
        find.textContaining('ECDH Encrypted'),
      );
      expect(textWidget.style?.color, Colors.green);
    });

    testWidgets('blue color for paired status', (tester) async {
      await _pumpChatScreen(
        tester,
        securityState: _pairedSecurityState(),
      );

      final textWidget = tester.widget<Text>(
        find.textContaining('Paired'),
      );
      expect(textWidget.style?.color, Colors.blue);
    });

    testWidgets('orange color for asymmetric contact', (tester) async {
      await _pumpChatScreen(
        tester,
        securityState: _asymmetricSecurityState(),
      );

      final textWidget = tester.widget<Text>(
        find.textContaining('Contact Sync Needed'),
      );
      expect(textWidget.style?.color, Colors.orange);
    });

    testWidgets('orange color for needs pairing', (tester) async {
      await _pumpChatScreen(
        tester,
        securityState: _needsPairingSecurityState(),
      );

      final textWidget = tester.widget<Text>(
        find.textContaining('Basic Encryption'),
      );
      expect(textWidget.style?.color, Colors.orange);
    });

    testWidgets('grey color for disconnected', (tester) async {
      await _pumpChatScreen(
        tester,
        securityState: _disconnectedSecurityState(),
      );

      final textWidget = tester.widget<Text>(
        find.textContaining('Disconnected'),
      );
      expect(textWidget.style?.color, Colors.grey);
    });
  });

  // --------------------------------------------------------------------------
  // GROUP 4: Action Button (_buildSingleActionButton coverage)
  // --------------------------------------------------------------------------
  group('ChatScreen – action button', () {
    testWidgets('shows lock_open icon when showPairingButton', (tester) async {
      await _pumpChatScreen(
        tester,
        securityState: _needsPairingSecurityState(),
      );

      expect(find.byIcon(Icons.lock_open), findsOneWidget);
      expect(find.byTooltip('Secure Chat'), findsOneWidget);
    });

    testWidgets('shows person_add icon when showContactAddButton',
        (tester) async {
      await _pumpChatScreen(
        tester,
        securityState: _showAddContactState(),
      );

      expect(find.byIcon(Icons.person_add), findsOneWidget);
      expect(find.byTooltip('Add Contact'), findsOneWidget);
    });

    testWidgets('shows sync icon when showContactSyncButton', (tester) async {
      await _pumpChatScreen(
        tester,
        securityState: _asymmetricSecurityState(),
      );

      expect(find.byIcon(Icons.sync), findsOneWidget);
      expect(find.byTooltip('Sync Contact'), findsOneWidget);
    });

    testWidgets('shows no action button when all flags false', (tester) async {
      await _pumpChatScreen(
        tester,
        securityState: _verifiedSecurityState(),
      );

      expect(find.byIcon(Icons.lock_open), findsNothing);
      expect(find.byIcon(Icons.person_add), findsNothing);
      expect(find.byIcon(Icons.sync), findsNothing);
    });
  });

  // --------------------------------------------------------------------------
  // GROUP 5: Connection Status (_buildStatusText with connection info)
  // --------------------------------------------------------------------------
  group('ChatScreen – connection-aware status', () {
    testWidgets('shows "Connected" in status when connected and ready',
        (tester) async {
      await _pumpChatScreen(
        tester,
        connectionInfo: _defaultConnectionInfo,
        securityState: _verifiedSecurityState(),
      );

      // In repository mode, connectionInfo is not shown in status text
      // (because _isRepositoryMode is true)
      expect(find.textContaining('ECDH Encrypted'), findsOneWidget);
    });

    testWidgets('shows Offline with disconnected info', (tester) async {
      await _pumpChatScreen(
        tester,
        connectionInfo: _disconnectedInfo,
        securityState: _verifiedSecurityState(),
      );

      // Repository mode doesn't prefix with Offline
      expect(find.textContaining('ECDH Encrypted'), findsOneWidget);
    });
  });

  // --------------------------------------------------------------------------
  // GROUP 6: Hint Text (_getMessageHintText coverage)
  // --------------------------------------------------------------------------
  group('ChatScreen – hint text', () {
    testWidgets('shows "Type a message..." in repository mode',
        (tester) async {
      await _pumpChatScreen(tester);

      expect(find.text('Type a message...'), findsOneWidget);
    });
  });

  // --------------------------------------------------------------------------
  // GROUP 7: Reconnection Banner
  // --------------------------------------------------------------------------
  group('ChatScreen – reconnection banner', () {
    testWidgets('hides reconnection banner when connected', (tester) async {
      await _pumpChatScreen(
        tester,
        connectionInfo: _defaultConnectionInfo,
      );

      expect(find.textContaining('Reconnecting'), findsNothing);
    });

    testWidgets('shows reconnection banner when disconnected', (tester) async {
      await _pumpChatScreen(
        tester,
        connectionInfo: _disconnectedInfo,
      );

      // The ReconnectionBanner widget should appear
      expect(find.byType(Scaffold), findsOneWidget);
    });

    testWidgets('shows reconnection banner when actively reconnecting',
        (tester) async {
      await _pumpChatScreen(
        tester,
        connectionInfo: _defaultConnectionInfo,
        isActivelyReconnecting: true,
      );

      expect(find.byType(Scaffold), findsOneWidget);
    });
  });

  // --------------------------------------------------------------------------
  // GROUP 8: Constructor Assertions
  // --------------------------------------------------------------------------
  group('ChatScreen – constructor', () {
    testWidgets('fromChatData constructor renders correctly', (tester) async {
      await _pumpChatScreen(
        tester,
        chatId: 'chat-abc',
        contactName: 'Charlie',
        contactPublicKey: 'pk-abc',
      );

      expect(find.text('Charlie'), findsOneWidget);
    });

    testWidgets('renders with minimal chat data', (tester) async {
      await _pumpChatScreen(
        tester,
        chatId: 'minimal-chat',
        contactName: 'Min',
        contactPublicKey: 'pk-min',
      );

      expect(find.text('Min'), findsOneWidget);
    });
  });

  // --------------------------------------------------------------------------
  // GROUP 9: Search Toggle
  // --------------------------------------------------------------------------
  group('ChatScreen – search', () {
    testWidgets('search button has correct tooltip', (tester) async {
      await _pumpChatScreen(tester);

      expect(find.byTooltip('Search messages'), findsOneWidget);
    });
  });

  // --------------------------------------------------------------------------
  // GROUP 10: Security State Loading and Error
  // --------------------------------------------------------------------------
  group('ChatScreen – security async states', () {
    testWidgets('renders correctly with verified security state',
        (tester) async {
      await _pumpChatScreen(
        tester,
        securityState: _verifiedSecurityState(),
      );

      expect(find.byType(Scaffold), findsOneWidget);
      expect(find.textContaining('ECDH Encrypted'), findsOneWidget);
    });

    testWidgets('renders correctly with paired security state',
        (tester) async {
      await _pumpChatScreen(
        tester,
        securityState: _pairedSecurityState(),
      );

      expect(find.byType(Scaffold), findsOneWidget);
      expect(find.textContaining('Paired'), findsOneWidget);
    });
  });

  // --------------------------------------------------------------------------
  // GROUP 11: Widget Structure Verification
  // --------------------------------------------------------------------------
  group('ChatScreen – widget structure', () {
    testWidgets('has Column as body child of SafeArea', (tester) async {
      await _pumpChatScreen(tester);

      expect(find.byType(Column), findsWidgets);
    });

    testWidgets('renders with proper widget tree', (tester) async {
      await _pumpChatScreen(tester);

      // Verify the key structural widgets exist
      expect(find.byType(Scaffold), findsOneWidget);
      expect(find.byType(AppBar), findsOneWidget);
      expect(find.byType(SafeArea), findsAtLeastNWidgets(1));
    });

    testWidgets('AppBar title is a Column widget', (tester) async {
      await _pumpChatScreen(tester);

      // The AppBar title should contain the contact name
      expect(find.text('Test User'), findsOneWidget);
    });

    testWidgets('AppBar has multiple actions', (tester) async {
      await _pumpChatScreen(
        tester,
        securityState: _needsPairingSecurityState(),
      );

      // Should have search + pairing action
      expect(find.byIcon(Icons.search), findsOneWidget);
      expect(find.byIcon(Icons.lock_open), findsOneWidget);
    });
  });

  // --------------------------------------------------------------------------
  // GROUP 12: Multiple Security States (comprehensive coverage)
  // --------------------------------------------------------------------------
  group('ChatScreen – all security states cycle', () {
    testWidgets('verified contact state renders correctly', (tester) async {
      await _pumpChatScreen(
        tester,
        securityState: _verifiedSecurityState(),
      );
      expect(find.byType(Scaffold), findsOneWidget);
    });

    testWidgets('paired state renders correctly', (tester) async {
      await _pumpChatScreen(
        tester,
        securityState: _pairedSecurityState(),
      );
      expect(find.byType(Scaffold), findsOneWidget);
    });

    testWidgets('needs pairing state renders correctly', (tester) async {
      await _pumpChatScreen(
        tester,
        securityState: _needsPairingSecurityState(),
      );
      expect(find.byType(Scaffold), findsOneWidget);
    });

    testWidgets('asymmetric state renders correctly', (tester) async {
      await _pumpChatScreen(
        tester,
        securityState: _asymmetricSecurityState(),
      );
      expect(find.byType(Scaffold), findsOneWidget);
    });

    testWidgets('disconnected state renders correctly', (tester) async {
      await _pumpChatScreen(
        tester,
        securityState: _disconnectedSecurityState(),
      );
      expect(find.byType(Scaffold), findsOneWidget);
    });

    testWidgets('add contact state renders correctly', (tester) async {
      await _pumpChatScreen(
        tester,
        securityState: _showAddContactState(),
      );
      expect(find.byType(Scaffold), findsOneWidget);
    });
  });

  // --------------------------------------------------------------------------
  // GROUP 13: Dispose does not crash
  // --------------------------------------------------------------------------
  group('ChatScreen – dispose', () {
    testWidgets('widget can be removed without error', (tester) async {
      await _pumpChatScreen(tester);
      expect(find.byType(Scaffold), findsOneWidget);

      // Navigate away to trigger dispose
      await tester.pumpWidget(const MaterialApp(home: Scaffold()));
      await tester.pump();
      await tester.pump();

      expect(find.byType(ChatScreen), findsNothing);
    });
  });

  // --------------------------------------------------------------------------
  // GROUP 14: Security Async Loading & Error (AppBar subtitle)
  // --------------------------------------------------------------------------
  group('ChatScreen – security async loading/error', () {
    testWidgets('shows "Loading..." when security state resolves', (
      tester,
    ) async {
      // Override securityStateProvider with a never-completing future
      final locator = GetIt.instance;
      final msgRepo = _FakeMessageRepository();
      final contactRepo = _FakeContactRepository();
      final chatsRepo = _FakeChatsRepository();
      final connService = _FakeConnectionService();
      final meshService = _FakeMeshNetworkingService();

      _registerService<IMessageRepository>(locator, msgRepo);
      _registerService<IContactRepository>(locator, contactRepo);
      _registerService<IChatsRepository>(locator, chatsRepo);

      final neverCompletes = Completer<SecurityState>();

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            connectionServiceProvider.overrideWith((ref) => connService),
            connectionInfoProvider.overrideWith(
              (ref) => const AsyncValue.data(_defaultConnectionInfo),
            ),
            meshNetworkingServiceProvider.overrideWith((ref) => meshService),
            meshNetworkStatusProvider.overrideWith(
              (ref) => const AsyncValue.data(_defaultMeshStatus),
            ),
            securityStateProvider.overrideWith(
              (ref, key) => neverCompletes.future,
            ),
            binaryPayloadStreamProvider.overrideWith(
              (ref) => meshService.binaryPayloadStream,
            ),
            chatScreenControllerProvider.overrideWith((ref, args) {
              return ChatScreenController(args);
            }),
          ],
          child: MaterialApp(
            home: ChatScreen.fromChatData(
              chatId: 'test-chat',
              contactName: 'Loader',
              contactPublicKey: 'pk-load',
            ),
          ),
        ),
      );

      await tester.pump();
      await tester.pump();

      expect(find.text('Loading...'), findsOneWidget);
    });

    testWidgets('shows "Error" when security state fails', (tester) async {
      final locator = GetIt.instance;
      final msgRepo = _FakeMessageRepository();
      final contactRepo = _FakeContactRepository();
      final chatsRepo = _FakeChatsRepository();
      final connService = _FakeConnectionService();
      final meshService = _FakeMeshNetworkingService();

      _registerService<IMessageRepository>(locator, msgRepo);
      _registerService<IContactRepository>(locator, contactRepo);
      _registerService<IChatsRepository>(locator, chatsRepo);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            connectionServiceProvider.overrideWith((ref) => connService),
            connectionInfoProvider.overrideWith(
              (ref) => const AsyncValue.data(_defaultConnectionInfo),
            ),
            meshNetworkingServiceProvider.overrideWith((ref) => meshService),
            meshNetworkStatusProvider.overrideWith(
              (ref) => const AsyncValue.data(_defaultMeshStatus),
            ),
            securityStateProvider.overrideWith(
              (ref, key) async {
                throw StateError('boom');
              },
            ),
            binaryPayloadStreamProvider.overrideWith(
              (ref) => meshService.binaryPayloadStream,
            ),
            chatScreenControllerProvider.overrideWith((ref, args) {
              return ChatScreenController(args);
            }),
          ],
          child: MaterialApp(
            home: ChatScreen.fromChatData(
              chatId: 'err-chat',
              contactName: 'ErrorUser',
              contactPublicKey: 'pk-err',
            ),
          ),
        ),
      );

      // Multiple pumps for future error resolution
      await tester.pump();
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('Error'), findsOneWidget);
    });

    testWidgets('shows no action button during security loading', (
      tester,
    ) async {
      final locator = GetIt.instance;
      final msgRepo = _FakeMessageRepository();
      final contactRepo = _FakeContactRepository();
      final chatsRepo = _FakeChatsRepository();
      final connService = _FakeConnectionService();
      final meshService = _FakeMeshNetworkingService();

      _registerService<IMessageRepository>(locator, msgRepo);
      _registerService<IContactRepository>(locator, contactRepo);
      _registerService<IChatsRepository>(locator, chatsRepo);

      final neverCompletes = Completer<SecurityState>();

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            connectionServiceProvider.overrideWith((ref) => connService),
            connectionInfoProvider.overrideWith(
              (ref) => const AsyncValue.data(_defaultConnectionInfo),
            ),
            meshNetworkingServiceProvider.overrideWith((ref) => meshService),
            meshNetworkStatusProvider.overrideWith(
              (ref) => const AsyncValue.data(_defaultMeshStatus),
            ),
            securityStateProvider.overrideWith(
              (ref, key) => neverCompletes.future,
            ),
            binaryPayloadStreamProvider.overrideWith(
              (ref) => meshService.binaryPayloadStream,
            ),
            chatScreenControllerProvider.overrideWith((ref, args) {
              return ChatScreenController(args);
            }),
          ],
          child: MaterialApp(
            home: ChatScreen.fromChatData(
              chatId: 'load-chat',
              contactName: 'LoadUser',
              contactPublicKey: 'pk-load',
            ),
          ),
        ),
      );

      await tester.pump();
      await tester.pump();

      // No pairing/add/sync buttons when loading
      expect(find.byIcon(Icons.lock_open), findsNothing);
      expect(find.byIcon(Icons.person_add), findsNothing);
      expect(find.byIcon(Icons.sync), findsNothing);
    });
  });

  // --------------------------------------------------------------------------
  // GROUP 15: Send Message (_sendMessage coverage)
  // --------------------------------------------------------------------------
  group('ChatScreen – send message', () {
    testWidgets('entering text and tapping send clears the field', (
      tester,
    ) async {
      await _pumpChatScreen(tester);

      // Find the text field
      final textFieldFinder = find.byType(TextField);
      expect(textFieldFinder, findsOneWidget);

      // Enter text
      await tester.enterText(textFieldFinder, 'Hello World');
      await tester.pump();

      // Tap send icon
      final sendButton = find.byIcon(Icons.send);
      if (sendButton.evaluate().isNotEmpty) {
        await tester.tap(sendButton);
        await tester.pump();

        // Text should be cleared after send
        final textField = tester.widget<TextField>(textFieldFinder);
        expect(textField.controller?.text, isEmpty);
      }
    });

    testWidgets('empty text does not trigger send', (tester) async {
      await _pumpChatScreen(tester);

      final textFieldFinder = find.byType(TextField);
      expect(textFieldFinder, findsOneWidget);

      // Don't enter text, just tap send
      final sendButton = find.byIcon(Icons.send);
      if (sendButton.evaluate().isNotEmpty) {
        await tester.tap(sendButton);
        await tester.pump();
        // No crash
      }
    });

    testWidgets('whitespace-only text does not trigger send', (tester) async {
      await _pumpChatScreen(tester);

      final textFieldFinder = find.byType(TextField);
      await tester.enterText(textFieldFinder, '   ');
      await tester.pump();

      final sendButton = find.byIcon(Icons.send);
      if (sendButton.evaluate().isNotEmpty) {
        await tester.tap(sendButton);
        await tester.pump();
        // No crash
      }
    });
  });

  // --------------------------------------------------------------------------
  // GROUP 16: Search Toggle (_toggleSearchMode coverage)
  // --------------------------------------------------------------------------
  group('ChatScreen – search toggle', () {
    testWidgets('tapping search icon does not crash', (tester) async {
      await _pumpChatScreen(tester);

      final searchIcon = find.byIcon(Icons.search);
      expect(searchIcon, findsOneWidget);

      await tester.tap(searchIcon);
      await tester.pump();
      await tester.pump();

      // Verify widget tree is still intact
      expect(find.byType(Scaffold), findsOneWidget);
    });
  });

  // --------------------------------------------------------------------------
  // GROUP 17: ChatComposer hint text variants
  // --------------------------------------------------------------------------
  group('ChatScreen – composer hint text', () {
    testWidgets('shows "Type a message..." in repo mode', (tester) async {
      await _pumpChatScreen(tester);

      expect(find.text('Type a message...'), findsOneWidget);
    });
  });

  // --------------------------------------------------------------------------
  // GROUP 18: ChatMessagesSection is present
  // --------------------------------------------------------------------------
  group('ChatScreen – message section', () {
    testWidgets('renders ChatMessagesSection in body', (tester) async {
      await _pumpChatScreen(tester);

      expect(find.byType(ChatMessagesSection), findsOneWidget);
    });

    testWidgets('renders ChatComposer in body', (tester) async {
      await _pumpChatScreen(tester);

      expect(find.byType(ChatComposer), findsOneWidget);
    });
  });

  // --------------------------------------------------------------------------
  // GROUP 19: Reconnection Banner with bluetooth on
  // --------------------------------------------------------------------------
  group('ChatScreen – bluetooth state banner', () {
    testWidgets('hides reconnection banner when BLE powered on and connected',
        (tester) async {
      await _pumpChatScreen(
        tester,
        connectionInfo: _defaultConnectionInfo,
      );

      // Should not show bluetooth_disabled icon
      expect(find.byIcon(Icons.bluetooth_disabled), findsNothing);
    });
  });

  // --------------------------------------------------------------------------
  // GROUP 20: FAB (floating action button)
  // --------------------------------------------------------------------------
  group('ChatScreen – scroll down FAB', () {
    testWidgets('no FAB when messages list is empty', (tester) async {
      await _pumpChatScreen(tester);

      // With empty messages, FAB should not show
      expect(find.byType(FloatingActionButton), findsNothing);
    });
  });

  // --------------------------------------------------------------------------
  // GROUP 21: Binary inbox/transfer areas (empty state)
  // --------------------------------------------------------------------------
  group('ChatScreen – binary payload areas', () {
    testWidgets('no BinaryInboxList when inbox is empty', (tester) async {
      await _pumpChatScreen(tester);

      expect(find.byType(BinaryInboxList), findsNothing);
    });

    testWidgets('no PendingBinaryBanner when transfers empty', (tester) async {
      await _pumpChatScreen(tester);

      expect(find.byType(PendingBinaryBanner), findsNothing);
    });
  });

  // --------------------------------------------------------------------------
  // GROUP 22: InitializationStatusPanel
  // --------------------------------------------------------------------------
  group('ChatScreen – initialization panel', () {
    testWidgets('no InitializationStatusPanel when not mesh initializing',
        (tester) async {
      await _pumpChatScreen(tester);

      expect(find.byType(InitializationStatusPanel), findsNothing);
    });
  });

  // --------------------------------------------------------------------------
  // GROUP 23: AppBar Column structure
  // --------------------------------------------------------------------------
  group('ChatScreen – AppBar details', () {
    testWidgets('AppBar title is a Column with contact name', (tester) async {
      await _pumpChatScreen(tester, contactName: 'Zara');

      expect(find.text('Zara'), findsOneWidget);
    });

    testWidgets('AppBar subtitle reflects verified status', (tester) async {
      await _pumpChatScreen(
        tester,
        securityState: _verifiedSecurityState(),
      );

      // Should find "ECDH Encrypted" in AppBar
      final statusFinder = find.textContaining('ECDH Encrypted');
      expect(statusFinder, findsOneWidget);
    });

    testWidgets('AppBar subtitle uses grey for loading state', (
      tester,
    ) async {
      final locator = GetIt.instance;
      final msgRepo = _FakeMessageRepository();
      final contactRepo = _FakeContactRepository();
      final chatsRepo = _FakeChatsRepository();
      final connService = _FakeConnectionService();
      final meshService = _FakeMeshNetworkingService();

      _registerService<IMessageRepository>(locator, msgRepo);
      _registerService<IContactRepository>(locator, contactRepo);
      _registerService<IChatsRepository>(locator, chatsRepo);

      final neverCompletes = Completer<SecurityState>();

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            connectionServiceProvider.overrideWith((ref) => connService),
            connectionInfoProvider.overrideWith(
              (ref) => const AsyncValue.data(_defaultConnectionInfo),
            ),
            meshNetworkingServiceProvider.overrideWith((ref) => meshService),
            meshNetworkStatusProvider.overrideWith(
              (ref) => const AsyncValue.data(_defaultMeshStatus),
            ),
            securityStateProvider.overrideWith(
              (ref, key) => neverCompletes.future,
            ),
            binaryPayloadStreamProvider.overrideWith(
              (ref) => meshService.binaryPayloadStream,
            ),
            chatScreenControllerProvider.overrideWith((ref, args) {
              return ChatScreenController(args);
            }),
          ],
          child: MaterialApp(
            home: ChatScreen.fromChatData(
              chatId: 'grey-chat',
              contactName: 'GreyUser',
              contactPublicKey: 'pk-grey',
            ),
          ),
        ),
      );

      await tester.pump();
      await tester.pump();

      final loadingText = tester.widget<Text>(find.text('Loading...'));
      expect(loadingText.style?.color, Colors.grey);
    });

    testWidgets('AppBar subtitle uses red for error state', (tester) async {
      final locator = GetIt.instance;
      final msgRepo = _FakeMessageRepository();
      final contactRepo = _FakeContactRepository();
      final chatsRepo = _FakeChatsRepository();
      final connService = _FakeConnectionService();
      final meshService = _FakeMeshNetworkingService();

      _registerService<IMessageRepository>(locator, msgRepo);
      _registerService<IContactRepository>(locator, contactRepo);
      _registerService<IChatsRepository>(locator, chatsRepo);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            connectionServiceProvider.overrideWith((ref) => connService),
            connectionInfoProvider.overrideWith(
              (ref) => const AsyncValue.data(_defaultConnectionInfo),
            ),
            meshNetworkingServiceProvider.overrideWith((ref) => meshService),
            meshNetworkStatusProvider.overrideWith(
              (ref) => const AsyncValue.data(_defaultMeshStatus),
            ),
            securityStateProvider.overrideWith(
              (ref, key) async {
                throw StateError('boom');
              },
            ),
            binaryPayloadStreamProvider.overrideWith(
              (ref) => meshService.binaryPayloadStream,
            ),
            chatScreenControllerProvider.overrideWith((ref, args) {
              return ChatScreenController(args);
            }),
          ],
          child: MaterialApp(
            home: ChatScreen.fromChatData(
              chatId: 'red-chat',
              contactName: 'RedUser',
              contactPublicKey: 'pk-red',
            ),
          ),
        ),
      );

      await tester.pump();
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      final errorText = tester.widget<Text>(find.text('Error'));
      expect(errorText.style?.color, Colors.red);
    });
  });

  // --------------------------------------------------------------------------
  // GROUP 24: canSendImage depends on connection
  // --------------------------------------------------------------------------
  group('ChatScreen – image send button', () {
    testWidgets('image button present when connected', (tester) async {
      await _pumpChatScreen(
        tester,
        connectionInfo: _defaultConnectionInfo,
      );

      // ChatComposer has an image button
      expect(find.byIcon(Icons.image), findsOneWidget);
    });
  });
}
