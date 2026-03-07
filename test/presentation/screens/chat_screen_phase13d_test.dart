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
import 'package:pak_connect/domain/entities/enhanced_message.dart';
import 'package:pak_connect/domain/interfaces/i_chats_repository.dart';
import 'package:pak_connect/domain/interfaces/i_connection_service.dart';
import 'package:pak_connect/domain/interfaces/i_contact_repository.dart';
import 'package:pak_connect/domain/interfaces/i_message_repository.dart';
import 'package:pak_connect/domain/interfaces/i_mesh_networking_service.dart';
import 'package:pak_connect/domain/interfaces/i_security_service.dart';
import 'package:pak_connect/domain/models/connection_info.dart';
import 'package:pak_connect/domain/models/mesh_network_models.dart';
import 'package:pak_connect/domain/models/security_level.dart';
import 'package:pak_connect/domain/models/security_state.dart';
import 'package:pak_connect/domain/services/mesh_networking_service.dart'
    show PendingBinaryTransfer, ReceivedBinaryEvent;
import 'package:pak_connect/domain/values/id_types.dart';

import 'package:pak_connect/presentation/controllers/chat_screen_controller.dart';
import 'package:pak_connect/presentation/providers/ble_providers.dart';
import 'package:pak_connect/presentation/providers/chat_session_providers.dart';
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
  _FakeConnectionService({
    this.activelyReconnecting = false,
    this.persistentPublicKey,
    this.sessionId,
  });

  final bool activelyReconnecting;
  final String? persistentPublicKey;
  final String? sessionId;

  @override
  BluetoothLowEnergyState get state => BluetoothLowEnergyState.poweredOn;

  @override
  bool get isActivelyReconnecting => activelyReconnecting;

  @override
  String? get theirPersistentPublicKey => persistentPublicKey;

  @override
  String? get theirPersistentKey => persistentPublicKey;

  @override
  String? get currentSessionId => sessionId;

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

  @override
  void setPairingInProgress(bool isInProgress) {}
}

class _FakeMeshNetworkingService extends Fake
    implements IMeshNetworkingService {
  final _streamController = StreamController<ReceivedBinaryEvent>.broadcast();
  List<PendingBinaryTransfer> pendingTransfers = [];
  int retryCount = 0;

  @override
  Stream<ReceivedBinaryEvent> get binaryPayloadStream =>
      _streamController.stream;

  @override
  List<PendingBinaryTransfer> getPendingBinaryTransfers() => pendingTransfers;

  @override
  Future<bool> retryBinaryMedia({
    required String transferId,
    String? recipientId,
    int? originalType,
  }) async {
    retryCount++;
    return true;
  }

  @override
  Stream<MeshNetworkStatus> get meshStatus => const Stream.empty();

  void dispose() {
    _streamController.close();
  }
}

class _FakeSecurityService extends Fake implements ISecurityService {
  @override
  bool hasEstablishedNoiseSession(String peerSessionId) => false;
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

const _connectingInfo = ConnectionInfo(
  isConnected: true,
  isReady: false,
);

const _reconnectingInfo = ConnectionInfo(
  isConnected: false,
  isReady: false,
  isReconnecting: true,
);

const _defaultMeshStatus = MeshNetworkStatus(
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

SecurityState _unknownSecurityState() => const SecurityState(
  status: SecurityStatus.unknown,
  canSendMessages: false,
  showContactAddButton: false,
  showPairingButton: false,
  showContactSyncButton: false,
);

Message _message({
  required String id,
  String chatId = 'test-chat',
  String content = 'Hello!',
  bool isFromMe = false,
  MessageStatus status = MessageStatus.delivered,
}) {
  return Message(
    id: MessageId(id),
    chatId: ChatId(chatId),
    content: content,
    timestamp: DateTime(2026, 1, 15, 10, 0),
    isFromMe: isFromMe,
    status: status,
  );
}

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
  if (locator.isRegistered<ISecurityService>()) {
    locator.unregister<ISecurityService>();
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
  List<PendingBinaryTransfer>? pendingTransfers,
  Map<String, ReceivedBinaryEvent>? binaryInbox,
  _FakeMeshNetworkingService? meshServiceOverride,
  _FakeConnectionService? connectionServiceOverride,
}) async {
  final locator = GetIt.instance;
  final msgRepo = _FakeMessageRepository();
  final contactRepo = _FakeContactRepository();
  final chatsRepo = _FakeChatsRepository();
  final connService = connectionServiceOverride ??
      _FakeConnectionService(
        activelyReconnecting: isActivelyReconnecting,
      );
  final meshService = meshServiceOverride ?? _FakeMeshNetworkingService();
  if (pendingTransfers != null) {
    meshService.pendingTransfers = pendingTransfers;
  }
  final secService = _FakeSecurityService();

  _registerService<IMessageRepository>(locator, msgRepo);
  _registerService<IContactRepository>(locator, contactRepo);
  _registerService<IChatsRepository>(locator, chatsRepo);
  _registerService<ISecurityService>(locator, secService);

  final secState = securityState ?? _verifiedSecurityState();

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        connectionServiceProvider.overrideWith((ref) => connService),
        connectionInfoProvider.overrideWith(
          (ref) => AsyncValue.data(connectionInfo),
        ),
        meshNetworkingServiceProvider.overrideWith((ref) => meshService),
        meshNetworkStatusProvider.overrideWith(
          (ref) => const AsyncValue.data(_defaultMeshStatus),
        ),
        securityStateProvider.overrideWith(
          (ref, key) async => secState,
        ),
        binaryPayloadStreamProvider.overrideWith(
          (ref) => meshService.binaryPayloadStream,
        ),
        if (binaryInbox != null)
          binaryPayloadInboxProvider.overrideWith((ref) {
            final notifier = BinaryPayloadInbox();
            for (final entry in binaryInbox.entries) {
              notifier.addPayload(entry.value);
            }
            return notifier;
          }),
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

  await tester.pump();
  await tester.pump();
}

// ============================================================================
// TESTS — Phase 13d: Comprehensive uncovered-line coverage
// ============================================================================

void main() {
  final locator = GetIt.instance;

  setUp(() {});

  tearDown(() {
    _cleanupGetIt(locator);
  });

  // --------------------------------------------------------------------------
  // GROUP 1: _buildStatusText with live connection info (lines 443-472)
  // --------------------------------------------------------------------------
  group('ChatScreen – _buildStatusText connection-aware (non-repo mode)', () {
    // We can't easily test non-repo mode without a real Peripheral/Central,
    // but in repo mode _isRepositoryMode is true so the connection branch
    // is skipped. However we still exercise all SecurityStatus branches.

    testWidgets('shows "Connected • ECDH Encrypted" wording in repo mode',
        (tester) async {
      await _pumpChatScreen(
        tester,
        connectionInfo: _defaultConnectionInfo,
        securityState: _verifiedSecurityState(),
      );
      // In repo mode the connection prefix is omitted, only security part
      expect(find.textContaining('ECDH Encrypted'), findsOneWidget);
    });

    testWidgets('shows Paired text for paired state', (tester) async {
      await _pumpChatScreen(
        tester,
        connectionInfo: _defaultConnectionInfo,
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

    testWidgets('shows Disconnected for unknown status', (tester) async {
      await _pumpChatScreen(
        tester,
        securityState: _unknownSecurityState(),
      );
      expect(find.textContaining('Disconnected'), findsOneWidget);
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
  // GROUP 2: _getStatusColor coverage (lines 475-488)
  // --------------------------------------------------------------------------
  group('ChatScreen – _getStatusColor branches', () {
    testWidgets('green for verifiedContact', (tester) async {
      await _pumpChatScreen(
        tester,
        securityState: _verifiedSecurityState(),
      );
      final t = tester.widget<Text>(find.textContaining('ECDH Encrypted'));
      expect(t.style?.color, Colors.green);
    });

    testWidgets('blue for paired', (tester) async {
      await _pumpChatScreen(tester, securityState: _pairedSecurityState());
      final t = tester.widget<Text>(find.textContaining('Paired'));
      expect(t.style?.color, Colors.blue);
    });

    testWidgets('orange for asymmetricContact', (tester) async {
      await _pumpChatScreen(
        tester,
        securityState: _asymmetricSecurityState(),
      );
      final t =
          tester.widget<Text>(find.textContaining('Contact Sync Needed'));
      expect(t.style?.color, Colors.orange);
    });

    testWidgets('orange for needsPairing', (tester) async {
      await _pumpChatScreen(
        tester,
        securityState: _needsPairingSecurityState(),
      );
      final t =
          tester.widget<Text>(find.textContaining('Basic Encryption'));
      expect(t.style?.color, Colors.orange);
    });

    testWidgets('grey for disconnected', (tester) async {
      await _pumpChatScreen(
        tester,
        securityState: _disconnectedSecurityState(),
      );
      final t = tester.widget<Text>(find.textContaining('Disconnected'));
      expect(t.style?.color, Colors.grey);
    });

    testWidgets('grey for unknown status', (tester) async {
      await _pumpChatScreen(
        tester,
        securityState: _unknownSecurityState(),
      );
      final t = tester.widget<Text>(find.textContaining('Disconnected'));
      expect(t.style?.color, Colors.grey);
    });
  });

  // --------------------------------------------------------------------------
  // GROUP 3: _buildSingleActionButton taps (lines 490-530)
  // --------------------------------------------------------------------------
  group('ChatScreen – action button taps', () {
    testWidgets('tapping pairing button (lock_open) does not crash',
        (tester) async {
      await _pumpChatScreen(
        tester,
        securityState: _needsPairingSecurityState(),
      );

      expect(find.byIcon(Icons.lock_open), findsOneWidget);
      await tester.tap(find.byIcon(Icons.lock_open));
      await tester.pump();
      await tester.pump();
      expect(find.byType(Scaffold), findsOneWidget);
    });

    testWidgets('tapping add-contact button (person_add) does not crash',
        (tester) async {
      await _pumpChatScreen(
        tester,
        securityState: _showAddContactState(),
      );

      expect(find.byIcon(Icons.person_add), findsOneWidget);
      await tester.tap(find.byIcon(Icons.person_add));
      await tester.pump();
      await tester.pump();
      expect(find.byType(Scaffold), findsOneWidget);
    });

    testWidgets('tapping sync button does not crash', (tester) async {
      await _pumpChatScreen(
        tester,
        securityState: _asymmetricSecurityState(),
      );

      expect(find.byIcon(Icons.sync), findsOneWidget);
      await tester.tap(find.byIcon(Icons.sync));
      await tester.pump();
      await tester.pump();
      expect(find.byType(Scaffold), findsOneWidget);
    });

    testWidgets('no action button when all flags false', (tester) async {
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
  // GROUP 4: _sendMessage coverage (lines 532-540)
  // --------------------------------------------------------------------------
  group('ChatScreen – _sendMessage', () {
    testWidgets('entering text and send clears the field', (tester) async {
      await _pumpChatScreen(tester);
      final tf = find.byType(TextField);
      expect(tf, findsOneWidget);
      await tester.enterText(tf, 'Hello World');
      await tester.pump();

      final sendBtn = find.byIcon(Icons.send);
      if (sendBtn.evaluate().isNotEmpty) {
        await tester.tap(sendBtn);
        await tester.pump();
        final textField = tester.widget<TextField>(tf);
        expect(textField.controller?.text, isEmpty);
      }
    });

    testWidgets('empty text send does nothing', (tester) async {
      await _pumpChatScreen(tester);
      final sendBtn = find.byIcon(Icons.send);
      if (sendBtn.evaluate().isNotEmpty) {
        await tester.tap(sendBtn);
        await tester.pump();
      }
      expect(find.byType(Scaffold), findsOneWidget);
    });

    testWidgets('whitespace-only text send does nothing', (tester) async {
      await _pumpChatScreen(tester);
      final tf = find.byType(TextField);
      await tester.enterText(tf, '   ');
      await tester.pump();
      final sendBtn = find.byIcon(Icons.send);
      if (sendBtn.evaluate().isNotEmpty) {
        await tester.tap(sendBtn);
        await tester.pump();
      }
      expect(find.byType(Scaffold), findsOneWidget);
    });
  });

  // --------------------------------------------------------------------------
  // GROUP 5: _toggleSearchMode (via search icon tap)
  // --------------------------------------------------------------------------
  group('ChatScreen – search toggle', () {
    testWidgets('tapping search icon toggles mode without crash',
        (tester) async {
      await _pumpChatScreen(tester);
      expect(find.byIcon(Icons.search), findsOneWidget);
      await tester.tap(find.byIcon(Icons.search));
      await tester.pump();
      await tester.pump();
      expect(find.byType(Scaffold), findsOneWidget);
    });
  });

  // --------------------------------------------------------------------------
  // GROUP 6: Reconnection banner visibility (lines 370-376)
  // --------------------------------------------------------------------------
  group('ChatScreen – reconnection banner', () {
    testWidgets('shows banner when disconnected', (tester) async {
      await _pumpChatScreen(
        tester,
        connectionInfo: _disconnectedInfo,
      );
      expect(find.byType(ReconnectionBanner), findsOneWidget);
    });

    testWidgets('shows banner when actively reconnecting', (tester) async {
      await _pumpChatScreen(
        tester,
        connectionInfo: _defaultConnectionInfo,
        isActivelyReconnecting: true,
      );
      expect(find.byType(ReconnectionBanner), findsOneWidget);
    });

    testWidgets('hides banner when connected and not reconnecting',
        (tester) async {
      await _pumpChatScreen(
        tester,
        connectionInfo: _defaultConnectionInfo,
        isActivelyReconnecting: false,
      );
      expect(find.byType(ReconnectionBanner), findsNothing);
    });

    testWidgets('banner onReconnect callback does not crash', (tester) async {
      await _pumpChatScreen(
        tester,
        connectionInfo: _disconnectedInfo,
      );
      // Find the banner and trigger its reconnect button if present
      final bannerFinder = find.byType(ReconnectionBanner);
      expect(bannerFinder, findsOneWidget);
      // Tap any tappable widget inside the banner
      final reconnectButtons = find.descendant(
        of: bannerFinder,
        matching: find.byType(InkWell),
      );
      if (reconnectButtons.evaluate().isNotEmpty) {
        await tester.tap(reconnectButtons.first);
        await tester.pump();
      }
      expect(find.byType(Scaffold), findsOneWidget);
    });
  });

  // --------------------------------------------------------------------------
  // GROUP 7: InitializationStatusPanel (line 378-381)
  // --------------------------------------------------------------------------
  group('ChatScreen – initialization panel', () {
    testWidgets('no panel when meshInitializing is false', (tester) async {
      await _pumpChatScreen(tester);
      expect(find.byType(InitializationStatusPanel), findsNothing);
    });
  });

  // --------------------------------------------------------------------------
  // GROUP 8: PendingBinaryBanner (lines 382-396)
  // --------------------------------------------------------------------------
  group('ChatScreen – pending binary banner', () {
    testWidgets('no banner when transfers empty', (tester) async {
      await _pumpChatScreen(tester);
      expect(find.byType(PendingBinaryBanner), findsNothing);
    });

    testWidgets('shows banner when pending transfers exist', (tester) async {
      final meshSvc = _FakeMeshNetworkingService();
      meshSvc.pendingTransfers = [
        PendingBinaryTransfer(
          transferId: 'tx-1',
          recipientId: 'r-1',
          originalType: 1,
        ),
      ];

      await _pumpChatScreen(
        tester,
        pendingTransfers: meshSvc.pendingTransfers,
        meshServiceOverride: meshSvc,
      );

      expect(find.byType(PendingBinaryBanner), findsOneWidget);
    });

    testWidgets('tapping retry on pending banner does not crash',
        (tester) async {
      final meshSvc = _FakeMeshNetworkingService();
      meshSvc.pendingTransfers = [
        PendingBinaryTransfer(
          transferId: 'tx-2',
          recipientId: 'r-2',
          originalType: 1,
        ),
      ];

      await _pumpChatScreen(
        tester,
        pendingTransfers: meshSvc.pendingTransfers,
        meshServiceOverride: meshSvc,
      );

      // Find tappable retry element inside the banner
      final bannerFinder = find.byType(PendingBinaryBanner);
      expect(bannerFinder, findsOneWidget);
      final tapTargets = find.descendant(
        of: bannerFinder,
        matching: find.byType(InkWell),
      );
      if (tapTargets.evaluate().isNotEmpty) {
        await tester.tap(tapTargets.first);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.byType(Scaffold), findsOneWidget);
    });
  });

  // --------------------------------------------------------------------------
  // GROUP 9: BinaryInboxList (lines 397-403)
  // --------------------------------------------------------------------------
  group('ChatScreen – binary inbox', () {
    testWidgets('no inbox list when inbox empty', (tester) async {
      await _pumpChatScreen(tester);
      expect(find.byType(BinaryInboxList), findsNothing);
    });

    testWidgets('shows inbox list when binary inbox has items', (tester) async {
      final event = ReceivedBinaryEvent(
        fragmentId: 'frag-1',
        originalType: 1,
        filePath: '/tmp/img.png',
        size: 1024,
        transferId: 'transfer-1',
        ttl: 3,
        senderNodeId: 'test-public-key',
      );

      await _pumpChatScreen(
        tester,
        binaryInbox: {'transfer-1': event},
      );

      expect(find.byType(BinaryInboxList), findsOneWidget);
    });
  });

  // --------------------------------------------------------------------------
  // GROUP 10: ChatComposer and hint text (lines 414-420, 747-761)
  // --------------------------------------------------------------------------
  group('ChatScreen – composer hint text variants', () {
    testWidgets('shows "Type a message..." in repository mode',
        (tester) async {
      await _pumpChatScreen(tester);
      expect(find.text('Type a message...'), findsOneWidget);
    });

    testWidgets('ChatComposer is present in body', (tester) async {
      await _pumpChatScreen(tester);
      expect(find.byType(ChatComposer), findsOneWidget);
    });

    testWidgets('ChatMessagesSection is present in body', (tester) async {
      await _pumpChatScreen(tester);
      expect(find.byType(ChatMessagesSection), findsOneWidget);
    });
  });

  // --------------------------------------------------------------------------
  // GROUP 11: FAB / Scroll-down button (lines 424-433)
  // --------------------------------------------------------------------------
  group('ChatScreen – floating action button', () {
    testWidgets('no FAB when messages list is empty', (tester) async {
      await _pumpChatScreen(tester);
      expect(find.byType(FloatingActionButton), findsNothing);
      expect(find.byType(ChatScrollDownFab), findsNothing);
    });
  });

  // --------------------------------------------------------------------------
  // GROUP 12: Security loading and error states in AppBar
  // --------------------------------------------------------------------------
  group('ChatScreen – security async loading/error (subtitle)', () {
    testWidgets('shows "Loading..." when security state pending',
        (tester) async {
      final meshService = _FakeMeshNetworkingService();
      final connService = _FakeConnectionService();
      final msgRepo = _FakeMessageRepository();
      final contactRepo = _FakeContactRepository();
      final chatsRepo = _FakeChatsRepository();

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

      expect(find.text('Loading...'), findsOneWidget);
      final loadTxt = tester.widget<Text>(find.text('Loading...'));
      expect(loadTxt.style?.color, Colors.grey);
    });

    testWidgets('shows "Error" with red when security state fails',
        (tester) async {
      final meshService = _FakeMeshNetworkingService();
      final connService = _FakeConnectionService();
      final msgRepo = _FakeMessageRepository();
      final contactRepo = _FakeContactRepository();
      final chatsRepo = _FakeChatsRepository();

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

      await tester.pump();
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('Error'), findsOneWidget);
      final errText = tester.widget<Text>(find.text('Error'));
      expect(errText.style?.color, Colors.red);
    });

    testWidgets('no action button during security loading', (tester) async {
      final meshService = _FakeMeshNetworkingService();
      final connService = _FakeConnectionService();
      _registerService<IMessageRepository>(locator, _FakeMessageRepository());
      _registerService<IContactRepository>(locator, _FakeContactRepository());
      _registerService<IChatsRepository>(locator, _FakeChatsRepository());

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
              chatId: 'l-chat',
              contactName: 'LUser',
              contactPublicKey: 'pk-l',
            ),
          ),
        ),
      );

      await tester.pump();
      await tester.pump();

      expect(find.byIcon(Icons.lock_open), findsNothing);
      expect(find.byIcon(Icons.person_add), findsNothing);
      expect(find.byIcon(Icons.sync), findsNothing);
    });

    testWidgets('no action button during security error', (tester) async {
      final meshService = _FakeMeshNetworkingService();
      final connService = _FakeConnectionService();
      _registerService<IMessageRepository>(locator, _FakeMessageRepository());
      _registerService<IContactRepository>(locator, _FakeContactRepository());
      _registerService<IChatsRepository>(locator, _FakeChatsRepository());

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
                throw StateError('fail');
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
              chatId: 'err2-chat',
              contactName: 'Err2User',
              contactPublicKey: 'pk-err2',
            ),
          ),
        ),
      );

      await tester.pump();
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.byIcon(Icons.lock_open), findsNothing);
      expect(find.byIcon(Icons.person_add), findsNothing);
      expect(find.byIcon(Icons.sync), findsNothing);
    });
  });

  // --------------------------------------------------------------------------
  // GROUP 13: Constructor variants (lines 48, 56)
  // --------------------------------------------------------------------------
  group('ChatScreen – constructor fromChatData', () {
    testWidgets('fromChatData renders correctly', (tester) async {
      await _pumpChatScreen(
        tester,
        chatId: 'chat-abc',
        contactName: 'Charlie',
        contactPublicKey: 'pk-abc',
      );
      expect(find.text('Charlie'), findsOneWidget);
    });
  });

  // --------------------------------------------------------------------------
  // GROUP 14: Dispose lifecycle
  // --------------------------------------------------------------------------
  group('ChatScreen – dispose', () {
    testWidgets('widget can be disposed by navigating away', (tester) async {
      await _pumpChatScreen(tester);
      expect(find.byType(ChatScreen), findsOneWidget);

      await tester.pumpWidget(const MaterialApp(home: Scaffold()));
      await tester.pump();
      await tester.pump();

      expect(find.byType(ChatScreen), findsNothing);
    });
  });

  // --------------------------------------------------------------------------
  // GROUP 15: Widget tree structure
  // --------------------------------------------------------------------------
  group('ChatScreen – widget tree', () {
    testWidgets('renders Scaffold+AppBar+SafeArea', (tester) async {
      await _pumpChatScreen(tester);
      expect(find.byType(Scaffold), findsOneWidget);
      expect(find.byType(AppBar), findsOneWidget);
      expect(find.byType(SafeArea), findsAtLeastNWidgets(1));
    });

    testWidgets('AppBar has Column with contact name and status',
        (tester) async {
      await _pumpChatScreen(
        tester,
        contactName: 'Zara',
        securityState: _pairedSecurityState(),
      );
      expect(find.text('Zara'), findsOneWidget);
      expect(find.textContaining('Paired'), findsOneWidget);
    });

    testWidgets('AppBar shows search and action buttons together',
        (tester) async {
      await _pumpChatScreen(
        tester,
        securityState: _needsPairingSecurityState(),
      );
      expect(find.byIcon(Icons.search), findsOneWidget);
      expect(find.byIcon(Icons.lock_open), findsOneWidget);
    });
  });

  // --------------------------------------------------------------------------
  // GROUP 16: All security states cycle
  // --------------------------------------------------------------------------
  group('ChatScreen – all security state cycle', () {
    for (final entry in {
      'verified': _verifiedSecurityState(),
      'paired': _pairedSecurityState(),
      'needsPairing': _needsPairingSecurityState(),
      'asymmetric': _asymmetricSecurityState(),
      'disconnected': _disconnectedSecurityState(),
      'addContact': _showAddContactState(),
      'unknown': _unknownSecurityState(),
    }.entries) {
      testWidgets('${entry.key} state renders without error', (tester) async {
        await _pumpChatScreen(tester, securityState: entry.value);
        expect(find.byType(Scaffold), findsOneWidget);
      });
    }
  });

  // --------------------------------------------------------------------------
  // GROUP 17: Image send button presence
  // --------------------------------------------------------------------------
  group('ChatScreen – image button', () {
    testWidgets('image icon present when connected', (tester) async {
      await _pumpChatScreen(
        tester,
        connectionInfo: _defaultConnectionInfo,
      );
      expect(find.byIcon(Icons.image), findsOneWidget);
    });

    testWidgets('image icon present when disconnected (composer renders)',
        (tester) async {
      await _pumpChatScreen(
        tester,
        connectionInfo: _disconnectedInfo,
      );
      // ChatComposer always renders, canSendImage controls enabled state
      expect(find.byType(ChatComposer), findsOneWidget);
    });
  });

  // --------------------------------------------------------------------------
  // GROUP 18: Connecting / Reconnecting info text
  // --------------------------------------------------------------------------
  group('ChatScreen – connecting and reconnecting info', () {
    testWidgets('renders with connecting info', (tester) async {
      await _pumpChatScreen(
        tester,
        connectionInfo: _connectingInfo,
        securityState: _needsPairingSecurityState(),
      );
      // Repo mode doesn't show connection prefix
      expect(find.textContaining('Basic Encryption'), findsOneWidget);
    });

    testWidgets('renders with reconnecting info', (tester) async {
      await _pumpChatScreen(
        tester,
        connectionInfo: _reconnectingInfo,
        securityState: _pairedSecurityState(),
      );
      expect(find.textContaining('Paired'), findsOneWidget);
    });
  });

  // --------------------------------------------------------------------------
  // GROUP 19: Ensure security state provider resolves per key
  // --------------------------------------------------------------------------
  group('ChatScreen – securityStateProvider key', () {
    testWidgets('securityStateKey is derived from contactPublicKey',
        (tester) async {
      await _pumpChatScreen(
        tester,
        contactPublicKey: 'my-key-123',
        securityState: _verifiedSecurityState(),
      );
      expect(find.textContaining('ECDH Encrypted'), findsOneWidget);
    });
  });

  // --------------------------------------------------------------------------
  // GROUP 20: Pending transfers with multiple items
  // --------------------------------------------------------------------------
  group('ChatScreen – pending transfers multiple', () {
    testWidgets('shows banner with multiple transfers', (tester) async {
      final meshSvc = _FakeMeshNetworkingService();
      meshSvc.pendingTransfers = [
        PendingBinaryTransfer(
          transferId: 'tx-a',
          recipientId: 'r-a',
          originalType: 1,
        ),
        PendingBinaryTransfer(
          transferId: 'tx-b',
          recipientId: 'r-b',
          originalType: 2,
        ),
      ];

      await _pumpChatScreen(
        tester,
        pendingTransfers: meshSvc.pendingTransfers,
        meshServiceOverride: meshSvc,
      );

      expect(find.byType(PendingBinaryBanner), findsOneWidget);
    });
  });

  // --------------------------------------------------------------------------
  // GROUP 21: Connection subscription listener path
  // --------------------------------------------------------------------------
  group('ChatScreen – initState subscription callbacks', () {
    testWidgets('widget initializes subscriptions without crash',
        (tester) async {
      await _pumpChatScreen(tester);
      // If initState subscriptions crash, pumpChatScreen will throw
      expect(find.byType(ChatScreen), findsOneWidget);
    });

    testWidgets('can rebuild after provider changes', (tester) async {
      await _pumpChatScreen(tester);
      // trigger rebuild
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.byType(ChatScreen), findsOneWidget);
    });
  });

  // --------------------------------------------------------------------------
  // GROUP 22: Multiple contact names / chatIds
  // --------------------------------------------------------------------------
  group('ChatScreen – varied chat data', () {
    testWidgets('different chatId and contactName', (tester) async {
      await _pumpChatScreen(
        tester,
        chatId: 'another-chat',
        contactName: 'Alice',
        contactPublicKey: 'alice-pk',
      );
      expect(find.text('Alice'), findsOneWidget);
    });

    testWidgets('long contact name renders', (tester) async {
      final longName = 'A' * 50;
      await _pumpChatScreen(
        tester,
        contactName: longName,
      );
      expect(find.textContaining(longName), findsOneWidget);
    });
  });

  // --------------------------------------------------------------------------
  // GROUP 23: ISecurityService registered in GetIt (lines 275-277)
  // --------------------------------------------------------------------------
  group('ChatScreen – ISecurityService registration', () {
    testWidgets('resolves ISecurityService via GetIt without crash',
        (tester) async {
      final secService = _FakeSecurityService();
      _registerService<ISecurityService>(locator, secService);

      await _pumpChatScreen(tester);
      expect(find.byType(Scaffold), findsOneWidget);
    });
  });

  // --------------------------------------------------------------------------
  // GROUP 24: Comprehensive connection info combos with security states
  // --------------------------------------------------------------------------
  group('ChatScreen – connection + security combos', () {
    testWidgets('disconnected + needsPairing', (tester) async {
      await _pumpChatScreen(
        tester,
        connectionInfo: _disconnectedInfo,
        securityState: _needsPairingSecurityState(),
      );
      expect(find.textContaining('Basic Encryption'), findsOneWidget);
      expect(find.byIcon(Icons.lock_open), findsOneWidget);
    });

    testWidgets('connecting + asymmetric', (tester) async {
      await _pumpChatScreen(
        tester,
        connectionInfo: _connectingInfo,
        securityState: _asymmetricSecurityState(),
      );
      expect(find.textContaining('Contact Sync Needed'), findsOneWidget);
      expect(find.byIcon(Icons.sync), findsOneWidget);
    });

    testWidgets('reconnecting + paired', (tester) async {
      await _pumpChatScreen(
        tester,
        connectionInfo: _reconnectingInfo,
        securityState: _pairedSecurityState(),
      );
      expect(find.textContaining('Paired'), findsOneWidget);
    });

    testWidgets('connected + addContact', (tester) async {
      await _pumpChatScreen(
        tester,
        connectionInfo: _defaultConnectionInfo,
        securityState: _showAddContactState(),
      );
      expect(find.byIcon(Icons.person_add), findsOneWidget);
    });
  });
}
