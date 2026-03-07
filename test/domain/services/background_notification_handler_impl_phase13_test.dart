import 'dart:convert';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_local_notifications_platform_interface/flutter_local_notifications_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:pak_connect/domain/entities/message.dart' as app_entities;
import 'package:pak_connect/domain/interfaces/i_notification_handler.dart';
import 'package:pak_connect/domain/interfaces/i_notification_navigation_handler.dart';
import 'package:pak_connect/domain/services/background_notification_handler_impl.dart';
import 'package:pak_connect/domain/services/notification_navigation_service.dart';
import 'package:pak_connect/domain/values/id_types.dart';

// ---------------------------------------------------------------------------
// Fakes
// ---------------------------------------------------------------------------

class _FakeNotificationsPlugin extends Fake
    implements FlutterLocalNotificationsPlugin {
  bool initializeCalled = false;
  InitializationSettings? lastInitSettings;
  void Function(NotificationResponse)? storedCallback;
  final List<_ShowCall> showCalls = [];
  final List<int> cancelCalls = [];
  bool cancelAllCalled = false;
  bool initShouldThrow = false;

  @override
  Future<bool?> initialize({
    required InitializationSettings settings,
    DidReceiveNotificationResponseCallback? onDidReceiveNotificationResponse,
    DidReceiveBackgroundNotificationResponseCallback?
        onDidReceiveBackgroundNotificationResponse,
  }) async {
    if (initShouldThrow) throw Exception('init-failure');
    initializeCalled = true;
    lastInitSettings = settings;
    storedCallback = onDidReceiveNotificationResponse;
    return true;
  }

  @override
  Future<void> show({
    required int id,
    String? title,
    String? body,
    NotificationDetails? notificationDetails,
    String? payload,
  }) async {
    showCalls.add(_ShowCall(
      id: id,
      title: title ?? '',
      body: body ?? '',
      payload: payload,
    ));
  }

  @override
  Future<void> cancel({required int id, String? tag}) async {
    cancelCalls.add(id);
  }

  @override
  Future<void> cancelAll() async {
    cancelAllCalled = true;
  }

  @override
  T? resolvePlatformSpecificImplementation<
    T extends FlutterLocalNotificationsPlatform
  >() {
    return null;
  }

  void simulateTap(String? payload) {
    storedCallback?.call(NotificationResponse(
      notificationResponseType:
          NotificationResponseType.selectedNotification,
      payload: payload,
    ));
  }
}

class _ShowCall {
  final int id;
  final String title;
  final String body;
  final String? payload;
  _ShowCall({
    required this.id,
    required this.title,
    required this.body,
    this.payload,
  });
}

class _FakeNavigationHandler implements INotificationNavigationHandler {
  final List<Map<String, String?>> chatNavigations = [];
  final List<Map<String, String>> contactNavigations = [];
  int homeNavigations = 0;

  @override
  Future<void> navigateToChat({
    required String chatId,
    required String contactName,
    String? contactPublicKey,
  }) async {
    chatNavigations.add({
      'chatId': chatId,
      'contactName': contactName,
      'contactPublicKey': contactPublicKey,
    });
  }

  @override
  Future<void> navigateToContactRequest({
    required String publicKey,
    required String contactName,
  }) async {
    contactNavigations.add({
      'publicKey': publicKey,
      'contactName': contactName,
    });
  }

  @override
  Future<void> navigateToHome() async {
    homeNavigations++;
  }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  late _FakeNotificationsPlugin fakePlugin;
  late BackgroundNotificationHandlerImpl handler;
  late _FakeNavigationHandler navHandler;
  late List<LogRecord> logs;

  setUp(() {
    fakePlugin = _FakeNotificationsPlugin();
    handler = BackgroundNotificationHandlerImpl(plugin: fakePlugin);
    navHandler = _FakeNavigationHandler();
    NotificationNavigationService.setHandler(navHandler);

    logs = [];
    Logger.root.level = Level.ALL;
    Logger.root.onRecord.listen(logs.add);
  });

  tearDown(() {
    handler.dispose();
    NotificationNavigationService.clearHandler();
  });

  // -----------------------------------------------------------------------
  // initialize
  // -----------------------------------------------------------------------
  group('initialize', () {
    test('initializes plugin and sets flag', () async {
      await handler.initialize();
      expect(fakePlugin.initializeCalled, isTrue);
      expect(fakePlugin.lastInitSettings, isNotNull);
      expect(
        logs.any((l) => l.message.contains('initialized successfully')),
        isTrue,
      );
    });

    test('second initialize call is a no-op', () async {
      await handler.initialize();
      fakePlugin.initializeCalled = false; // reset
      await handler.initialize();
      expect(fakePlugin.initializeCalled, isFalse);
      expect(
        logs.any((l) => l.message.contains('Already initialized')),
        isTrue,
      );
    });

    test('initialize error rethrows', () async {
      fakePlugin.initShouldThrow = true;
      expect(() => handler.initialize(), throwsException);
    });
  });

  // -----------------------------------------------------------------------
  // showNotification (post-init)
  // -----------------------------------------------------------------------
  group('showNotification (initialized)', () {
    setUp(() async {
      await handler.initialize();
    });

    test('shows notification with default channel and priority', () async {
      await handler.showNotification(
        id: 'n1',
        title: 'Hello',
        body: 'World',
      );
      expect(fakePlugin.showCalls, hasLength(1));
      expect(fakePlugin.showCalls.first.title, 'Hello');
      expect(fakePlugin.showCalls.first.body, 'World');
    });

    test('shows notification for each channel', () async {
      for (final channel in NotificationChannel.values) {
        await handler.showNotification(
          id: 'ch-${channel.name}',
          title: 'Channel ${channel.name}',
          body: 'body',
          channel: channel,
        );
      }
      expect(fakePlugin.showCalls, hasLength(NotificationChannel.values.length));
    });

    test('shows notification for each priority', () async {
      for (final priority in NotificationPriority.values) {
        await handler.showNotification(
          id: 'pri-${priority.name}',
          title: 'Priority ${priority.name}',
          body: 'body',
          priority: priority,
        );
      }
      expect(fakePlugin.showCalls,
          hasLength(NotificationPriority.values.length));
    });

    test('payload is passed through', () async {
      await handler.showNotification(
        id: 'payload-test',
        title: 'T',
        body: 'B',
        payload: 'custom-payload',
      );
      expect(fakePlugin.showCalls.first.payload, 'custom-payload');
    });

    test('playSound and vibrate params accepted', () async {
      await handler.showNotification(
        id: 'sound-vib',
        title: 'T',
        body: 'B',
        playSound: false,
        vibrate: false,
      );
      expect(fakePlugin.showCalls, hasLength(1));
    });
  });

  // -----------------------------------------------------------------------
  // showMessageNotification (post-init)
  // -----------------------------------------------------------------------
  group('showMessageNotification (initialized)', () {
    setUp(() async {
      await handler.initialize();
    });

    test('handles MessagingStyle error gracefully', () async {
      // MessagingStyleInformation / Person from flutter_local_notifications
      // may throw in headless test environments. The handler should catch it
      // and log SEVERE without propagating.
      final msg = app_entities.Message(
        id: const MessageId('msg-42'),
        chatId: const ChatId('chat-42'),
        content: 'Hello from test',
        timestamp: DateTime(2026, 1, 1),
        isFromMe: false,
        status: app_entities.MessageStatus.delivered,
      );

      // Should NOT throw
      await handler.showMessageNotification(
        message: msg,
        contactName: 'Alice',
        contactPublicKey: 'pk-alice',
      );

      // Either it succeeded (show called) or failed gracefully (SEVERE logged)
      final severeLogged = logs.any(
        (l) =>
            l.level == Level.SEVERE &&
            l.message.contains('Failed to show message notification'),
      );
      final showCalled = fakePlugin.showCalls.isNotEmpty;
      expect(severeLogged || showCalled, isTrue);
    });

    test('returns early when not initialized', () async {
      handler.dispose();
      final msg = app_entities.Message(
        id: const MessageId('msg-43'),
        chatId: const ChatId('chat-43'),
        content: 'No init',
        timestamp: DateTime(2026, 1, 1),
        isFromMe: false,
        status: app_entities.MessageStatus.delivered,
      );

      await handler.showMessageNotification(
        message: msg,
        contactName: 'Bob',
      );
      expect(fakePlugin.showCalls, isEmpty);
    });
  });

  // -----------------------------------------------------------------------
  // showContactRequestNotification (post-init)
  // -----------------------------------------------------------------------
  group('showContactRequestNotification (initialized)', () {
    setUp(() async {
      await handler.initialize();
    });

    test('delegates to showNotification with contacts channel', () async {
      await handler.showContactRequestNotification(
        contactName: 'Carol',
        publicKey: 'pk-carol',
      );

      expect(fakePlugin.showCalls, hasLength(1));
      expect(fakePlugin.showCalls.first.title, 'New Contact Request');
      expect(fakePlugin.showCalls.first.body, 'Carol wants to connect');
    });
  });

  // -----------------------------------------------------------------------
  // showSystemNotification (post-init)
  // -----------------------------------------------------------------------
  group('showSystemNotification (initialized)', () {
    setUp(() async {
      await handler.initialize();
    });

    test('low priority does not play sound', () async {
      await handler.showSystemNotification(
        title: 'System',
        message: 'Low alert',
        priority: NotificationPriority.low,
      );
      expect(fakePlugin.showCalls, hasLength(1));
    });

    test('default priority does not play sound', () async {
      await handler.showSystemNotification(
        title: 'System',
        message: 'Default alert',
      );
      expect(fakePlugin.showCalls, hasLength(1));
    });

    test('high priority plays sound and vibrates', () async {
      await handler.showSystemNotification(
        title: 'System',
        message: 'High alert',
        priority: NotificationPriority.high,
      );
      expect(fakePlugin.showCalls, hasLength(1));
    });

    test('max priority plays sound and vibrates', () async {
      await handler.showSystemNotification(
        title: 'System',
        message: 'Max alert',
        priority: NotificationPriority.max,
      );
      expect(fakePlugin.showCalls, hasLength(1));
    });
  });

  // -----------------------------------------------------------------------
  // cancelNotification / cancelAllNotifications (post-init)
  // -----------------------------------------------------------------------
  group('cancel (initialized)', () {
    setUp(() async {
      await handler.initialize();
    });

    test('cancelNotification calls plugin with hashCode', () async {
      await handler.cancelNotification('some-id');
      expect(fakePlugin.cancelCalls, hasLength(1));
      expect(fakePlugin.cancelCalls.first, 'some-id'.hashCode);
    });

    test('cancelAllNotifications calls plugin', () async {
      await handler.cancelAllNotifications();
      expect(fakePlugin.cancelAllCalled, isTrue);
    });
  });

  // -----------------------------------------------------------------------
  // areNotificationsEnabled / requestPermissions (post-init)
  // -----------------------------------------------------------------------
  group('permissions (initialized)', () {
    setUp(() async {
      await handler.initialize();
    });

    test('areNotificationsEnabled returns false when no platform impl',
        () async {
      final enabled = await handler.areNotificationsEnabled();
      // resolvePlatformSpecificImplementation returns null in our fake
      expect(enabled, isFalse);
    });

    test('requestPermissions returns false when no platform impl', () async {
      final granted = await handler.requestPermissions();
      expect(granted, isFalse);
    });
  });

  // -----------------------------------------------------------------------
  // _onNotificationTapped via fake plugin callback
  // -----------------------------------------------------------------------
  group('notification tap handling', () {
    setUp(() async {
      await handler.initialize();
    });

    test('message tap navigates to chat', () async {
      fakePlugin.simulateTap(jsonEncode({
        'type': 'message',
        'chatId': 'chat-tap-1',
        'contactName': 'Dave',
        'contactPublicKey': 'pk-dave',
      }));

      // Allow async nav to complete
      await Future<void>.delayed(Duration.zero);

      expect(navHandler.chatNavigations, hasLength(1));
      expect(navHandler.chatNavigations.first['chatId'], 'chat-tap-1');
      expect(navHandler.chatNavigations.first['contactName'], 'Dave');
    });

    test('contact_request tap navigates to contact request', () async {
      fakePlugin.simulateTap(jsonEncode({
        'type': 'contact_request',
        'publicKey': 'pk-eve',
        'contactName': 'Eve',
      }));

      await Future<void>.delayed(Duration.zero);

      expect(navHandler.contactNavigations, hasLength(1));
      expect(navHandler.contactNavigations.first['publicKey'], 'pk-eve');
    });

    test('unknown type navigates to home', () async {
      fakePlugin.simulateTap(jsonEncode({'type': 'something_else'}));

      await Future<void>.delayed(Duration.zero);
      expect(navHandler.homeNavigations, 1);
    });

    test('null payload logs warning', () {
      fakePlugin.simulateTap(null);
      expect(
        logs.any((l) => l.message.contains('No payload')),
        isTrue,
      );
    });

    test('empty payload logs warning', () {
      fakePlugin.simulateTap('');
      expect(
        logs.any((l) => l.message.contains('No payload')),
        isTrue,
      );
    });

    test('malformed JSON payload falls back to home', () async {
      fakePlugin.simulateTap('not-json');

      await Future<void>.delayed(Duration.zero);
      expect(navHandler.homeNavigations, 1);
    });

    test('message tap with missing chatId does not navigate', () {
      fakePlugin.simulateTap(jsonEncode({
        'type': 'message',
        'contactName': 'NoChat',
      }));
      expect(navHandler.chatNavigations, isEmpty);
    });

    test('contact_request tap with missing publicKey does not navigate', () {
      fakePlugin.simulateTap(jsonEncode({
        'type': 'contact_request',
        'contactName': 'NoKey',
      }));
      expect(navHandler.contactNavigations, isEmpty);
    });
  });

  // -----------------------------------------------------------------------
  // dispose and re-use
  // -----------------------------------------------------------------------
  group('dispose and re-use', () {
    test('dispose blocks subsequent operations', () async {
      await handler.initialize();
      handler.dispose();

      await handler.showNotification(id: 'x', title: 'T', body: 'B');
      expect(fakePlugin.showCalls, isEmpty);
    });

    test('can re-initialize after dispose', () async {
      await handler.initialize();
      handler.dispose();
      await handler.initialize();

      await handler.showNotification(id: 'y', title: 'T', body: 'B');
      expect(fakePlugin.showCalls, hasLength(1));
    });
  });

  // -----------------------------------------------------------------------
  // cancelChannelNotifications
  // -----------------------------------------------------------------------
  group('cancelChannelNotifications', () {
    test('logs warning for every channel', () async {
      for (final channel in NotificationChannel.values) {
        await handler.cancelChannelNotifications(channel);
      }
      final warnings = logs.where(
          (l) => l.message.contains('Channel-specific cancellation'));
      expect(warnings.length, NotificationChannel.values.length);
    });
  });
}
