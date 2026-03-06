import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pak_connect/data/repositories/intro_hint_repository.dart';
import 'package:pak_connect/domain/entities/ephemeral_discovery_hint.dart';
import 'package:shared_preferences/shared_preferences.dart';

EphemeralDiscoveryHint _hint({
  required int seed,
  required String name,
  required Duration expiresIn,
  bool isActive = true,
}) {
  final bytes = Uint8List.fromList(
    List<int>.generate(8, (index) => seed + index),
  );
  final now = DateTime.now();
  return EphemeralDiscoveryHint(
    hintBytes: bytes,
    createdAt: now.subtract(const Duration(minutes: 1)),
    expiresAt: now.add(expiresIn),
    displayName: name,
    isActive: isActive,
  );
}

Map<String, dynamic> _serializableHintMap(EphemeralDiscoveryHint hint) {
  final map = hint.toMap();
  map['hint_bytes'] = (map['hint_bytes'] as Uint8List).toList();
  return map;
}

void main() {
  late IntroHintRepository repository;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    repository = IntroHintRepository();
  });

  group('getMyActiveHints and saveMyActiveHint', () {
    test('returns empty list when no hints exist', () async {
      final hints = await repository.getMyActiveHints();
      expect(hints, isEmpty);
    });

    test('stores most recent hints and trims to max of three', () async {
      final first = _hint(
        seed: 1,
        name: 'one',
        expiresIn: const Duration(days: 2),
      );
      final second = _hint(
        seed: 20,
        name: 'two',
        expiresIn: const Duration(days: 2),
      );
      final third = _hint(
        seed: 40,
        name: 'three',
        expiresIn: const Duration(days: 2),
      );
      final fourth = _hint(
        seed: 60,
        name: 'four',
        expiresIn: const Duration(days: 2),
      );

      await repository.saveMyActiveHint(first);
      await repository.saveMyActiveHint(second);
      await repository.saveMyActiveHint(third);
      await repository.saveMyActiveHint(fourth);

      final hints = await repository.getMyActiveHints();
      expect(hints, hasLength(3));
      expect(hints.first.hintId, fourth.hintId);
      expect(hints[1].hintId, third.hintId);
      expect(hints[2].hintId, second.hintId);
    });

    test('filters expired active hints and persists cleanup', () async {
      final active = _hint(
        seed: 5,
        name: 'active',
        expiresIn: const Duration(hours: 2),
      );
      final expired = _hint(
        seed: 15,
        name: 'expired',
        expiresIn: const Duration(hours: -1),
      );

      SharedPreferences.setMockInitialValues({
        'my_active_intro_hints': jsonEncode([
          _serializableHintMap(active),
          _serializableHintMap(expired),
        ]),
      });

      final hints = await repository.getMyActiveHints();
      expect(hints.map((h) => h.hintId), [active.hintId]);

      final prefs = await SharedPreferences.getInstance();
      final storedJson = prefs.getString('my_active_intro_hints');
      final storedList = jsonDecode(storedJson!) as List<dynamic>;
      expect(storedList, hasLength(1));
    });

    test('returns empty list when active hint payload is malformed', () async {
      SharedPreferences.setMockInitialValues({
        'my_active_intro_hints': '{not-json',
      });
      final hints = await repository.getMyActiveHints();
      expect(hints, isEmpty);
    });
  });

  group('scanned hint lifecycle', () {
    test(
      'filters expired and malformed scanned hints, then persists cleanup',
      () async {
        final active = _hint(
          seed: 101,
          name: 'active-scanned',
          expiresIn: const Duration(days: 1),
        );
        final expired = _hint(
          seed: 121,
          name: 'expired-scanned',
          expiresIn: const Duration(hours: -2),
        );

        SharedPreferences.setMockInitialValues({
          'scanned_intro_hints': jsonEncode({
            'active-key': _serializableHintMap(active),
            'expired-key': _serializableHintMap(expired),
            'broken-key': {'hint_bytes': 'invalid-shape'},
          }),
        });

        final hints = await repository.getScannedHints();
        expect(hints.keys, {'active-key'});
        expect(hints['active-key']!.hintId, active.hintId);

        final prefs = await SharedPreferences.getInstance();
        final storedJson = prefs.getString('scanned_intro_hints');
        final storedMap = jsonDecode(storedJson!) as Map<String, dynamic>;
        expect(storedMap.keys, {'active-key'});
      },
    );

    test('saveScannedHint and removeScannedHint mutate stored map', () async {
      final first = _hint(
        seed: 201,
        name: 'first',
        expiresIn: const Duration(days: 3),
      );
      final second = _hint(
        seed: 221,
        name: 'second',
        expiresIn: const Duration(days: 3),
      );

      await repository.saveScannedHint('first-key', first);
      await repository.saveScannedHint('second-key', second);

      var hints = await repository.getScannedHints();
      expect(hints.keys, {'first-key', 'second-key'});

      await repository.removeScannedHint('first-key');
      hints = await repository.getScannedHints();
      expect(hints.keys, {'second-key'});

      await repository.removeScannedHint('missing-key');
      hints = await repository.getScannedHints();
      expect(hints.keys, {'second-key'});
    });
  });

  test('cleanupExpiredHints prunes both active and scanned buckets', () async {
    final activeMine = _hint(
      seed: 41,
      name: 'mine-active',
      expiresIn: const Duration(days: 1),
    );
    final expiredMine = _hint(
      seed: 51,
      name: 'mine-expired',
      expiresIn: const Duration(hours: -3),
    );
    final activeScanned = _hint(
      seed: 61,
      name: 'scanned-active',
      expiresIn: const Duration(days: 1),
    );
    final expiredScanned = _hint(
      seed: 71,
      name: 'scanned-expired',
      expiresIn: const Duration(hours: -3),
    );

    SharedPreferences.setMockInitialValues({
      'my_active_intro_hints': jsonEncode([
        _serializableHintMap(activeMine),
        _serializableHintMap(expiredMine),
      ]),
      'scanned_intro_hints': jsonEncode({
        'active': _serializableHintMap(activeScanned),
        'expired': _serializableHintMap(expiredScanned),
      }),
    });

    await repository.cleanupExpiredHints();

    final mine = await repository.getMyActiveHints();
    final scanned = await repository.getScannedHints();
    expect(mine.map((h) => h.hintId), [activeMine.hintId]);
    expect(scanned.keys, {'active'});
  });

  test(
    'getMostRecentActiveHint and clearAll cover empty and populated states',
    () async {
      expect(await repository.getMostRecentActiveHint(), isNull);

      final recent = _hint(
        seed: 88,
        name: 'recent',
        expiresIn: const Duration(days: 2),
      );
      await repository.saveMyActiveHint(recent);

      final mostRecent = await repository.getMostRecentActiveHint();
      expect(mostRecent?.hintId, recent.hintId);

      await repository.clearAll();
      expect(await repository.getMyActiveHints(), isEmpty);
      expect(await repository.getScannedHints(), isEmpty);
    },
  );
}
