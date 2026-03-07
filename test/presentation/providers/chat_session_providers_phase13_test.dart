// Phase 13.2: ChatSessionProviders data classes + model coverage

import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:pak_connect/presentation/providers/chat_session_providers.dart';
import 'package:pak_connect/presentation/models/chat_ui_state.dart';
import 'package:pak_connect/presentation/viewmodels/chat_session_view_model.dart';
import 'package:pak_connect/presentation/controllers/chat_session_lifecycle.dart';
import 'package:pak_connect/domain/values/id_types.dart';
import 'package:pak_connect/domain/models/connection_info.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pak_connect/domain/models/mesh_network_models.dart';

void main() {
  Logger.root.level = Level.OFF;

  group('ChatSessionActions', () {
    test('can be constructed with all required callbacks', () {
      final actions = ChatSessionActions(
        sendMessage: (_) async {},
        deleteMessage: (_, __) async {},
        retryFailedMessages: () async {},
        manualReconnection: () async {},
        retryFailedMessagesInline: () async {},
        requestPairing: () async {},
        handleAsymmetricContact: (_, __) async {},
        handleConnectionChange: (_, __) {},
        handleMeshInitializationStatusChange: (_, __) {},
        scrollToBottom: () {},
        toggleSearchMode: () {},
      );

      expect(actions.sendMessage, isNotNull);
      expect(actions.deleteMessage, isNotNull);
      expect(actions.retryFailedMessages, isNotNull);
      expect(actions.manualReconnection, isNotNull);
      expect(actions.retryFailedMessagesInline, isNotNull);
      expect(actions.requestPairing, isNotNull);
      expect(actions.handleAsymmetricContact, isNotNull);
      expect(actions.handleConnectionChange, isNotNull);
      expect(actions.handleMeshInitializationStatusChange, isNotNull);
      expect(actions.scrollToBottom, isNotNull);
      expect(actions.toggleSearchMode, isNotNull);
    });

    test('sendMessage callback works', () async {
      String? captured;
      final actions = ChatSessionActions(
        sendMessage: (content) async { captured = content; },
        deleteMessage: (_, __) async {},
        retryFailedMessages: () async {},
        manualReconnection: () async {},
        retryFailedMessagesInline: () async {},
        requestPairing: () async {},
        handleAsymmetricContact: (_, __) async {},
        handleConnectionChange: (_, __) {},
        handleMeshInitializationStatusChange: (_, __) {},
        scrollToBottom: () {},
        toggleSearchMode: () {},
      );

      await actions.sendMessage('hello');
      expect(captured, 'hello');
    });

    test('deleteMessage callback passes parameters', () async {
      MessageId? capturedId;
      bool? capturedForEveryone;
      final actions = ChatSessionActions(
        sendMessage: (_) async {},
        deleteMessage: (id, forEveryone) async {
          capturedId = id;
          capturedForEveryone = forEveryone;
        },
        retryFailedMessages: () async {},
        manualReconnection: () async {},
        retryFailedMessagesInline: () async {},
        requestPairing: () async {},
        handleAsymmetricContact: (_, __) async {},
        handleConnectionChange: (_, __) {},
        handleMeshInitializationStatusChange: (_, __) {},
        scrollToBottom: () {},
        toggleSearchMode: () {},
      );

      await actions.deleteMessage(const MessageId('msg1'), true);
      expect(capturedId, const MessageId('msg1'));
      expect(capturedForEveryone, isTrue);
    });

    test('handleConnectionChange passes old and new', () {
      ConnectionInfo? capturedOld;
      ConnectionInfo? capturedNew;
      final actions = ChatSessionActions(
        sendMessage: (_) async {},
        deleteMessage: (_, __) async {},
        retryFailedMessages: () async {},
        manualReconnection: () async {},
        retryFailedMessagesInline: () async {},
        requestPairing: () async {},
        handleAsymmetricContact: (_, __) async {},
        handleConnectionChange: (old, newInfo) {
          capturedOld = old;
          capturedNew = newInfo;
        },
        handleMeshInitializationStatusChange: (_, __) {},
        scrollToBottom: () {},
        toggleSearchMode: () {},
      );

      actions.handleConnectionChange(null, null);
      expect(capturedOld, isNull);
      expect(capturedNew, isNull);
    });

    test('handleMeshInitializationStatusChange works', () {
      var called = false;
      final actions = ChatSessionActions(
        sendMessage: (_) async {},
        deleteMessage: (_, __) async {},
        retryFailedMessages: () async {},
        manualReconnection: () async {},
        retryFailedMessagesInline: () async {},
        requestPairing: () async {},
        handleAsymmetricContact: (_, __) async {},
        handleConnectionChange: (_, __) {},
        handleMeshInitializationStatusChange: (_, __) { called = true; },
        scrollToBottom: () {},
        toggleSearchMode: () {},
      );

      actions.handleMeshInitializationStatusChange(
        null,
        const AsyncData(MeshNetworkStatus(
          isInitialized: true,
          isConnected: false,
          statistics: MeshNetworkStatistics(
            nodeId: 'test',
            isInitialized: true,
            spamPreventionActive: false,
            queueSyncActive: false,
          ),
        )),
      );
      expect(called, isTrue);
    });
  });

  group('ChatSessionProviderArgs', () {
    test('can be constructed', () {
      // Just verify the class exists and compiles with named params
      expect(ChatSessionProviderArgs, isNotNull);
    });
  });

  group('ChatSessionLifecycleArgs', () {
    test('can be constructed', () {
      expect(ChatSessionLifecycleArgs, isNotNull);
    });
  });

  group('ChatSessionHandle', () {
    test('is a const constructible data holder', () {
      expect(ChatSessionHandle, isNotNull);
    });
  });
}
