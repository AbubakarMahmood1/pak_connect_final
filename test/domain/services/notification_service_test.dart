import 'package:flutter_test/flutter_test.dart';
import 'package:pak_connect/domain/entities/message.dart';
import 'package:pak_connect/domain/entities/preference_keys.dart';
import 'package:pak_connect/domain/interfaces/i_notification_handler.dart';
import 'package:pak_connect/domain/interfaces/i_preferences_repository.dart';
import 'package:pak_connect/domain/services/notification_service.dart';
import 'package:pak_connect/domain/values/id_types.dart';

void main() {
  group('ForegroundNotificationHandler', () {
    test('initializes idempotently and honors preference gates', () async {
      final prefs = _MemoryPreferencesRepository(<String, dynamic>{
        PreferenceKeys.notificationsEnabled: true,
        PreferenceKeys.soundEnabled: false,
        PreferenceKeys.vibrationEnabled: false,
      });
      final handler = ForegroundNotificationHandler(
        preferencesRepository: prefs,
      );

      await handler.initialize();
      await handler.initialize();

      await handler.showNotification(id: 'n1', title: 't', body: 'b');
      await handler.showMessageNotification(
        message: _message('msg-1'),
        contactName: 'Alice',
      );
      await handler.showContactRequestNotification(
        contactName: 'Bob',
        publicKey: 'pk',
      );
      await handler.showSystemNotification(title: 'sys', message: 'ok');
      await handler.cancelNotification('n1');
      await handler.cancelChannelNotifications(NotificationChannel.system);
      await handler.cancelAllNotifications();

      expect(await handler.areNotificationsEnabled(), isTrue);
      expect(await handler.requestPermissions(), isTrue);

      handler.dispose();
    });

    test('swallows sound and vibration errors from preferences', () async {
      final prefs = _ThrowingPreferencesRepository();
      final handler = ForegroundNotificationHandler(
        preferencesRepository: prefs,
      );

      await handler.initialize();
      await handler.showNotification(id: 'n2', title: 'title', body: 'body');
    });
  });

  group('NotificationService', () {
    setUp(() {
      NotificationService.dispose();
    });

    tearDown(() {
      NotificationService.dispose();
    });

    test('initialize stores handler once and supports swapping', () async {
      final handlerA = _FakeNotificationHandler();
      final handlerB = _FakeNotificationHandler();

      await NotificationService.initialize(handler: handlerA);
      await NotificationService.initialize(handler: _FakeNotificationHandler());

      expect(NotificationService.isInitialized, isTrue);
      expect(NotificationService.handler, same(handlerA));
      expect(handlerA.initializeCalls, 1);

      await NotificationService.swapHandler(handlerB);
      expect(handlerA.disposeCalls, 1);
      expect(handlerB.initializeCalls, 1);
      expect(NotificationService.handler, same(handlerB));
    });

    test('message and contact notifications respect enabled permission', () async {
      final handler = _FakeNotificationHandler()..notificationsEnabled = false;
      await NotificationService.initialize(handler: handler);

      await NotificationService.showMessageNotification(
        message: _message('msg-2'),
        contactName: 'Alice',
      );
      await NotificationService.showContactRequestNotification(
        contactName: 'Bob',
        publicKey: 'pk',
      );

      expect(handler.messageNotifications, isEmpty);
      expect(handler.contactNotifications, isEmpty);

      handler.notificationsEnabled = true;
      await NotificationService.showMessageNotification(
        message: _message('msg-3'),
        contactName: 'Carol',
      );
      await NotificationService.showContactRequestNotification(
        contactName: 'Dan',
        publicKey: 'pk2',
      );
      await NotificationService.showChatNotification(
        contactName: 'Eve',
        message: 'hi',
      );
      await NotificationService.showSystemNotification(
        title: 'System',
        message: 'message',
      );

      expect(handler.messageNotifications.length, 1);
      expect(handler.contactNotifications.length, 1);
      expect(handler.genericNotifications.length, greaterThanOrEqualTo(2));
    });

    test('supports test notifications cancel flow and permission checks', () async {
      final handler = _FakeNotificationHandler()..permissionResult = true;
      await NotificationService.initialize(handler: handler);

      await NotificationService.showTestNotification(
        title: 'T',
        body: 'B',
        playSound: false,
        vibrate: false,
      );
      await NotificationService.cancelNotification('abc');
      await NotificationService.cancelAllNotifications();

      final granted = await NotificationService.requestPermissions();
      final hasPermission = await NotificationService.hasPermission();

      expect(granted, isTrue);
      expect(hasPermission, isTrue);
      expect(handler.cancelAllCalls, 1);
      expect(handler.cancelledIds, contains('abc'));
    });

    test('handles uninitialized and failing handler paths safely', () async {
      await NotificationService.showMessageNotification(
        message: _message('msg-4'),
        contactName: 'NoInit',
      );
      await NotificationService.showTestNotification();
      await NotificationService.showContactRequestNotification(
        contactName: 'NoInit',
        publicKey: 'pk',
      );
      await NotificationService.showSystemNotification(
        title: 'NoInit',
        message: 'm',
      );
      await NotificationService.cancelNotification('x');
      await NotificationService.cancelAllNotifications();
      expect(await NotificationService.requestPermissions(), isFalse);
      expect(await NotificationService.hasPermission(), isFalse);

      final failing = _FakeNotificationHandler()
        ..throwOnShowMessage = true
        ..throwOnShowNotification = true
        ..throwOnShowContactRequest = true
        ..throwOnShowSystemNotification = true
        ..throwOnRequestPermissions = true
        ..notificationsEnabled = true;
      await NotificationService.initialize(handler: failing);

      await NotificationService.showMessageNotification(
        message: _message('msg-5'),
        contactName: 'Failing',
      );
      await NotificationService.showChatNotification(
        contactName: 'Failing',
        message: 'hello',
      );
      await NotificationService.showContactRequestNotification(
        contactName: 'Failing',
        publicKey: 'pk',
      );
      await NotificationService.showSystemNotification(
        title: 'Failing',
        message: 'm',
      );
      await NotificationService.showTestNotification();
      expect(await NotificationService.requestPermissions(), isFalse);
    });
  });
}

Message _message(String id) {
  return Message(
    id: MessageId(id),
    chatId: const ChatId('chat-1'),
    content: 'hello',
    timestamp: DateTime(2026, 1, 1),
    isFromMe: false,
    status: MessageStatus.sent,
  );
}

class _MemoryPreferencesRepository implements IPreferencesRepository {
  _MemoryPreferencesRepository([Map<String, dynamic>? values])
    : _values = <String, dynamic>{...?values};

  final Map<String, dynamic> _values;

  @override
  Future<void> clearAll() async => _values.clear();

  @override
  Future<void> delete(String key) async => _values.remove(key);

  @override
  Future<Map<String, dynamic>> getAll() async => Map<String, dynamic>.from(_values);

  @override
  Future<bool> getBool(String key, {bool? defaultValue}) async =>
      (_values[key] as bool?) ?? (defaultValue ?? false);

  @override
  Future<double> getDouble(String key, {double? defaultValue}) async =>
      (_values[key] as double?) ?? (defaultValue ?? 0.0);

  @override
  Future<int> getInt(String key, {int? defaultValue}) async =>
      (_values[key] as int?) ?? (defaultValue ?? 0);

  @override
  Future<String> getString(String key, {String? defaultValue}) async =>
      (_values[key] as String?) ?? (defaultValue ?? '');

  @override
  Future<void> setBool(String key, bool value) async {
    _values[key] = value;
  }

  @override
  Future<void> setDouble(String key, double value) async {
    _values[key] = value;
  }

  @override
  Future<void> setInt(String key, int value) async {
    _values[key] = value;
  }

  @override
  Future<void> setString(String key, String value) async {
    _values[key] = value;
  }
}

class _ThrowingPreferencesRepository extends _MemoryPreferencesRepository {
  @override
  Future<bool> getBool(String key, {bool? defaultValue}) {
    throw StateError('pref read failed for $key');
  }
}

class _FakeNotificationHandler implements INotificationHandler {
  int initializeCalls = 0;
  int disposeCalls = 0;
  int cancelAllCalls = 0;
  bool notificationsEnabled = true;
  bool permissionResult = false;
  bool throwOnShowNotification = false;
  bool throwOnShowMessage = false;
  bool throwOnShowContactRequest = false;
  bool throwOnShowSystemNotification = false;
  bool throwOnRequestPermissions = false;
  final List<String> cancelledIds = <String>[];
  final List<Map<String, dynamic>> genericNotifications = <Map<String, dynamic>>[];
  final List<Map<String, dynamic>> messageNotifications = <Map<String, dynamic>>[];
  final List<Map<String, dynamic>> contactNotifications = <Map<String, dynamic>>[];

  @override
  Future<bool> areNotificationsEnabled() async => notificationsEnabled;

  @override
  Future<void> cancelAllNotifications() async {
    cancelAllCalls++;
  }

  @override
  Future<void> cancelChannelNotifications(NotificationChannel channel) async {}

  @override
  Future<void> cancelNotification(String id) async {
    cancelledIds.add(id);
  }

  @override
  void dispose() {
    disposeCalls++;
  }

  @override
  Future<void> initialize() async {
    initializeCalls++;
  }

  @override
  Future<bool> requestPermissions() async {
    if (throwOnRequestPermissions) {
      throw StateError('permission failure');
    }
    return permissionResult;
  }

  @override
  Future<void> showContactRequestNotification({
    required String contactName,
    required String publicKey,
  }) async {
    if (throwOnShowContactRequest) {
      throw StateError('contact notification failure');
    }
    contactNotifications.add(<String, dynamic>{
      'contactName': contactName,
      'publicKey': publicKey,
    });
  }

  @override
  Future<void> showMessageNotification({
    required Message message,
    required String contactName,
    String? contactAvatar,
    String? contactPublicKey,
  }) async {
    if (throwOnShowMessage) {
      throw StateError('message notification failure');
    }
    messageNotifications.add(<String, dynamic>{
      'messageId': message.id.value,
      'contactName': contactName,
    });
  }

  @override
  Future<void> showNotification({
    required String id,
    required String title,
    required String body,
    NotificationChannel channel = NotificationChannel.messages,
    NotificationPriority priority = NotificationPriority.default_,
    String? payload,
    Map<String, dynamic>? data,
    bool playSound = true,
    bool vibrate = true,
  }) async {
    if (throwOnShowNotification) {
      throw StateError('generic notification failure');
    }
    genericNotifications.add(<String, dynamic>{
      'id': id,
      'title': title,
      'body': body,
      'channel': channel,
      'priority': priority,
      'playSound': playSound,
      'vibrate': vibrate,
    });
  }

  @override
  Future<void> showSystemNotification({
    required String title,
    required String message,
    NotificationPriority priority = NotificationPriority.default_,
  }) async {
    if (throwOnShowSystemNotification) {
      throw StateError('system notification failure');
    }
    genericNotifications.add(<String, dynamic>{
      'title': title,
      'message': message,
      'priority': priority,
    });
  }
}
