// Riverpod providers for contact groups and group messaging

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:get_it/get_it.dart';
import 'package:logging/logging.dart';
import '../../domain/models/contact_group.dart';
import '../../domain/interfaces/i_contact_repository.dart';
import '../../domain/interfaces/i_group_repository.dart';
import '../../domain/interfaces/i_shared_message_queue_provider.dart';
import '../../domain/services/group_messaging_service.dart';
import '../../domain/values/id_types.dart';

final _logger = Logger('GroupProviders');

// ==================== REPOSITORIES ====================

/// Provider for GroupRepository singleton
final groupRepositoryProvider = Provider<IGroupRepository>((ref) {
  return _resolveGroupRepository();
});

// ==================== SERVICES ====================

/// Provider for GroupMessagingService
final groupMessagingServiceProvider = Provider<GroupMessagingService>((ref) {
  final groupRepo = ref.watch(groupRepositoryProvider);
  final contactRepo = _resolveContactRepository();
  final sharedQueueProvider = _resolveSharedQueueProvider();
  if (!sharedQueueProvider.isInitialized) {
    throw StateError(
      'Shared message queue is not initialized. '
      'Ensure app bootstrap completes before using group messaging.',
    );
  }
  final messageQueue = sharedQueueProvider.messageQueue;

  return GroupMessagingService(
    groupRepo: groupRepo,
    contactRepo: contactRepo,
    messageQueue: messageQueue,
  );
});

// ==================== STATE PROVIDERS ====================

/// Provider for all groups (refreshable)
///
/// Usage:
/// ```dart
/// final groups = ref.watch(allGroupsProvider);
/// groups.when(
///   data: (groups) => ListView(...),
///   loading: () => CircularProgressIndicator(),
///   error: (err, stack) => Text('Error: $err'),
/// );
/// ```
final allGroupsProvider = FutureProvider.autoDispose<List<ContactGroup>>((
  ref,
) async {
  final repo = ref.watch(groupRepositoryProvider);
  return await repo.getAllGroups();
});

/// Provider for a specific group by ID
///
/// Usage:
/// ```dart
/// final group = ref.watch(groupByIdProvider(groupId));
/// ```
final groupByIdProvider = FutureProvider.autoDispose
    .family<ContactGroup?, String>((ref, groupId) async {
      final repo = ref.watch(groupRepositoryProvider);
      return await repo.getGroup(groupId);
    });

/// Provider for messages in a group
///
/// Usage:
/// ```dart
/// final messages = ref.watch(groupMessagesProvider(groupId));
/// ```
final groupMessagesProvider = FutureProvider.autoDispose
    .family<List<GroupMessage>, String>((ref, groupId) async {
      final service = ref.watch(groupMessagingServiceProvider);
      return await service.getGroupMessages(groupId);
    });

/// Provider for a specific message with delivery status
final groupMessageByIdProvider = FutureProvider.autoDispose
    .family<GroupMessage?, String>((ref, messageId) async {
      final service = ref.watch(groupMessagingServiceProvider);
      return await service.getMessage(MessageId(messageId));
    });

/// Provider for delivery summary of a message
final messageDeliverySummaryProvider = FutureProvider.autoDispose
    .family<Map<MessageDeliveryStatus, int>, String>((ref, messageId) async {
      final service = ref.watch(groupMessagingServiceProvider);
      return await service.getDeliverySummary(MessageId(messageId));
    });

/// Provider for groups that a specific member belongs to
final groupsForMemberProvider = FutureProvider.autoDispose
    .family<List<ContactGroup>, String>((ref, memberKey) async {
      final repo = ref.watch(groupRepositoryProvider);
      return await repo.getGroupsForMember(memberKey);
    });

// ==================== ACTION PROVIDERS (Simplified - no StateNotifier) ====================

/// Create a new group
final createGroupProvider =
    Provider<
      Future<void> Function({
        required String name,
        required List<String> memberKeys,
        String? description,
      })
    >((ref) {
      final repo = ref.watch(groupRepositoryProvider);

      return ({
        required String name,
        required List<String> memberKeys,
        String? description,
      }) async {
        final group = ContactGroup.create(
          name: name,
          memberKeys: memberKeys,
          description: description,
        );

        await repo.createGroup(group);
        _logger.info('✅ Created group: $name');

        // Invalidate groups list to refresh UI
        ref.invalidate(allGroupsProvider);
      };
    });

/// Update an existing group
final updateGroupProvider = Provider<Future<void> Function(ContactGroup)>((
  ref,
) {
  final repo = ref.watch(groupRepositoryProvider);

  return (ContactGroup group) async {
    await repo.updateGroup(group);
    _logger.info('✅ Updated group: ${group.name}');

    // Invalidate groups list to refresh UI
    ref.invalidate(allGroupsProvider);
  };
});

/// Delete a group
final deleteGroupProvider = Provider<Future<void> Function(String)>((ref) {
  final repo = ref.watch(groupRepositoryProvider);

  return (String groupId) async {
    await repo.deleteGroup(groupId);
    _logger.info('✅ Deleted group: $groupId');

    // Invalidate groups list to refresh UI
    ref.invalidate(allGroupsProvider);
  };
});

// ==================== ACTION PROVIDERS ====================

/// Send a message to a group
///
/// Usage:
/// ```dart
/// final sendMessage = ref.read(sendGroupMessageProvider);
/// await sendMessage(
///   groupId: 'group_123',
///   senderKey: myKey,
///   content: 'Hello group!',
/// );
/// ```
final sendGroupMessageProvider =
    Provider<
      Future<GroupMessage> Function({
        required String groupId,
        required String senderKey,
        required String content,
      })
    >((ref) {
      final service = ref.watch(groupMessagingServiceProvider);

      return ({
        required String groupId,
        required String senderKey,
        required String content,
      }) async {
        final message = await service.sendGroupMessage(
          groupId: groupId,
          senderKey: senderKey,
          content: content,
        );

        // Invalidate messages list to refresh UI
        ref.invalidate(groupMessagesProvider(groupId));

        return message;
      };
    });

ISharedMessageQueueProvider _resolveSharedQueueProvider() {
  if (GetIt.instance.isRegistered<ISharedMessageQueueProvider>()) {
    return GetIt.instance<ISharedMessageQueueProvider>();
  }
  throw StateError(
    'ISharedMessageQueueProvider is not registered. '
    'Register it in DI before creating GroupMessagingService.',
  );
}

IGroupRepository _resolveGroupRepository() {
  if (GetIt.instance.isRegistered<IGroupRepository>()) {
    return GetIt.instance<IGroupRepository>();
  }
  throw StateError(
    'IGroupRepository is not registered. '
    'Register it in DI before creating group providers.',
  );
}

IContactRepository _resolveContactRepository() {
  if (GetIt.instance.isRegistered<IContactRepository>()) {
    return GetIt.instance<IContactRepository>();
  }
  throw StateError(
    'IContactRepository is not registered. '
    'Register it in DI before creating group providers.',
  );
}

/// Mark a message as delivered for a member
final markMessageDeliveredProvider =
    Provider<
      Future<void> Function({
        required String messageId,
        required String memberKey,
      })
    >((ref) {
      final service = ref.watch(groupMessagingServiceProvider);

      return ({required String messageId, required String memberKey}) async {
        await service.markDeliveredForMember(
          MessageId(messageId),
          ChatId(memberKey),
        );

        // Invalidate message to refresh delivery status
        ref.invalidate(groupMessageByIdProvider(messageId));
        ref.invalidate(messageDeliverySummaryProvider(messageId));
      };
    });

/// Mark a message as failed for a member
final markMessageFailedProvider =
    Provider<
      Future<void> Function({
        required String messageId,
        required String memberKey,
      })
    >((ref) {
      final service = ref.watch(groupMessagingServiceProvider);

      return ({required String messageId, required String memberKey}) async {
        await service.markFailedForMember(
          MessageId(messageId),
          ChatId(memberKey),
        );

        // Invalidate message to refresh delivery status
        ref.invalidate(groupMessageByIdProvider(messageId));
        ref.invalidate(messageDeliverySummaryProvider(messageId));
      };
    });
