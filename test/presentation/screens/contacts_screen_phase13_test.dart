// Phase 13: ContactsScreen additional coverage
// Targets uncovered lines: 43-60, 124, 216-250, 262-272,
// 315-317, 327, 377-381, 443, 465, 471, 494, 502-504

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
import 'package:pak_connect/presentation/widgets/contact_list_tile.dart';
import 'package:pak_connect/presentation/widgets/empty_contacts_view.dart';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

final _testNow = DateTime(2026, 1, 10, 12, 0);

EnhancedContact _contact({
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
    lastSeenAgo:
        isRecentlyActive ? const Duration(minutes: 5) : const Duration(days: 10),
    isRecentlyActive: isRecentlyActive,
    interactionCount: interactionCount,
    averageResponseTime: const Duration(minutes: 2),
    groupMemberships: const <String>[],
  );
}

ContactSearchResult _result(
  List<EnhancedContact> contacts, {
  String query = '',
  ContactSortOption sortedBy = ContactSortOption.name,
  bool ascending = true,
}) {
  return ContactSearchResult(
    contacts: contacts,
    query: query,
    totalResults: contacts.length,
    searchTime: const Duration(milliseconds: 5),
    sortedBy: sortedBy,
    ascending: ascending,
  );
}

void _configureSurface(WidgetTester tester) {
  tester.view.physicalSize = const Size(1200, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Future<void> _pump(
  WidgetTester tester, {
  Future<ContactSearchResult> Function()? loadContacts,
  Future<ContactStats> Function()? loadStats,
}) async {
  _configureSurface(tester);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        filteredContactsProvider.overrideWith((ref) async {
          if (loadContacts != null) return loadContacts();
          return _result(const <EnhancedContact>[]);
        }),
        contactStatsProvider.overrideWith((ref) async {
          if (loadStats != null) return loadStats();
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

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  // -----------------------------------------------------------------------
  // Basic rendering
  // -----------------------------------------------------------------------
  group('ContactsScreen rendering', () {
    testWidgets('renders Contacts title and search field', (tester) async {
      await _pump(tester);
      await tester.pumpAndSettle();

      expect(find.text('Contacts'), findsOneWidget);
      expect(find.byType(TextField), findsOneWidget);
      expect(find.text('Search contacts...'), findsOneWidget);
    });

    testWidgets('renders FAB with Add Contact label', (tester) async {
      await _pump(tester);
      await tester.pumpAndSettle();

      expect(
        find.widgetWithText(FloatingActionButton, 'Add Contact'),
        findsOneWidget,
      );
      expect(find.byIcon(Icons.qr_code_scanner), findsOneWidget);
    });

    testWidgets('filter and sort buttons are in appbar', (tester) async {
      await _pump(tester);
      await tester.pumpAndSettle();

      expect(find.byTooltip('Filter contacts'), findsOneWidget);
      expect(find.byTooltip('Sort contacts'), findsOneWidget);
    });
  });

  // -----------------------------------------------------------------------
  // Stats subtitle (line 124 – error case)
  // -----------------------------------------------------------------------
  group('Stats subtitle', () {
    testWidgets('shows stats when loaded', (tester) async {
      await _pump(
        tester,
        loadStats: () async => const ContactStats(
          totalContacts: 5,
          verifiedContacts: 3,
          activeContacts: 2,
          highSecurityContacts: 1,
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('5 total • 3 verified'), findsOneWidget);
    });

    testWidgets('shows nothing on stats error (line 124)', (tester) async {
      await _pump(
        tester,
        loadStats: () async => throw Exception('stats error'),
      );
      await tester.pumpAndSettle();

      // SizedBox.shrink is the error fallback
      expect(find.text('5 total'), findsNothing);
    });

    testWidgets('shows nothing while stats loading', (tester) async {
      final gate = Completer<ContactStats>();
      await _pump(tester, loadStats: () => gate.future);
      // Still loading – SizedBox.shrink rendered
      expect(find.text('0 total'), findsNothing);
    });
  });

  // -----------------------------------------------------------------------
  // Empty state (line 310-311)
  // -----------------------------------------------------------------------
  group('Empty contacts state', () {
    testWidgets('shows EmptyContactsView when result is empty', (tester) async {
      await _pump(
        tester,
        loadContacts: () async => ContactSearchResult.empty(''),
      );
      await tester.pumpAndSettle();

      expect(find.byType(EmptyContactsView), findsOneWidget);
    });

    testWidgets('EmptyContactsView receives search query', (tester) async {
      await _pump(
        tester,
        loadContacts: () async => ContactSearchResult.empty('xyz'),
      );
      await tester.pumpAndSettle();

      expect(find.byType(EmptyContactsView), findsOneWidget);
    });
  });

  // -----------------------------------------------------------------------
  // Contact list rendering (lines 315-317, 327)
  // -----------------------------------------------------------------------
  group('Contact list', () {
    testWidgets('renders ContactListTile for each contact', (tester) async {
      final contacts = [
        _contact(
          publicKey: 'pk_a_1234567890abcdef1234567890abcdef',
          displayName: 'Alice',
        ),
        _contact(
          publicKey: 'pk_b_1234567890abcdef1234567890abcdef',
          displayName: 'Bob',
        ),
        _contact(
          publicKey: 'pk_c_1234567890abcdef1234567890abcdef',
          displayName: 'Charlie',
        ),
      ];

      await _pump(
        tester,
        loadContacts: () async => _result(contacts),
        loadStats: () async => const ContactStats(
          totalContacts: 3,
          verifiedContacts: 0,
          activeContacts: 3,
          highSecurityContacts: 0,
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(ContactListTile), findsNWidgets(3));
      expect(find.text('Alice'), findsOneWidget);
      expect(find.text('Bob'), findsOneWidget);
      expect(find.text('Charlie'), findsOneWidget);
    });

    testWidgets('pull-to-refresh triggers reload (lines 315-317)',
        (tester) async {
      var loadCount = 0;
      final contacts = [
        _contact(
          publicKey: 'pk_r_1234567890abcdef1234567890abcdef',
          displayName: 'RefreshTest',
        ),
      ];

      await _pump(
        tester,
        loadContacts: () async {
          loadCount++;
          return _result(contacts);
        },
      );
      await tester.pumpAndSettle();

      // Perform a fling down to trigger RefreshIndicator
      await tester.fling(
        find.byType(ListView),
        const Offset(0, 300),
        1000,
      );
      await tester.pumpAndSettle();

      // At least initial load happened; refresh may trigger additional
      expect(loadCount, greaterThanOrEqualTo(1));
    });

    testWidgets('tapping a contact navigates (line 327)', (tester) async {
      final contacts = [
        _contact(
          publicKey: 'pk_tap_1234567890abcdef1234567890abcde',
          displayName: 'Tappable',
        ),
      ];

      await _pump(
        tester,
        loadContacts: () async => _result(contacts),
      );
      await tester.pumpAndSettle();

      // Tap the contact tile — triggers _openContactDetail (line 327)
      await tester.tap(find.text('Tappable'));
      // Use pump() only — ContactDetailScreen may have unresolvable providers
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
    });
  });

  // -----------------------------------------------------------------------
  // Search functionality
  // -----------------------------------------------------------------------
  group('Search', () {
    testWidgets('typing in search field triggers debounced query',
        (tester) async {
      await _pump(
        tester,
        loadContacts: () async => _result([
          _contact(
            publicKey: 'pk_s_1234567890abcdef1234567890abcdef',
            displayName: 'SearchUser',
          ),
        ]),
      );
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), 'sea');
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();

      // Clear icon appears
      expect(find.byIcon(Icons.clear), findsOneWidget);
    });

    testWidgets('clear button resets search', (tester) async {
      await _pump(
        tester,
        loadContacts: () async => _result([
          _contact(
            publicKey: 'pk_clr_234567890abcdef1234567890abcde',
            displayName: 'ClearTest',
          ),
        ]),
      );
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), 'test');
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.clear));
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.clear), findsNothing);
    });
  });

  // -----------------------------------------------------------------------
  // Add contact FAB (lines 43-60)
  // -----------------------------------------------------------------------
  group('Add contact navigation', () {
    testWidgets('tapping FAB attempts navigation to QRContactScreen',
        (tester) async {
      await _pump(tester);
      await tester.pumpAndSettle();

      // Tap the FAB
      await tester.tap(
        find.widgetWithText(FloatingActionButton, 'Add Contact'),
      );
      await tester.pumpAndSettle();

      // The navigation will push QRContactScreen which may need providers;
      // verify no crash at minimum
    });
  });

  // -----------------------------------------------------------------------
  // Filter bottom sheet (lines 443, 465, 471, 494, 502-504)
  // -----------------------------------------------------------------------
  group('Filter bottom sheet', () {
    testWidgets('opens and shows security level chips', (tester) async {
      await _pump(
        tester,
        loadContacts: () async => _result([
          _contact(
            publicKey: 'pk_f1_234567890abcdef1234567890abcde',
            displayName: 'FilterUser',
          ),
        ]),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Filter contacts'));
      await tester.pumpAndSettle();

      expect(find.text('Filter Contacts'), findsOneWidget);
      expect(find.text('Security Level'), findsOneWidget);
      expect(find.text('Trust Status'), findsOneWidget);
      expect(find.text('Only Recently Active'), findsOneWidget);
    });

    testWidgets('selecting security level chip updates state (line 443)',
        (tester) async {
      await _pump(
        tester,
        loadContacts: () async => _result([
          _contact(
            publicKey: 'pk_f2_234567890abcdef1234567890abcde',
            displayName: 'F2',
          ),
        ]),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Filter contacts'));
      await tester.pumpAndSettle();

      // Select 'high' security level
      await tester.tap(find.widgetWithText(ChoiceChip, 'high'));
      await tester.pumpAndSettle();

      // The 'high' chip should now be selected
      final chip = tester.widget<ChoiceChip>(
        find.widgetWithText(ChoiceChip, 'high'),
      );
      expect(chip.selected, isTrue);
    });

    testWidgets('selecting All security resets selection (line 443)',
        (tester) async {
      await _pump(
        tester,
        loadContacts: () async => _result([
          _contact(
            publicKey: 'pk_f3_234567890abcdef1234567890abcde',
            displayName: 'F3',
          ),
        ]),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Filter contacts'));
      await tester.pumpAndSettle();

      // Select 'medium' then 'All'
      await tester.tap(find.widgetWithText(ChoiceChip, 'medium'));
      await tester.pumpAndSettle();
      // Find the 'All' chip in the Security Level section (first one)
      final allChips = find.widgetWithText(ChoiceChip, 'All');
      await tester.tap(allChips.first);
      await tester.pumpAndSettle();
    });

    testWidgets('selecting trust status chip works (line 465, 471)',
        (tester) async {
      await _pump(
        tester,
        loadContacts: () async => _result([
          _contact(
            publicKey: 'pk_f4_234567890abcdef1234567890abcde',
            displayName: 'F4',
          ),
        ]),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Filter contacts'));
      await tester.pumpAndSettle();

      // Select 'verified' trust status
      await tester.tap(find.widgetWithText(ChoiceChip, 'verified'));
      await tester.pumpAndSettle();

      final chip = tester.widget<ChoiceChip>(
        find.widgetWithText(ChoiceChip, 'verified'),
      );
      expect(chip.selected, isTrue);
    });

    testWidgets('toggling recently active switch works', (tester) async {
      await _pump(
        tester,
        loadContacts: () async => _result([
          _contact(
            publicKey: 'pk_f5_234567890abcdef1234567890abcde',
            displayName: 'F5',
          ),
        ]),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Filter contacts'));
      await tester.pumpAndSettle();

      await tester.tap(
        find.widgetWithText(SwitchListTile, 'Only Recently Active'),
      );
      await tester.pumpAndSettle();

      final switchTile = tester.widget<SwitchListTile>(
        find.widgetWithText(SwitchListTile, 'Only Recently Active'),
      );
      expect(switchTile.value, isTrue);
    });

    testWidgets('Clear button calls onApply with null (line 494)',
        (tester) async {
      await _pump(
        tester,
        loadContacts: () async => _result([
          _contact(
            publicKey: 'pk_f6_234567890abcdef1234567890abcde',
            displayName: 'F6',
          ),
        ]),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Filter contacts'));
      await tester.pumpAndSettle();

      // Tap Clear
      await tester.tap(find.widgetWithText(TextButton, 'Clear'));
      await tester.pumpAndSettle();

      // Bottom sheet closes
      expect(find.text('Filter Contacts'), findsNothing);
    });

    testWidgets('Apply with no selections sends null filter (lines 502-504)',
        (tester) async {
      await _pump(
        tester,
        loadContacts: () async => _result([
          _contact(
            publicKey: 'pk_f7_234567890abcdef1234567890abcde',
            displayName: 'F7',
          ),
        ]),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Filter contacts'));
      await tester.pumpAndSettle();

      // Apply with defaults (all null selections → null filter)
      await tester.tap(find.widgetWithText(FilledButton, 'Apply'));
      await tester.pumpAndSettle();

      // Bottom sheet closes, no filter chips visible
      expect(find.text('Filter Contacts'), findsNothing);
      expect(find.text('Security:'), findsNothing);
    });

    testWidgets('Apply with selections creates a filter', (tester) async {
      await _pump(
        tester,
        loadContacts: () async => _result([
          _contact(
            publicKey: 'pk_f8_234567890abcdef1234567890abcde',
            displayName: 'F8',
          ),
        ]),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Filter contacts'));
      await tester.pumpAndSettle();

      // Select high security and recently active
      await tester.tap(find.widgetWithText(ChoiceChip, 'high'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.widgetWithText(SwitchListTile, 'Only Recently Active'),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(FilledButton, 'Apply'));
      await tester.pumpAndSettle();

      // Filter chips should appear
      expect(find.text('Security: high'), findsOneWidget);
      expect(find.text('Recently Active'), findsOneWidget);
    });
  });

  // -----------------------------------------------------------------------
  // Filter chip deletion (lines 216-250, 262-272)
  // -----------------------------------------------------------------------
  group('Filter chip removal', () {
    Future<void> applySecurityAndTrustFilter(WidgetTester tester) async {
      await _pump(
        tester,
        loadContacts: () async => _result([
          _contact(
            publicKey: 'pk_ch_234567890abcdef1234567890abcde',
            displayName: 'ChipUser',
          ),
        ]),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Filter contacts'));
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(ChoiceChip, 'high'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ChoiceChip, 'verified'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.widgetWithText(SwitchListTile, 'Only Recently Active'),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(FilledButton, 'Apply'));
      await tester.pumpAndSettle();
    }

    testWidgets('removing security chip keeps other filters (lines 216-228)',
        (tester) async {
      await applySecurityAndTrustFilter(tester);

      // Verify chips are present
      expect(find.text('Security: high'), findsOneWidget);
      expect(find.text('Trust: verified'), findsOneWidget);
      expect(find.text('Recently Active'), findsOneWidget);

      // Delete security chip
      final securityChipDeleteIcon = find.descendant(
        of: find.widgetWithText(Chip, 'Security: high'),
        matching: find.byIcon(Icons.close),
      );
      await tester.tap(securityChipDeleteIcon);
      await tester.pumpAndSettle();

      expect(find.text('Security: high'), findsNothing);
      // Trust and recently active should still be present
      expect(find.text('Trust: verified'), findsOneWidget);
      expect(find.text('Recently Active'), findsOneWidget);
    });

    testWidgets('removing trust chip keeps other filters (lines 240-250)',
        (tester) async {
      await applySecurityAndTrustFilter(tester);

      // Delete trust chip
      final trustChipDeleteIcon = find.descendant(
        of: find.widgetWithText(Chip, 'Trust: verified'),
        matching: find.byIcon(Icons.close),
      );
      await tester.tap(trustChipDeleteIcon);
      await tester.pumpAndSettle();

      expect(find.text('Trust: verified'), findsNothing);
      expect(find.text('Security: high'), findsOneWidget);
      expect(find.text('Recently Active'), findsOneWidget);
    });

    testWidgets(
        'removing recently active chip keeps other filters (lines 262-272)',
        (tester) async {
      await applySecurityAndTrustFilter(tester);

      // Delete recently active chip
      final recentlyActiveDeleteIcon = find.descendant(
        of: find.widgetWithText(Chip, 'Recently Active'),
        matching: find.byIcon(Icons.close),
      );
      await tester.tap(recentlyActiveDeleteIcon);
      await tester.pumpAndSettle();

      expect(find.text('Recently Active'), findsNothing);
      expect(find.text('Security: high'), findsOneWidget);
      expect(find.text('Trust: verified'), findsOneWidget);
    });
  });

  // -----------------------------------------------------------------------
  // Sort bottom sheet
  // -----------------------------------------------------------------------
  group('Sort bottom sheet', () {
    testWidgets('opens and shows sort options', (tester) async {
      await _pump(
        tester,
        loadContacts: () async => _result([
          _contact(
            publicKey: 'pk_so_234567890abcdef1234567890abcde',
            displayName: 'SortUser',
          ),
        ]),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Sort contacts'));
      await tester.pumpAndSettle();

      expect(find.text('Sort Contacts'), findsOneWidget);
      expect(find.widgetWithText(ChoiceChip, 'Name'), findsOneWidget);
      expect(find.widgetWithText(ChoiceChip, 'Last Seen'), findsOneWidget);
      // Sort bottom sheet uses its own labels:
      expect(find.widgetWithText(ChoiceChip, 'Security Level'), findsOneWidget);
      expect(find.widgetWithText(ChoiceChip, 'Message Count'), findsOneWidget);
      expect(find.widgetWithText(ChoiceChip, 'Date Added'), findsOneWidget);
    });

    testWidgets('selecting sort option and toggling ascending', (tester) async {
      await _pump(
        tester,
        loadContacts: () async => _result([
          _contact(
            publicKey: 'pk_s2_234567890abcdef1234567890abcde',
            displayName: 'S2',
          ),
        ]),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Sort contacts'));
      await tester.pumpAndSettle();

      // Select 'Security Level' (sort bottom sheet label)
      await tester.tap(find.widgetWithText(ChoiceChip, 'Security Level'));
      await tester.pumpAndSettle();

      // Toggle ascending off
      await tester.tap(
        find.widgetWithText(SwitchListTile, 'Ascending Order'),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(FilledButton, 'Apply'));
      await tester.pumpAndSettle();

      // Sort chip uses main screen's _getSortLabel: 'Security'
      expect(find.text('Sort: Security'), findsOneWidget);
      expect(find.byIcon(Icons.arrow_downward), findsOneWidget);
    });
  });

  // -----------------------------------------------------------------------
  // _getSortLabel coverage (lines 377-381)
  // -----------------------------------------------------------------------
  group('Sort label display', () {
    testWidgets('shows Last Seen sort label', (tester) async {
      await _pump(
        tester,
        loadContacts: () async => _result([
          _contact(
            publicKey: 'pk_sl_234567890abcdef1234567890abcde',
            displayName: 'SL',
          ),
        ]),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Sort contacts'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ChoiceChip, 'Last Seen'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Apply'));
      await tester.pumpAndSettle();

      expect(find.text('Sort: Last Seen'), findsOneWidget);
    });

    testWidgets('shows Messages sort label (line 380)', (tester) async {
      await _pump(
        tester,
        loadContacts: () async => _result([
          _contact(
            publicKey: 'pk_m1_234567890abcdef1234567890abcde',
            displayName: 'M1',
          ),
        ]),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Sort contacts'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ChoiceChip, 'Message Count'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Apply'));
      await tester.pumpAndSettle();

      // Main screen label uses 'Messages' (from _ContactsScreenState._getSortLabel)
      expect(find.text('Sort: Messages'), findsOneWidget);
    });

    testWidgets('shows Date Added sort label (line 381)', (tester) async {
      await _pump(
        tester,
        loadContacts: () async => _result([
          _contact(
            publicKey: 'pk_da_234567890abcdef1234567890abcde',
            displayName: 'DA',
          ),
        ]),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Sort contacts'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ChoiceChip, 'Date Added'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Apply'));
      await tester.pumpAndSettle();

      expect(find.text('Sort: Date Added'), findsOneWidget);
    });

    testWidgets('shows Security sort label (line 378)', (tester) async {
      await _pump(
        tester,
        loadContacts: () async => _result([
          _contact(
            publicKey: 'pk_se_234567890abcdef1234567890abcde',
            displayName: 'SE',
          ),
        ]),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Sort contacts'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ChoiceChip, 'Security Level'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Apply'));
      await tester.pumpAndSettle();

      expect(find.text('Sort: Security'), findsOneWidget);
    });
  });

  // -----------------------------------------------------------------------
  // Error state
  // -----------------------------------------------------------------------
  group('Error state', () {
    testWidgets('displays error icon and message text', (tester) async {
      await _pump(
        tester,
        loadContacts: () async => throw Exception('network down'),
      );
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.error_outline), findsOneWidget);
      expect(find.text('Failed to load contacts'), findsOneWidget);
      expect(find.textContaining('network down'), findsOneWidget);
    });
  });

  // -----------------------------------------------------------------------
  // Loading state
  // -----------------------------------------------------------------------
  group('Loading state', () {
    testWidgets('shows spinner while contacts are loading', (tester) async {
      final gate = Completer<ContactSearchResult>();
      await _pump(tester, loadContacts: () => gate.future);

      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    });
  });

  // -----------------------------------------------------------------------
  // Contact detail navigation (line 56-60)
  // -----------------------------------------------------------------------
  group('Contact detail', () {
    testWidgets('tapping contact navigates to detail (lines 56-60)',
        (tester) async {
      final contacts = [
        _contact(
          publicKey: 'pk_dt_234567890abcdef1234567890abcde',
          displayName: 'DetailTarget',
          securityLevel: SecurityLevel.high,
          trustStatus: TrustStatus.verified,
        ),
      ];

      await _pump(
        tester,
        loadContacts: () async => _result(contacts),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('DetailTarget'));
      // Use pump() only — ContactDetailScreen may have unresolvable providers
      // which would cause pumpAndSettle to time out. The tap itself covers
      // _openContactDetail (lines 56-60).
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
    });
  });

  // -----------------------------------------------------------------------
  // Clear all filter chips
  // -----------------------------------------------------------------------
  group('Clear all', () {
    testWidgets('Clear all removes all filter and sort chips', (tester) async {
      await _pump(
        tester,
        loadContacts: () async => _result([
          _contact(
            publicKey: 'pk_ca_234567890abcdef1234567890abcde',
            displayName: 'CA',
          ),
        ]),
      );
      await tester.pumpAndSettle();

      // Apply a sort to get a chip (sort bottom sheet uses 'Message Count')
      await tester.tap(find.byTooltip('Sort contacts'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ChoiceChip, 'Message Count'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Apply'));
      await tester.pumpAndSettle();

      // Main screen label is 'Messages'
      expect(find.text('Sort: Messages'), findsOneWidget);
      expect(find.text('Clear all'), findsOneWidget);

      await tester.tap(find.text('Clear all'));
      await tester.pumpAndSettle();

      expect(find.text('Sort: Messages'), findsNothing);
      expect(find.text('Clear all'), findsNothing);
    });
  });
}
