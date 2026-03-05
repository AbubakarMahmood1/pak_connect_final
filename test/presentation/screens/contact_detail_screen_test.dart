import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pak_connect/domain/entities/contact.dart';
import 'package:pak_connect/domain/entities/enhanced_contact.dart';
import 'package:pak_connect/domain/interfaces/i_contact_repository.dart';
import 'package:pak_connect/domain/models/security_level.dart';
import 'package:pak_connect/domain/services/contact_management_service.dart';
import 'package:pak_connect/domain/values/id_types.dart';
import 'package:pak_connect/presentation/providers/contact_provider.dart';
import 'package:pak_connect/presentation/screens/contact_detail_screen.dart';

const _publicKey = 'pk_contact_1234567890abcdef1234567890abcdef1234';
final _testNow = DateTime(2026, 1, 10, 12, 0);

class _FakeContactRepository extends Fake implements IContactRepository {
  bool resetResult = true;
  Object? resetError;
  int resetCalls = 0;
  String? lastResetPublicKey;

  @override
  Future<bool> resetContactSecurity(String publicKey, String reason) async {
    resetCalls++;
    lastResetPublicKey = publicKey;
    if (resetError != null) {
      throw resetError!;
    }
    return resetResult;
  }
}

EnhancedContact _buildContact({
  String publicKey = _publicKey,
  String displayName = 'Alice',
  TrustStatus trustStatus = TrustStatus.newContact,
  SecurityLevel securityLevel = SecurityLevel.medium,
  bool isRecentlyActive = true,
  List<String> groups = const <String>['Family'],
}) {
  return EnhancedContact(
    contact: Contact(
      publicKey: publicKey,
      displayName: displayName,
      trustStatus: trustStatus,
      securityLevel: securityLevel,
      firstSeen: _testNow.subtract(const Duration(days: 40)),
      lastSeen: _testNow.subtract(const Duration(minutes: 20)),
      lastSecuritySync: _testNow.subtract(const Duration(hours: 1)),
    ),
    lastSeenAgo: isRecentlyActive
        ? const Duration(minutes: 20)
        : const Duration(days: 10),
    isRecentlyActive: isRecentlyActive,
    interactionCount: 9,
    averageResponseTime: const Duration(minutes: 3),
    groupMemberships: groups,
  );
}

Future<void> _pumpContactDetail(
  WidgetTester tester, {
  required String publicKey,
  required Future<EnhancedContact?> Function(UserId userId) loadContact,
  FutureOr<bool> Function(String publicKey)? onVerify,
  FutureOr<ContactOperationResult> Function(String publicKey)? onDelete,
  _FakeContactRepository? repository,
}) async {
  final repo = repository ?? _FakeContactRepository();

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        contactRepositoryProvider.overrideWithValue(repo),
        contactDetailByUserIdProvider.overrideWith((ref, userId) {
          return loadContact(userId);
        }),
        verifyContactProvider.overrideWith((ref, key) async {
          return onVerify?.call(key) ?? true;
        }),
        deleteContactProvider.overrideWith((ref, key) async {
          return onDelete?.call(key) ?? ContactOperationResult.success('ok');
        }),
      ],
      child: MaterialApp(
        initialRoute: '/detail',
        routes: {
          '/': (context) =>
              const Scaffold(body: Center(child: Text('Root Host'))),
          '/detail': (context) => ContactDetailScreen(publicKey: publicKey),
        },
      ),
    ),
  );
  await tester.pump();
}

Future<void> _openMenuAndSelect(WidgetTester tester, String label) async {
  await tester.tap(find.byType(PopupMenuButton<String>));
  await tester.pumpAndSettle();
  await tester.tap(find.text(label).last);
  await tester.pumpAndSettle();
}

void main() {
  group('ContactDetailScreen', () {
    testWidgets('shows loading spinner while detail is loading', (
      tester,
    ) async {
      final gate = Completer<EnhancedContact?>();

      await _pumpContactDetail(
        tester,
        publicKey: _publicKey,
        loadContact: (_) => gate.future,
      );

      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    });

    testWidgets('shows not-found state when contact is missing', (
      tester,
    ) async {
      await _pumpContactDetail(
        tester,
        publicKey: _publicKey,
        loadContact: (_) async => null,
      );
      await tester.pumpAndSettle();

      expect(find.text('Contact not found'), findsOneWidget);
      expect(find.text('Go Back'), findsOneWidget);
    });

    testWidgets('shows error state when detail provider fails', (tester) async {
      await _pumpContactDetail(
        tester,
        publicKey: _publicKey,
        loadContact: (_) async {
          throw Exception('detail exploded');
        },
      );
      await tester.pumpAndSettle();

      expect(find.text('Failed to load contact'), findsOneWidget);
      expect(find.textContaining('detail exploded'), findsOneWidget);
    });

    testWidgets('renders full detail sections and unverified actions', (
      tester,
    ) async {
      final contact = _buildContact(groups: const <String>['Family', 'Team']);

      await _pumpContactDetail(
        tester,
        publicKey: _publicKey,
        loadContact: (_) async => contact,
      );
      await tester.pumpAndSettle();

      expect(find.text('Alice'), findsOneWidget);
      expect(find.text('Security'), findsOneWidget);
      expect(find.text('Activity'), findsOneWidget);
      expect(find.text('Groups'), findsOneWidget);
      expect(find.text('Family'), findsOneWidget);
      expect(find.text('Send Message'), findsOneWidget);
      expect(find.text('Verify Contact'), findsOneWidget);
    });

    testWidgets(
      'popup menu hides verify/reset for verified low-security contact',
      (tester) async {
        final contact = _buildContact(
          trustStatus: TrustStatus.verified,
          securityLevel: SecurityLevel.low,
          groups: const <String>[],
        );

        await _pumpContactDetail(
          tester,
          publicKey: _publicKey,
          loadContact: (_) async => contact,
        );
        await tester.pumpAndSettle();

        await tester.tap(find.byType(PopupMenuButton<String>));
        await tester.pumpAndSettle();

        expect(find.text('Verify Contact'), findsNothing);
        expect(find.text('Reset Security'), findsNothing);
        expect(find.text('Copy Public Key'), findsOneWidget);
        expect(find.text('Delete Contact'), findsNWidgets(2));
      },
    );

    testWidgets('copy public key action shows snackbar', (tester) async {
      final contact = _buildContact();

      await _pumpContactDetail(
        tester,
        publicKey: _publicKey,
        loadContact: (_) async => contact,
      );
      await tester.pumpAndSettle();

      await _openMenuAndSelect(tester, 'Copy Public Key');

      expect(find.text('Public key copied to clipboard'), findsOneWidget);
    });

    testWidgets('verify action shows success snackbar on true result', (
      tester,
    ) async {
      final contact = _buildContact();

      await _pumpContactDetail(
        tester,
        publicKey: _publicKey,
        loadContact: (_) async => contact,
        onVerify: (_) => true,
      );
      await tester.pumpAndSettle();

      await _openMenuAndSelect(tester, 'Verify Contact');
      await tester.tap(find.widgetWithText(FilledButton, 'Verify'));
      await tester.pumpAndSettle();

      expect(find.text('Contact verified'), findsOneWidget);
    });

    testWidgets('verify action shows failure snackbar on false result', (
      tester,
    ) async {
      final contact = _buildContact();

      await _pumpContactDetail(
        tester,
        publicKey: _publicKey,
        loadContact: (_) async => contact,
        onVerify: (_) => false,
      );
      await tester.pumpAndSettle();

      await _openMenuAndSelect(tester, 'Verify Contact');
      await tester.tap(find.widgetWithText(FilledButton, 'Verify'));
      await tester.pumpAndSettle();

      expect(find.text('Failed to verify contact'), findsOneWidget);
    });

    testWidgets('reset security action calls repository and shows success', (
      tester,
    ) async {
      final repository = _FakeContactRepository()..resetResult = true;
      final contact = _buildContact(securityLevel: SecurityLevel.high);

      await _pumpContactDetail(
        tester,
        publicKey: _publicKey,
        loadContact: (_) async => contact,
        repository: repository,
      );
      await tester.pumpAndSettle();

      await _openMenuAndSelect(tester, 'Reset Security');
      await tester.tap(find.widgetWithText(FilledButton, 'Reset'));
      await tester.pumpAndSettle();

      expect(find.text('Security reset to low level'), findsOneWidget);
      expect(repository.resetCalls, 1);
      expect(repository.lastResetPublicKey, _publicKey);
    });

    testWidgets('delete action success pops back to host route', (
      tester,
    ) async {
      final contact = _buildContact();

      await _pumpContactDetail(
        tester,
        publicKey: _publicKey,
        loadContact: (_) async => contact,
        onDelete: (_) => ContactOperationResult.success('done'),
      );
      await tester.pumpAndSettle();

      await _openMenuAndSelect(tester, 'Delete Contact');
      await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
      await tester.pumpAndSettle();

      expect(find.text('Root Host'), findsOneWidget);
    });

    testWidgets('delete action failure keeps detail screen and shows error', (
      tester,
    ) async {
      final contact = _buildContact();

      await _pumpContactDetail(
        tester,
        publicKey: _publicKey,
        loadContact: (_) async => contact,
        onDelete: (_) => ContactOperationResult.failure('denied'),
      );
      await tester.pumpAndSettle();

      await _openMenuAndSelect(tester, 'Delete Contact');
      await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
      await tester.pumpAndSettle();

      expect(find.text('Contact Details'), findsOneWidget);
      expect(find.text('Failed to delete: denied'), findsOneWidget);
    });
  });
}
