import 'package:flutter_test/flutter_test.dart';
import 'package:pak_connect/domain/models/identity_session_state.dart';
import 'package:pak_connect/domain/models/protocol_message_type.dart';
import 'package:pak_connect/domain/values/id_types.dart';

void main() {
  group('IdentitySessionState', () {
    late IdentitySessionState state;

    setUp(() {
      state = IdentitySessionState();
    });

    test('setters keep typed and string ids synchronized', () {
      state.setTheirEphemeralId('ephemeral-1');
      expect(state.theirEphemeralId, 'ephemeral-1');
      expect(state.currentSessionId, 'ephemeral-1');
      expect(state.currentSessionUserId, const UserId('ephemeral-1'));

      state.setTheirPersistentKey('persistent-1');
      expect(state.theirPersistentKey, 'persistent-1');
      expect(state.theirPersistentUserId, const UserId('persistent-1'));
      expect(state.getRecipientId(), 'persistent-1');
      expect(state.getIdType(), 'persistent');
      expect(state.isPaired, isTrue);

      state.setTheirPersistentUserId(const UserId('persistent-2'));
      state.setTheirEphemeralUserId(const UserId('ephemeral-2'));
      state.setCurrentSessionUserId(const UserId('session-3'));
      expect(state.theirPersistentKey, 'persistent-2');
      expect(state.theirEphemeralId, 'ephemeral-2');
      expect(state.currentSessionId, 'session-3');
    });

    test('persistent associations map ephemeral keys and preserve session fallback', () {
      state.setCurrentSessionId('session-x');
      state.setPersistentAssociation(
        persistentKey: 'persistent-x',
        ephemeralId: 'ephemeral-x',
      );

      expect(state.getPersistentKeyFromEphemeral('ephemeral-x'), 'persistent-x');
      expect(state.getRecipientId(), 'persistent-x');

      state.setCurrentSessionId('session-only');
      state.theirPersistentKey = null;
      expect(state.getRecipientId(), 'session-only');

      state.setPersistentAssociationUser(
        persistentId: const UserId('persistent-y'),
        ephemeralId: const UserId('ephemeral-y'),
      );
      expect(state.getPersistentKeyFromEphemeral('ephemeral-y'), 'persistent-y');
    });

    test('clear and mapping operations honor preservePersistentId flag', () {
      state.setTheirPersistentKey('persistent-a');
      state.setTheirEphemeralId('ephemeral-a');
      state.rememberDisplayName('Alice');
      state.mapEphemeralToPersistent('ephemeral-a', 'persistent-a');

      state.clear(preservePersistentId: true);
      expect(state.theirPersistentKey, 'persistent-a');
      expect(state.currentSessionId, isNotNull);
      expect(state.lastKnownDisplayName, 'Alice');
      expect(state.theirEphemeralId, isNull);

      state.clearMappings();
      expect(state.ephemeralToPersistent, isEmpty);

      state.clear();
      expect(state.currentSessionId, isNull);
      expect(state.theirPersistentKey, isNull);
      expect(state.lastKnownDisplayName, isNull);
      expect(state.getIdType(), 'ephemeral');
      expect(state.getRecipientId(), isNull);
    });

    test('detectSpyMode emits callback only when hints are disabled', () async {
      state.setTheirEphemeralId('anon-ephemeral');

      Object? callbackValue;
      await state.detectSpyMode(
        persistentKey: 'pk',
        getContactDisplayName: (_) async => null,
        hintsEnabledFetcher: () async => false,
        onSpyModeDetected: (info) => callbackValue = info,
      );
      expect(callbackValue, isNull);

      await state.detectSpyMode(
        persistentKey: 'pk',
        getContactDisplayName: (_) async => 'Bob',
        hintsEnabledFetcher: () async => true,
        onSpyModeDetected: (info) => callbackValue = info,
      );
      expect(callbackValue, isNull);

      await state.detectSpyMode(
        persistentKey: 'pk',
        getContactDisplayName: (_) async => 'Bob',
        hintsEnabledFetcher: () async => false,
        onSpyModeDetected: (info) => callbackValue = info,
      );
      expect(callbackValue, isNotNull);
    });

    test('createRevealMessage validates prerequisites and signs challenge', () async {
      final noSession = await state.createRevealMessage(
        myPersistentKey: 'mine',
        sign: (_) => 'proof',
        nowMillis: () => 1000,
      );
      expect(noSession, isNull);

      state.setTheirEphemeralId('peer-ephemeral');
      final noProof = await state.createRevealMessage(
        myPersistentKey: 'mine',
        sign: (_) => '',
        nowMillis: () => 2000,
      );
      expect(noProof, isNull);

      final reveal = await state.createRevealMessage(
        myPersistentKey: 'mine',
        sign: (challenge) => challenge.endsWith('_3000') ? 'sig' : null,
        nowMillis: () => 3000,
      );

      expect(reveal, isNotNull);
      expect(reveal!.type, ProtocolMessageType.friendReveal);
      expect(reveal.payload['myPersistentKey'], 'mine');
      expect(reveal.payload['proof'], 'sig');
      expect(reveal.payload['timestamp'], 3000);
    });

    test('recoverDisplayName updates cached name only for non-empty results', () async {
      final noSession = await state.recoverDisplayName((_) async => 'ignored');
      expect(noSession, isNull);

      state.setCurrentSessionId('peer');
      final empty = await state.recoverDisplayName((_) async => '');
      expect(empty, '');
      expect(state.lastKnownDisplayName, isNull);

      final restored = await state.recoverDisplayName((_) async => 'Recovered');
      expect(restored, 'Recovered');
      expect(state.lastKnownDisplayName, 'Recovered');
    });
  });
}
