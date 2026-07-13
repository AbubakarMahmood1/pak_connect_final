import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:pak_connect/data/services/panic_wipe_service.dart';
import 'package:pak_connect/domain/interfaces/i_panic_wipe_service.dart';

void main() {
  group('PanicWipeService', () {
    test(
      'successful wipe executes teardown and reinitialize steps in order',
      () async {
        final calls = <String>[];
        final service = PanicWipeService(
          disposeAppCore: () async => calls.add('disposeAppCore'),
          shutdownSecurityManager: () async =>
              calls.add('shutdownSecurityManager'),
          clearConversationKeys: () async => calls.add('clearConversationKeys'),
          clearReplayProtectionState: () async =>
              calls.add('clearReplayProtectionState'),
          clearHintCache: () async => calls.add('clearHintCache'),
          closeDatabase: () async => calls.add('closeDatabase'),
          deleteDatabase: () async => calls.add('deleteDatabase'),
          databaseExists: () async {
            calls.add('databaseExists');
            return false;
          },
          deleteEncryptionKey: () async => calls.add('deleteEncryptionKey'),
          hasEncryptionKey: () async {
            calls.add('hasEncryptionKey');
            return false;
          },
          deleteSecureStorage: () async => calls.add('deleteSecureStorage'),
          clearSharedPreferences: () async =>
              calls.add('clearSharedPreferences'),
          resetAppCoreSingleton: () async => calls.add('resetAppCoreSingleton'),
          initializeAppCore: () async => calls.add('initializeAppCore'),
        );

        final result = await service.execute(origin: PanicWipeOrigin.settings);

        expect(result.success, isTrue);
        expect(result.failures, isEmpty);
        expect(calls, <String>[
          'disposeAppCore',
          'shutdownSecurityManager',
          'clearConversationKeys',
          'clearReplayProtectionState',
          'clearHintCache',
          'closeDatabase',
          'deleteDatabase',
          'databaseExists',
          'deleteEncryptionKey',
          'hasEncryptionKey',
          'deleteSecureStorage',
          'clearSharedPreferences',
          'resetAppCoreSingleton',
          'initializeAppCore',
        ]);
      },
    );

    test(
      'failure in one step still runs remaining cleanup and returns failure',
      () async {
        final calls = <String>[];
        final service = PanicWipeService(
          disposeAppCore: () async => calls.add('disposeAppCore'),
          shutdownSecurityManager: () async =>
              calls.add('shutdownSecurityManager'),
          clearConversationKeys: () async => calls.add('clearConversationKeys'),
          clearReplayProtectionState: () async =>
              calls.add('clearReplayProtectionState'),
          clearHintCache: () async => calls.add('clearHintCache'),
          closeDatabase: () async => calls.add('closeDatabase'),
          deleteDatabase: () async {
            calls.add('deleteDatabase');
            throw StateError('boom');
          },
          databaseExists: () async {
            calls.add('databaseExists');
            return false;
          },
          deleteEncryptionKey: () async => calls.add('deleteEncryptionKey'),
          hasEncryptionKey: () async {
            calls.add('hasEncryptionKey');
            return false;
          },
          deleteSecureStorage: () async => calls.add('deleteSecureStorage'),
          clearSharedPreferences: () async =>
              calls.add('clearSharedPreferences'),
          resetAppCoreSingleton: () async => calls.add('resetAppCoreSingleton'),
          initializeAppCore: () async => calls.add('initializeAppCore'),
        );

        final result = await service.execute(
          origin: PanicWipeOrigin.hiddenAboutVersion,
        );

        expect(result.success, isFalse);
        expect(result.failures.single, contains('delete database file failed'));
        expect(
          calls,
          containsAllInOrder(<String>[
            'deleteDatabase',
            'deleteEncryptionKey',
            'deleteSecureStorage',
            'clearSharedPreferences',
            'resetAppCoreSingleton',
            'initializeAppCore',
          ]),
        );
      },
    );

    test('concurrent execution returns already-in-progress failure', () async {
      final gate = Completer<void>();
      final calls = <String>[];
      final service = PanicWipeService(
        disposeAppCore: () async {
          calls.add('disposeAppCore');
          await gate.future;
        },
        shutdownSecurityManager: () async =>
            calls.add('shutdownSecurityManager'),
        clearConversationKeys: () async => calls.add('clearConversationKeys'),
        clearReplayProtectionState: () async =>
            calls.add('clearReplayProtectionState'),
        clearHintCache: () async => calls.add('clearHintCache'),
        closeDatabase: () async => calls.add('closeDatabase'),
        deleteDatabase: () async => calls.add('deleteDatabase'),
        databaseExists: () async => false,
        deleteEncryptionKey: () async => calls.add('deleteEncryptionKey'),
        hasEncryptionKey: () async => false,
        deleteSecureStorage: () async => calls.add('deleteSecureStorage'),
        clearSharedPreferences: () async => calls.add('clearSharedPreferences'),
        resetAppCoreSingleton: () async => calls.add('resetAppCoreSingleton'),
        initializeAppCore: () async => calls.add('initializeAppCore'),
      );

      final firstRun = service.execute(origin: PanicWipeOrigin.settings);
      final secondRun = await service.execute(
        origin: PanicWipeOrigin.hiddenAboutVersion,
      );

      expect(secondRun.success, isFalse);
      expect(secondRun.failures, contains('panic wipe already in progress'));

      gate.complete();
      final firstResult = await firstRun;
      expect(firstResult.success, isTrue);
      expect(calls.first, 'disposeAppCore');
    });
  });
}
