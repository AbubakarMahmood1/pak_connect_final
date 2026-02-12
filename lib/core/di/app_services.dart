import 'package:pak_connect/domain/interfaces/i_archive_repository.dart';
import 'package:pak_connect/domain/interfaces/i_chats_repository.dart';
import 'package:pak_connect/domain/interfaces/i_connection_service.dart';
import 'package:pak_connect/domain/interfaces/i_contact_repository.dart';
import 'package:pak_connect/domain/interfaces/i_message_repository.dart';
import 'package:pak_connect/domain/interfaces/i_mesh_networking_service.dart';
import 'package:pak_connect/domain/interfaces/i_preferences_repository.dart';
import 'package:pak_connect/domain/interfaces/i_repository_provider.dart';
import 'package:pak_connect/domain/interfaces/i_security_service.dart';
import 'package:pak_connect/domain/interfaces/i_shared_message_queue_provider.dart';
import 'package:pak_connect/domain/interfaces/i_user_preferences.dart';
import 'package:pak_connect/domain/services/archive_management_service.dart';
import 'package:pak_connect/domain/services/archive_search_service.dart';
import 'package:pak_connect/domain/services/chat_management_service.dart';
import 'package:pak_connect/domain/services/contact_management_service.dart';
import 'package:pak_connect/domain/services/mesh/mesh_network_health_monitor.dart';

/// Typed composition-root snapshot exposed by [AppCore].
///
/// Pass 4 scaffold: presentation/domain adapters can gradually read from this
/// object instead of ad-hoc service locator calls.
class AppServices {
  const AppServices({
    required this.contactRepository,
    required this.messageRepository,
    required this.archiveRepository,
    required this.chatsRepository,
    required this.userPreferences,
    required this.preferencesRepository,
    required this.repositoryProvider,
    required this.sharedMessageQueueProvider,
    required this.connectionService,
    required this.meshNetworkingService,
    required this.meshNetworkHealthMonitor,
    required this.securityService,
    required this.contactManagementService,
    required this.chatManagementService,
    required this.archiveManagementService,
    required this.archiveSearchService,
  });

  final IContactRepository contactRepository;
  final IMessageRepository messageRepository;
  final IArchiveRepository archiveRepository;
  final IChatsRepository chatsRepository;
  final IUserPreferences userPreferences;
  final IPreferencesRepository preferencesRepository;
  final IRepositoryProvider repositoryProvider;
  final ISharedMessageQueueProvider sharedMessageQueueProvider;
  final IConnectionService connectionService;
  final IMeshNetworkingService meshNetworkingService;
  final MeshNetworkHealthMonitor meshNetworkHealthMonitor;
  final ISecurityService securityService;
  final ContactManagementService contactManagementService;
  final ChatManagementService chatManagementService;
  final ArchiveManagementService archiveManagementService;
  final ArchiveSearchService archiveSearchService;
}
