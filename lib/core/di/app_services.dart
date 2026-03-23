import 'package:pak_connect/domain/interfaces/i_archive_repository.dart';
import 'package:pak_connect/domain/interfaces/i_chats_repository.dart';
import 'package:pak_connect/domain/interfaces/i_chat_list_coordinator_factory.dart';
import 'package:pak_connect/domain/interfaces/i_chat_connection_manager_factory.dart';
import 'package:pak_connect/domain/interfaces/i_ble_service_facade.dart';
import 'package:pak_connect/domain/interfaces/i_ble_service_facade_factory.dart';
import 'package:pak_connect/domain/interfaces/i_connection_service.dart';
import 'package:pak_connect/domain/interfaces/i_contact_repository.dart';
import 'package:pak_connect/domain/interfaces/i_database_provider.dart';
import 'package:pak_connect/domain/interfaces/i_export_service.dart';
import 'package:pak_connect/domain/interfaces/i_group_repository.dart';
import 'package:pak_connect/domain/interfaces/i_home_screen_facade_factory.dart';
import 'package:pak_connect/domain/interfaces/i_import_service.dart';
import 'package:pak_connect/domain/interfaces/i_intro_hint_repository.dart';
import 'package:pak_connect/domain/interfaces/i_message_repository.dart';
import 'package:pak_connect/domain/interfaces/i_mesh_relay_engine_factory.dart';
import 'package:pak_connect/domain/interfaces/i_mesh_networking_service.dart';
import 'package:pak_connect/domain/interfaces/i_preferences_repository.dart';
import 'package:pak_connect/domain/interfaces/i_repository_provider.dart';
import 'package:pak_connect/domain/interfaces/i_security_service.dart';
import 'package:pak_connect/domain/interfaces/i_seen_message_store.dart';
import 'package:pak_connect/domain/interfaces/i_shared_message_queue_provider.dart';
import 'package:pak_connect/domain/interfaces/i_user_preferences.dart';
import 'package:pak_connect/domain/services/archive_management_service.dart';
import 'package:pak_connect/domain/services/archive_search_service.dart';
import 'package:pak_connect/domain/services/chat_management_service.dart';
import 'package:pak_connect/domain/services/contact_management_service.dart';
import 'package:pak_connect/domain/services/mesh/mesh_queue_sync_coordinator.dart';
import 'package:pak_connect/domain/services/mesh/mesh_network_health_monitor.dart';
import 'package:pak_connect/domain/services/mesh/mesh_relay_coordinator.dart';

/// Typed bootstrap dependency bundle resolved from the legacy runtime locator.
///
/// `AppCore` uses this during startup so the remaining locator reads stay
/// centralized and mechanically replaceable ahead of full GetIt removal.
class AppBootstrapServices {
  const AppBootstrapServices({
    required this.contactRepository,
    required this.messageRepository,
    required this.archiveRepository,
    required this.chatsRepository,
    required this.userPreferences,
    required this.preferencesRepository,
    required this.repositoryProvider,
    required this.sharedMessageQueueProvider,
    required this.databaseProvider,
    required this.seenMessageStore,
    required this.bleServiceFacadeFactory,
    required this.meshRelayEngineFactory,
    this.bleServiceFacade,
    this.groupRepository,
    this.introHintRepository,
    this.exportService,
    this.importService,
    this.homeScreenFacadeFactory,
    this.chatConnectionManagerFactory,
    this.chatListCoordinatorFactory,
  });

  final IContactRepository contactRepository;
  final IMessageRepository messageRepository;
  final IArchiveRepository archiveRepository;
  final IChatsRepository chatsRepository;
  final IUserPreferences userPreferences;
  final IPreferencesRepository preferencesRepository;
  final IRepositoryProvider repositoryProvider;
  final ISharedMessageQueueProvider sharedMessageQueueProvider;
  final IDatabaseProvider databaseProvider;
  final ISeenMessageStore seenMessageStore;
  final IBLEServiceFacadeFactory bleServiceFacadeFactory;
  final IMeshRelayEngineFactory meshRelayEngineFactory;
  final IBLEServiceFacade? bleServiceFacade;
  final IGroupRepository? groupRepository;
  final IIntroHintRepository? introHintRepository;
  final IExportService? exportService;
  final IImportService? importService;
  final IHomeScreenFacadeFactory? homeScreenFacadeFactory;
  final IChatConnectionManagerFactory? chatConnectionManagerFactory;
  final IChatListCoordinatorFactory? chatListCoordinatorFactory;

  AppServices buildRuntimeSnapshot({
    required IConnectionService connectionService,
    required IMeshNetworkingService meshNetworkingService,
    required MeshNetworkHealthMonitor meshNetworkHealthMonitor,
    required ISecurityService securityService,
    required ContactManagementService contactManagementService,
    required ChatManagementService chatManagementService,
    required ArchiveManagementService archiveManagementService,
    required ArchiveSearchService archiveSearchService,
  }) {
    return AppServices(
      contactRepository: contactRepository,
      messageRepository: messageRepository,
      archiveRepository: archiveRepository,
      chatsRepository: chatsRepository,
      userPreferences: userPreferences,
      preferencesRepository: preferencesRepository,
      repositoryProvider: repositoryProvider,
      sharedMessageQueueProvider: sharedMessageQueueProvider,
      connectionService: connectionService,
      meshNetworkingService: meshNetworkingService,
      meshNetworkHealthMonitor: meshNetworkHealthMonitor,
      securityService: securityService,
      contactManagementService: contactManagementService,
      chatManagementService: chatManagementService,
      archiveManagementService: archiveManagementService,
      archiveSearchService: archiveSearchService,
      databaseProvider: databaseProvider,
      groupRepository: groupRepository,
      introHintRepository: introHintRepository,
      exportService: exportService,
      importService: importService,
      homeScreenFacadeFactory: homeScreenFacadeFactory,
      chatConnectionManagerFactory: chatConnectionManagerFactory,
      chatListCoordinatorFactory: chatListCoordinatorFactory,
    );
  }
}

/// Explicit in-memory runtime bindings published by `AppCore` as startup
/// progresses.
///
/// This replaces the previous pattern of publishing initialized runtime
/// services into GetIt before the full `AppServices` snapshot exists.
class AppRuntimeBindings {
  const AppRuntimeBindings({
    required this.securityService,
    required this.connectionService,
    required this.meshNetworkingService,
    this.meshRelayCoordinator,
    this.meshQueueSyncCoordinator,
    this.meshHealthMonitor,
  });

  final ISecurityService securityService;
  final IConnectionService connectionService;
  final IMeshNetworkingService meshNetworkingService;
  final MeshRelayCoordinator? meshRelayCoordinator;
  final MeshQueueSyncCoordinator? meshQueueSyncCoordinator;
  final MeshNetworkHealthMonitor? meshHealthMonitor;

  Iterable<Object?> get runtimeBindings sync* {
    yield securityService;
    yield connectionService;
    yield meshNetworkingService;
    yield meshRelayCoordinator;
    yield meshQueueSyncCoordinator;
    yield meshHealthMonitor;
  }
}

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
    this.databaseProvider,
    this.groupRepository,
    this.introHintRepository,
    this.exportService,
    this.importService,
    this.homeScreenFacadeFactory,
    this.chatConnectionManagerFactory,
    this.chatListCoordinatorFactory,
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
  final IDatabaseProvider? databaseProvider;
  final IGroupRepository? groupRepository;
  final IIntroHintRepository? introHintRepository;
  final IExportService? exportService;
  final IImportService? importService;
  final IHomeScreenFacadeFactory? homeScreenFacadeFactory;
  final IChatConnectionManagerFactory? chatConnectionManagerFactory;
  final IChatListCoordinatorFactory? chatListCoordinatorFactory;

  Iterable<Object?> get runtimeBindings sync* {
    yield this;
    yield contactRepository;
    yield messageRepository;
    yield archiveRepository;
    yield chatsRepository;
    yield userPreferences;
    yield preferencesRepository;
    yield repositoryProvider;
    yield sharedMessageQueueProvider;
    yield connectionService;
    yield meshNetworkingService;
    yield meshNetworkHealthMonitor;
    yield securityService;
    yield contactManagementService;
    yield chatManagementService;
    yield archiveManagementService;
    yield archiveSearchService;
    yield databaseProvider;
    yield groupRepository;
    yield introHintRepository;
    yield exportService;
    yield importService;
    yield homeScreenFacadeFactory;
    yield chatConnectionManagerFactory;
    yield chatListCoordinatorFactory;
  }
}

/// Explicit runtime composition registry used by `AppCore` and the provider
/// bridge during the GetIt retirement migration.
class AppRuntimeServicesRegistry {
  AppRuntimeServicesRegistry._();

  static AppRuntimeBindings? _bindings;
  static AppServices? _services;

  static AppServices get current {
    final services = _services;
    if (services == null) {
      throw StateError('AppServices have not been published yet.');
    }
    return services;
  }

  static AppServices? maybeCurrent() => _services;

  static void publishBindings(AppRuntimeBindings bindings) {
    _bindings = bindings;
  }

  static void publish(AppServices services) {
    _services = services;
    _bindings = null;
  }

  static void clear() {
    _bindings = null;
    _services = null;
  }

  static bool has<T extends Object>() => maybeResolve<T>() != null;

  static T? maybeResolve<T extends Object>() {
    final services = _services;
    if (services != null) {
      for (final candidate in services.runtimeBindings) {
        if (candidate is T) {
          return candidate;
        }
      }
    }

    final bindings = _bindings;
    if (bindings != null) {
      for (final candidate in bindings.runtimeBindings) {
        if (candidate is T) {
          return candidate;
        }
      }
    }

    return null;
  }
}
