import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pak_connect/domain/entities/contact.dart';
import 'package:pak_connect/domain/entities/enhanced_contact.dart';
import 'package:pak_connect/domain/models/security_level.dart';
import 'package:pak_connect/domain/services/contact_management_service.dart';
import 'package:pak_connect/presentation/providers/contact_provider.dart';
import 'package:pak_connect/presentation/screens/contacts_screen.dart';

final _testNow = DateTime(2026, 1, 10, 12, 0);

EnhancedContact _buildContact({
  required String publicKey,
  required String displayName,
  TrustStatus trustStatus = TrustStatus.newContact,
  SecurityLevel securityLevel = SecurityLevel.low,
  bool isRecentlyActive = true,
  int interactionCount = 0,
}) {
  return EnhancedContact(
    contact: Contact(
      publicKey: publicKey,
      displayName: displayName,
      trustStatus: trustStatus,
      securityLevel: securityLevel,
      firstSeen: _testNow.subtract(const Duration(days: 30)),
      lastSeen: _testNow.subtract(const Duration(minutes: 5)),
      lastSecuritySync: _testNow.subtract(const Duration(hours: 2)),
    ),
    lastSeenAgo: isRecentlyActive
        ? const Duration(minutes: 5)
        : const Duration(days: 10),
    isRecentlyActive: isRecentlyActive,
    interactionCount: interactionCount,
    averageResponseTime: const Duration(minutes: 2),
    groupMemberships: const <String>[],
  );
}

ContactSearchResult _result(List<EnhancedContact> contacts) {
  return ContactSearchResult(
    contacts: contacts,
    query: '',
    totalResults: contacts.length,
    searchTime: const Duration(milliseconds: 8),
    sortedBy: ContactSortOption.name,
    ascending: true,
  );
}

void _configureSurface(WidgetTester tester) {
  tester.view.physicalSize = const Size(1200, 2000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Future<void> _pumpContactsScreen(
  WidgetTester tester, {
  Future<ContactSearchResult> Function()? loadContacts,
  Future<ContactStats> Function()? loadStats,
}) async {
  _configureSurface(tester);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        filteredContactsProvider.overrideWith((ref) async {
          if (loadContacts != null) {
            return loadContacts();
          }
          return _result(const <EnhancedContact>[]);
        }),
        contactStatsProvider.overrideWith((ref) async {
          if (loadStats != null) {
            return loadStats();
          }
          return const ContactStats(
            totalContacts: 0,
            verifiedContacts: 0,
            activeContacts: 0,
            highSecurityContacts: 0,
          );
        }),
      ],
      child: const MaterialApp(home: ContactsScreen()),
    ),
  );
  await tester.pump();
}

void main() {
  group('ContactsScreen', () {
    testWidgets('shows loading spinner while contacts are loading', (
      tester,
    ) async {
      final gate = Completer<ContactSearchResult>();

      await _pumpContactsScreen(tester, loadContacts: () => gate.future);

      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    });

    testWidgets('shows empty-state copy when there are no contacts', (
      tester,
    ) async {
      await _pumpContactsScreen(
        tester,
        loadContacts: () async => ContactSearchResult.empty(''),
      );
      await tester.pumpAndSettle();

      expect(find.text('No contacts yet'), findsOneWidget);
      expect(
        find.text('Add your first contact to start secure messaging'),
        findsOneWidget,
      );
    });

    testWidgets('renders stats subtitle and contact rows', (tester) async {
      final contacts = <EnhancedContact>[
        _buildContact(
          publicKey: 'pk_a_1234567890abcdef1234567890abcdef',
          displayName: 'Alice',
          trustStatus: TrustStatus.verified,
          securityLevel: SecurityLevel.high,
          interactionCount: 14,
        ),
        _buildContact(
          publicKey: 'pk_b_1234567890abcdef1234567890abcdef',
          displayName: 'Bob',
          trustStatus: TrustStatus.newContact,
          securityLevel: SecurityLevel.low,
        ),
      ];

      await _pumpContactsScreen(
        tester,
        loadContacts: () async => _result(contacts),
        loadStats: () async => const ContactStats(
          totalContacts: 2,
          verifiedContacts: 1,
          activeContacts: 1,
          highSecurityContacts: 1,
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('2 total • 1 verified'), findsOneWidget);
      expect(find.text('Alice'), findsOneWidget);
      expect(find.text('Bob'), findsOneWidget);
    });

    testWidgets('search query shows clear icon then clears state', (
      tester,
    ) async {
      final contacts = <EnhancedContact>[
        _buildContact(
          publicKey: 'pk_c_1234567890abcdef1234567890abcdef',
          displayName: 'Charlie',
        ),
      ];

      await _pumpContactsScreen(
        tester,
        loadContacts: () async => _result(contacts),
      );
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.clear), findsNothing);
      await tester.enterText(find.byType(TextField), 'cha');
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.clear), findsOneWidget);

      await tester.tap(find.byIcon(Icons.clear));
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.clear), findsNothing);
    });

    testWidgets('applies filter chips and clear-all resets them', (
      tester,
    ) async {
      final contacts = <EnhancedContact>[
        _buildContact(
          publicKey: 'pk_d_1234567890abcdef1234567890abcdef',
          displayName: 'Dina',
          securityLevel: SecurityLevel.high,
        ),
      ];

      await _pumpContactsScreen(
        tester,
        loadContacts: () async => _result(contacts),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Filter contacts'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ChoiceChip, 'high'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.widgetWithText(SwitchListTile, 'Only Recently Active'),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Apply'));
      await tester.pumpAndSettle();

      expect(find.text('Security: high'), findsOneWidget);
      expect(find.text('Recently Active'), findsOneWidget);
      expect(find.text('Clear all'), findsOneWidget);

      await tester.tap(find.text('Clear all'));
      await tester.pumpAndSettle();
      expect(find.text('Security: high'), findsNothing);
      expect(find.text('Recently Active'), findsNothing);
      expect(find.text('Clear all'), findsNothing);
    });

    testWidgets('applies sort option and direction chip', (tester) async {
      final contacts = <EnhancedContact>[
        _buildContact(
          publicKey: 'pk_e_1234567890abcdef1234567890abcdef',
          displayName: 'Eve',
        ),
      ];

      await _pumpContactsScreen(
        tester,
        loadContacts: () async => _result(contacts),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Sort contacts'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ChoiceChip, 'Last Seen'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(SwitchListTile, 'Ascending Order'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Apply'));
      await tester.pumpAndSettle();

      expect(find.text('Sort: Last Seen'), findsOneWidget);
      expect(find.byIcon(Icons.arrow_downward), findsOneWidget);
    });

    testWidgets('shows error UI when contacts query fails', (tester) async {
      await _pumpContactsScreen(
        tester,
        loadContacts: () async {
          throw Exception('contacts exploded');
        },
      );
      await tester.pumpAndSettle();

      expect(find.text('Failed to load contacts'), findsOneWidget);
      expect(find.textContaining('contacts exploded'), findsOneWidget);
    });
  });
}
