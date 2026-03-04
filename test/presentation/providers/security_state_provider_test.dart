import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pak_connect/domain/models/security_state.dart';
import 'package:pak_connect/presentation/providers/security_state_provider.dart';

void main() {
  setUp(() {
    clearSecurityStateCache();
  });

  tearDown(() {
    clearSecurityStateCache();
  });

  group('securityStateProvider helpers', () {
    test('helper providers map security state to convenience values', () async {
      const key = 'contact-key';
      final container = ProviderContainer(
        overrides: [
          securityStateProvider.overrideWith(
            (ref, _) async => SecurityState.paired(
              otherUserName: 'Peer',
              otherPublicKey: key,
            ),
          ),
        ],
      );
      addTearDown(container.dispose);

      await container.read(securityStateProvider(key).future);
      expect(container.read(canSendMessagesProvider(key)), isTrue);
      expect(
        container.read(recommendedActionProvider(key)),
        'Tap + to add contact for ECDH encryption',
      );
      expect(
        container.read(encryptionDescriptionProvider(key)),
        'Paired + Global Encryption',
      );
    });

    test('cache utility functions are safe to call repeatedly', () {
      expect(clearSecurityStateCache, returnsNormally);
      expect(() => invalidateSecurityStateCache('key-a'), returnsNormally);
      expect(clearSecurityStateCache, returnsNormally);
    });
  });
}
