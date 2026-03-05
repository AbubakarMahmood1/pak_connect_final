import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:get_it/get_it.dart';
import 'package:mockito/mockito.dart';
import 'package:pak_connect/domain/entities/contact.dart';
import 'package:pak_connect/domain/interfaces/i_contact_repository.dart';
import 'package:pak_connect/domain/models/security_level.dart';
import 'package:pak_connect/presentation/providers/group_providers.dart';
import 'package:pak_connect/presentation/screens/create_group_screen.dart';

import '../../data/services/ble_messaging_service_test.mocks.dart';

Contact _contact({
  required String publicKey,
  String? noisePublicKey,
  required String displayName,
  required TrustStatus trust,
  required SecurityLevel security,
}) {
  final now = DateTime.now();
  return Contact(
    publicKey: publicKey,
    displayName: displayName,
    trustStatus: trust,
    securityLevel: security,
    firstSeen: now,
    lastSeen: now,
    noisePublicKey: noisePublicKey,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('CreateGroupScreen', () {
    late MockContactRepository contactRepository;

    setUp(() async {
      await GetIt.instance.reset();
      resetMockitoState();
      contactRepository = MockContactRepository();
      GetIt.instance.registerSingleton<IContactRepository>(contactRepository);
      when(
        contactRepository.getAllContacts(),
      ).thenAnswer((_) async => <String, Contact>{});
    });

    tearDown(() async {
      await GetIt.instance.reset();
    });

    testWidgets(
      'loads only verified medium/high contacts and creates group with selected members',
      (tester) async {
        when(contactRepository.getAllContacts()).thenAnswer(
          (_) async => <String, Contact>{
            'pk1': _contact(
              publicKey: 'pk1',
              displayName: 'Alice',
              trust: TrustStatus.verified,
              security: SecurityLevel.medium,
            ),
            'pk2': _contact(
              publicKey: 'pk2',
              noisePublicKey: 'noise2',
              displayName: 'Bob',
              trust: TrustStatus.verified,
              security: SecurityLevel.high,
            ),
            'pk3': _contact(
              publicKey: 'pk3',
              displayName: 'Unverified',
              trust: TrustStatus.newContact,
              security: SecurityLevel.high,
            ),
            'pk4': _contact(
              publicKey: 'pk4',
              displayName: 'LowSecurity',
              trust: TrustStatus.verified,
              security: SecurityLevel.low,
            ),
          },
        );

        Map<String, dynamic>? capturedCreateArgs;

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              createGroupProvider.overrideWithValue(({
                required String name,
                required List<String> memberKeys,
                String? description,
              }) async {
                capturedCreateArgs = <String, dynamic>{
                  'name': name,
                  'memberKeys': memberKeys,
                  'description': description,
                };
              }),
            ],
            child: const MaterialApp(home: CreateGroupScreen()),
          ),
        );

        await tester.pumpAndSettle();

        expect(find.text('Alice'), findsOneWidget);
        expect(find.text('Bob'), findsOneWidget);
        expect(find.text('Unverified'), findsNothing);
        expect(find.text('LowSecurity'), findsNothing);

        await tester.enterText(
          find.widgetWithText(TextFormField, 'Group Name'),
          '  Weekend Plans  ',
        );
        await tester.enterText(
          find.widgetWithText(TextFormField, 'Description (optional)'),
          '  Hiking trip  ',
        );

        await tester.tap(find.text('Alice'));
        await tester.pump();
        await tester.tap(find.text('Bob'));
        await tester.pump();

        await tester.tap(find.widgetWithText(ElevatedButton, 'Create Group'));
        await tester.pumpAndSettle();

        expect(capturedCreateArgs, isNotNull);
        expect(capturedCreateArgs!['name'], 'Weekend Plans');
        expect(capturedCreateArgs!['description'], 'Hiking trip');
        expect(
          capturedCreateArgs!['memberKeys'],
          containsAll(<String>['pk1', 'noise2']),
        );
      },
    );

    testWidgets('shows validation snackbar when no members are selected', (
      tester,
    ) async {
      when(contactRepository.getAllContacts()).thenAnswer(
        (_) async => <String, Contact>{
          'pk1': _contact(
            publicKey: 'pk1',
            displayName: 'Alice',
            trust: TrustStatus.verified,
            security: SecurityLevel.high,
          ),
        },
      );

      var createInvoked = false;

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            createGroupProvider.overrideWithValue(({
              required String name,
              required List<String> memberKeys,
              String? description,
            }) async {
              createInvoked = true;
            }),
          ],
          child: const MaterialApp(home: CreateGroupScreen()),
        ),
      );

      await tester.pumpAndSettle();

      await tester.enterText(
        find.widgetWithText(TextFormField, 'Group Name'),
        'No Members Group',
      );
      await tester.tap(find.widgetWithText(ElevatedButton, 'Create Group'));
      await tester.pumpAndSettle();

      expect(createInvoked, isFalse);
      expect(find.text('Please select at least one member'), findsOneWidget);
    });
  });
}
