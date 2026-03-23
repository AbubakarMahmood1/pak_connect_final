import 'package:logging/logging.dart';
import 'package:pak_connect/data/database/database_provider.dart';
import 'package:pak_connect/data/repositories/archive_repository.dart';
import 'package:pak_connect/data/repositories/chats_repository.dart';
import 'package:pak_connect/data/repositories/contact_repository.dart';
import 'package:pak_connect/data/repositories/group_repository.dart';
import 'package:pak_connect/data/repositories/intro_hint_repository.dart';
import 'package:pak_connect/data/repositories/message_repository.dart';
import 'package:pak_connect/data/repositories/preferences_repository.dart';
import 'package:pak_connect/data/repositories/user_preferences.dart';
import 'package:pak_connect/data/services/ble_message_handler.dart';
import 'package:pak_connect/data/services/ble_message_handler_facade.dart';
import 'package:pak_connect/data/services/ble_message_handler_facade_impl.dart';
import 'package:pak_connect/data/services/ble_handshake_service.dart';
import 'package:pak_connect/data/services/ble_service_facade.dart';
import 'package:pak_connect/data/services/ble_service_facade_factory.dart';
import 'package:pak_connect/data/services/ble_state_manager.dart';
import 'package:pak_connect/data/services/ble_state_manager_facade.dart';
import 'package:pak_connect/data/services/ephemeral_contact_cleaner.dart';
import 'package:pak_connect/data/services/export_import/export_service_adapter.dart';
import 'package:pak_connect/data/services/export_import/import_service_adapter.dart';
import 'package:pak_connect/data/services/mesh_routing_service.dart';
import 'package:pak_connect/data/services/mesh_relay_handler.dart';
import 'package:pak_connect/data/services/protocol_message_handler.dart';
import 'package:pak_connect/data/services/relay_coordinator.dart';
import 'package:pak_connect/data/services/seen_message_store.dart';
import 'package:pak_connect/domain/interfaces/i_archive_repository.dart';
import 'package:pak_connect/domain/interfaces/i_ble_handshake_service.dart';
import 'package:pak_connect/domain/interfaces/i_ble_message_handler_facade.dart';
import 'package:pak_connect/domain/interfaces/i_ble_service_facade_factory.dart';
import 'package:pak_connect/domain/interfaces/i_ble_state_manager_facade.dart';
import 'package:pak_connect/domain/interfaces/i_chats_repository.dart';
import 'package:pak_connect/domain/interfaces/i_contact_repository.dart';
import 'package:pak_connect/domain/interfaces/i_database_provider.dart';
import 'package:pak_connect/domain/interfaces/i_export_service.dart';
import 'package:pak_connect/domain/interfaces/i_group_repository.dart';
import 'package:pak_connect/domain/interfaces/i_identity_manager.dart';
import 'package:pak_connect/domain/interfaces/i_import_service.dart';
import 'package:pak_connect/domain/interfaces/i_intro_hint_repository.dart';
import 'package:pak_connect/domain/interfaces/i_message_repository.dart';
import 'package:pak_connect/domain/interfaces/i_message_queue_repository.dart';
import 'package:pak_connect/domain/interfaces/i_handshake_coordinator_factory.dart';
import 'package:pak_connect/domain/interfaces/i_mesh_relay_engine_factory.dart';
import 'package:pak_connect/domain/interfaces/i_mesh_routing_service.dart';
import 'package:pak_connect/domain/interfaces/i_preferences_repository.dart';
import 'package:pak_connect/domain/interfaces/i_seen_message_store.dart';
import 'package:pak_connect/domain/interfaces/i_service_registry.dart';
import 'package:pak_connect/domain/interfaces/i_shared_message_queue_provider.dart';
import 'package:pak_connect/domain/interfaces/i_user_preferences.dart';

/// Registers concrete data-layer implementations into the composition registry.
///
/// Core DI setup should call this hook instead of importing concrete data types.
Future<void> registerDataLayerServices(
  IServiceRegistry services,
  Logger logger,
) async {
  BLEHandshakeService.configureCoordinatorFactoryResolver(
    () => services.resolve<IHandshakeCoordinatorFactory>(),
  );
  BLEServiceFacade.configureHandshakeServiceRegistrar((handshakeService) {
    if (!services.isRegistered<IBLEHandshakeService>()) {
      services.registerSingleton<IBLEHandshakeService>(handshakeService);
    }
  });
  BLEMessageHandlerFacade.configureDependencyResolvers(
    handshakeServiceResolver: () {
      if (services.isRegistered<IBLEHandshakeService>()) {
        return services.resolve<IBLEHandshakeService>();
      }
      return null;
    },
    seenMessageStoreResolver: () {
      if (services.isRegistered<ISeenMessageStore>()) {
        return services.resolve<ISeenMessageStore>();
      }
      return null;
    },
  );
  BLEMessageHandlerFacadeImpl.configureDependencyResolvers(
    legacyStateManagerResolver: () {
      if (services.isRegistered<BLEStateManagerFacade>()) {
        return services.resolve<BLEStateManagerFacade>().legacyStateManager;
      }
      if (services.isRegistered<IBLEStateManagerFacade>()) {
        final facade = services.resolve<IBLEStateManagerFacade>();
        if (facade is BLEStateManagerFacade) {
          return facade.legacyStateManager;
        }
      }
      if (services.isRegistered<BLEStateManager>()) {
        return services.resolve<BLEStateManager>();
      }
      return null;
    },
    sharedQueueProviderResolver: () {
      if (services.isRegistered<ISharedMessageQueueProvider>()) {
        return services.resolve<ISharedMessageQueueProvider>();
      }
      return null;
    },
  );
  ProtocolMessageHandler.configureIdentityManagerResolver(() {
    if (services.isRegistered<IIdentityManager>()) {
      return services.resolve<IIdentityManager>();
    }
    return null;
  });
  RelayCoordinator.configureDependencyResolvers(
    sharedQueueProviderResolver: () {
      if (services.isRegistered<ISharedMessageQueueProvider>()) {
        return services.resolve<ISharedMessageQueueProvider>();
      }
      return null;
    },
    relayEngineFactoryResolver: () =>
        services.resolve<IMeshRelayEngineFactory>(),
  );
  MeshRelayHandler.configureRelayEngineFactoryResolver(
    () => services.resolve<IMeshRelayEngineFactory>(),
  );
  EphemeralContactCleaner.configureQueueRepositoryResolver(() {
    if (services.isRegistered<IMessageQueueRepository>()) {
      return services.resolve<IMessageQueueRepository>();
    }
    return null;
  });

  // ===========================
  // REPOSITORIES
  // ===========================
  if (!services.isRegistered<ContactRepository>()) {
    services.registerSingleton<ContactRepository>(ContactRepository());
    logger.fine('✅ ContactRepository registered');
  } else {
    logger.fine('ℹ️ ContactRepository already registered');
  }

  if (!services.isRegistered<IContactRepository>()) {
    services.registerSingleton<IContactRepository>(
      services.resolve<ContactRepository>(),
    );
    logger.fine('✅ IContactRepository registered (data registrar)');
  }

  if (!services.isRegistered<MessageRepository>()) {
    services.registerSingleton<MessageRepository>(MessageRepository());
    logger.fine('✅ MessageRepository registered');
  } else {
    logger.fine('ℹ️ MessageRepository already registered');
  }

  if (!services.isRegistered<IMessageRepository>()) {
    services.registerSingleton<IMessageRepository>(
      services.resolve<MessageRepository>(),
    );
    logger.fine('✅ IMessageRepository registered (data registrar)');
  }

  if (!services.isRegistered<ArchiveRepository>()) {
    services.registerSingleton<ArchiveRepository>(ArchiveRepository());
    logger.fine('✅ ArchiveRepository registered');
  } else {
    logger.fine('ℹ️ ArchiveRepository already registered');
  }

  if (!services.isRegistered<ChatsRepository>()) {
    services.registerSingleton<ChatsRepository>(ChatsRepository());
    logger.fine('✅ ChatsRepository registered');
  } else {
    logger.fine('ℹ️ ChatsRepository already registered');
  }

  if (!services.isRegistered<PreferencesRepository>()) {
    services.registerSingleton<PreferencesRepository>(PreferencesRepository());
    logger.fine('✅ PreferencesRepository registered');
  } else {
    logger.fine('ℹ️ PreferencesRepository already registered');
  }

  if (!services.isRegistered<GroupRepository>()) {
    services.registerSingleton<GroupRepository>(GroupRepository());
    logger.fine('✅ GroupRepository registered');
  } else {
    logger.fine('ℹ️ GroupRepository already registered');
  }

  if (!services.isRegistered<IntroHintRepository>()) {
    services.registerSingleton<IntroHintRepository>(IntroHintRepository());
    logger.fine('✅ IntroHintRepository registered');
  } else {
    logger.fine('ℹ️ IntroHintRepository already registered');
  }

  if (!services.isRegistered<MeshRoutingService>()) {
    services.registerSingleton<MeshRoutingService>(MeshRoutingService());
    logger.fine('✅ MeshRoutingService registered');
  } else {
    logger.fine('ℹ️ MeshRoutingService already registered');
  }

  // ===========================
  // INTERFACE BINDINGS
  // ===========================
  if (!services.isRegistered<IMeshRoutingService>()) {
    services.registerSingleton<IMeshRoutingService>(
      services.resolve<MeshRoutingService>(),
    );
    logger.fine('✅ IMeshRoutingService registered');
  }

  if (!services.isRegistered<IArchiveRepository>()) {
    services.registerSingleton<IArchiveRepository>(
      services.resolve<ArchiveRepository>(),
    );
    logger.fine('✅ IArchiveRepository registered');
  }

  if (!services.isRegistered<IChatsRepository>()) {
    services.registerSingleton<IChatsRepository>(
      services.resolve<ChatsRepository>(),
    );
    logger.fine('✅ IChatsRepository registered');
  }

  if (!services.isRegistered<IPreferencesRepository>()) {
    services.registerSingleton<IPreferencesRepository>(
      services.resolve<PreferencesRepository>(),
    );
    logger.fine('✅ IPreferencesRepository registered');
  }

  if (!services.isRegistered<IUserPreferences>()) {
    services.registerSingleton<IUserPreferences>(UserPreferences());
    logger.fine('✅ IUserPreferences registered');
  }

  if (!services.isRegistered<IGroupRepository>()) {
    services.registerSingleton<IGroupRepository>(
      services.resolve<GroupRepository>(),
    );
    logger.fine('✅ IGroupRepository registered');
  }

  if (!services.isRegistered<IIntroHintRepository>()) {
    services.registerSingleton<IIntroHintRepository>(
      services.resolve<IntroHintRepository>(),
    );
    logger.fine('✅ IIntroHintRepository registered');
  }

  if (!services.isRegistered<IExportService>()) {
    services.registerLazySingleton<IExportService>(
      () => const ExportServiceAdapter(),
    );
    logger.fine('✅ IExportService registered');
  }

  if (!services.isRegistered<IImportService>()) {
    services.registerLazySingleton<IImportService>(
      () => const ImportServiceAdapter(),
    );
    logger.fine('✅ IImportService registered');
  }

  if (!services.isRegistered<ISeenMessageStore>()) {
    services.registerSingleton<ISeenMessageStore>(SeenMessageStore());
    logger.fine('✅ ISeenMessageStore registered');
  }

  if (!services.isRegistered<IDatabaseProvider>()) {
    services.registerSingleton<IDatabaseProvider>(DatabaseProvider());
    logger.fine('✅ IDatabaseProvider registered');
  }

  if (!services.isRegistered<ISharedMessageQueueProvider>()) {
    throw StateError(
      'ISharedMessageQueueProvider must be registered before data services.',
    );
  }

  if (!services.isRegistered<IBLEMessageHandlerFacade>()) {
    services.registerLazySingleton<IBLEMessageHandlerFacade>(
      () => BLEMessageHandlerFacadeImpl(
        BLEMessageHandler(),
        services.resolve<ISeenMessageStore>(),
        sharedQueueProvider: services.resolve<ISharedMessageQueueProvider>(),
      ),
    );
    logger.fine('✅ IBLEMessageHandlerFacade registered');
  }

  if (!services.isRegistered<IBLEServiceFacadeFactory>()) {
    services.registerLazySingleton<IBLEServiceFacadeFactory>(
      () => const DataBleServiceFacadeFactory(),
    );
    logger.fine('✅ IBLEServiceFacadeFactory registered');
  }
}

