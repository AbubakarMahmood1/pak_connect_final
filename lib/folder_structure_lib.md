# Project Structure: lib 
 
Generated on: Mon 10/20/2025  5:22:54.78 
Location: C:\dev\pak_connect\lib 
 
```tree 
Folder PATH listing
Volume serial number is B0CC-62E5
C:.
|   folder_structure.bat
|   folder_structure_lib.md
|   main.dart
|   
+---core
|   |   app_core.dart
|   |   
|   +---bluetooth
|   |       bluetooth_state_monitor.dart
|   |       handshake_coordinator.dart
|   |       peripheral_initializer.dart
|   |       smart_handshake_manager.dart
|   |       
|   +---compression
|   |       compression_config.dart
|   |       compression_stats.dart
|   |       compression_util.dart
|   |       
|   +---constants
|   |       ble_constants.dart
|   |       special_recipients.dart
|   |       
|   +---demo
|   |       mesh_demo_utils.dart
|   |       
|   +---discovery
|   |       batch_processor.dart
|   |       device_deduplication_manager.dart
|   |       
|   +---integration
|   +---messaging
|   |       gossip_sync_manager.dart
|   |       mesh_relay_engine.dart
|   |       message_router.dart
|   |       offline_message_queue.dart
|   |       queue_sync_manager.dart
|   |       relay_config_manager.dart
|   |       relay_policy.dart
|   |       
|   +---models
|   |       archive_models.dart
|   |       connection_info.dart
|   |       connection_state.dart
|   |       connection_status.dart
|   |       contact_group.dart
|   |       mesh_relay_models.dart
|   |       message_priority.dart
|   |       message_queue.dart
|   |       network_topology.dart
|   |       pairing_state.dart
|   |       protocol_message.dart
|   |       qr_contact_data.dart
|   |       security_state.dart
|   |       
|   +---networking
|   |       topology_manager.dart
|   |       
|   +---performance
|   |       performance_monitor.dart
|   |       
|   +---power
|   |       adaptive_power_manager.dart
|   |       battery_optimizer.dart
|   |       ephemeral_power_manager.dart
|   |       
|   +---routing
|   |       connection_quality_monitor.dart
|   |       network_topology_analyzer.dart
|   |       route_calculator.dart
|   |       routing_models.dart
|   |       smart_mesh_router.dart
|   |       
|   +---scanning
|   |       burst_scanning_controller.dart
|   |       
|   +---security
|   |   |   background_cache_service.dart
|   |   |   contact_recognizer.dart
|   |   |   ephemeral_key_manager.dart
|   |   |   hint_cache_manager.dart
|   |   |   message_security.dart
|   |   |   signing_manager.dart
|   |   |   spam_prevention_manager.dart
|   |   |   
|   |   \---noise
|   |       |   noise.dart
|   |       |   noise_encryption_service.dart
|   |       |   noise_handshake_exception.dart
|   |       |   noise_session.dart
|   |       |   noise_session_manager.dart
|   |       |   
|   |       +---models
|   |       |       noise_models.dart
|   |       |       
|   |       \---primitives
|   |               cipher_state.dart
|   |               dh_state.dart
|   |               handshake_state.dart
|   |               handshake_state_kk.dart
|   |               symmetric_state.dart
|   |               
|   +---services
|   |       hint_advertisement_service.dart
|   |       hint_scanner_service.dart
|   |       message_retry_coordinator.dart
|   |       navigation_service.dart
|   |       persistent_chat_state_manager.dart
|   |       security_manager.dart
|   |       simple_crypto.dart
|   |       
|   \---utils
|           app_logger.dart
|           chat_utils.dart
|           gcs_filter.dart
|           mesh_debug_logger.dart
|           message_fragmenter.dart
|           service_disposal_coordinator.dart
|           
+---data
|   +---database
|   |       database_backup_service.dart
|   |       database_encryption.dart
|   |       database_helper.dart
|   |       database_monitor_service.dart
|   |       database_query_optimizer.dart
|   |       migration_service.dart
|   |       
|   +---exceptions
|   |       connection_exceptions.dart
|   |       
|   +---models
|   |       ble_client_connection.dart
|   |       ble_server_connection.dart
|   |       connection_limit_config.dart
|   |       
|   +---repositories
|   |       archive_repository.dart
|   |       chats_repository.dart
|   |       contact_repository.dart
|   |       group_repository.dart
|   |       intro_hint_repository.dart
|   |       message_repository.dart
|   |       preferences_repository.dart
|   |       user_preferences.dart
|   |       
|   \---services
|       |   ble_connection_manager.dart
|       |   ble_message_handler.dart
|       |   ble_service.dart
|       |   ble_state_manager.dart
|       |   chat_migration_service.dart
|       |   seen_message_store.dart
|       |   
|       \---export_import
|               encryption_utils.dart
|               export_bundle.dart
|               export_service.dart
|               import_service.dart
|               selective_backup_service.dart
|               selective_restore_service.dart
|               
+---domain
|   +---entities
|   |       archived_chat.dart
|   |       archived_message.dart
|   |       chat_list_item.dart
|   |       enhanced_contact.dart
|   |       enhanced_message.dart
|   |       ephemeral_discovery_hint.dart
|   |       message.dart
|   |       sensitive_contact_hint.dart
|   |       
|   +---interfaces
|   |       i_notification_handler.dart
|   |       
|   \---services
|           archive_management_service.dart
|           archive_search_service.dart
|           auto_archive_scheduler.dart
|           background_notification_handler_impl.dart
|           chat_management_service.dart
|           contact_management_service.dart
|           group_messaging_service.dart
|           mesh_networking_service.dart
|           notification_handler_factory.dart
|           notification_service.dart
|           security_state_computer.dart
|           
\---presentation
    +---providers
    |       archive_provider.dart
    |       ble_providers.dart
    |       contact_provider.dart
    |       group_providers.dart
    |       mesh_networking_provider.dart
    |       security_state_provider.dart
    |       theme_provider.dart
    |       
    +---screens
    |       archive_detail_screen.dart
    |       archive_screen.dart
    |       chat_screen.dart
    |       contacts_screen.dart
    |       contact_detail_screen.dart
    |       create_group_screen.dart
    |       group_chat_screen.dart
    |       group_list_screen.dart
    |       home_screen.dart
    |       network_topology_screen.dart
    |       permission_screen.dart
    |       profile_screen.dart
    |       qr_contact_screen.dart
    |       settings_screen.dart
    |       
    +---theme
    |       app_theme.dart
    |       
    \---widgets
            archived_chat_tile.dart
            archive_context_menu.dart
            archive_search_delegate.dart
            archive_statistics_card.dart
            bluetooth_status_widget.dart
            burst_status_widget.dart
            chat_search_bar.dart
            contact_avatar.dart
            contact_list_tile.dart
            contact_request_dialog.dart
            delete_confirmation_dialog.dart
            device_tile.dart
            discovery_overlay.dart
            edit_name_dialog.dart
            empty_contacts_view.dart
            export_dialog.dart
            import_dialog.dart
            message_bubble.dart
            message_context_menu.dart
            modern_message_bubble.dart
            modern_search_delegate.dart
            pairing_dialog.dart
            passphrase_strength_indicator.dart
            queue_status_indicator.dart
            relay_queue_widget.dart
            restore_confirmation_dialog.dart
            routing_status_indicator.dart
            scanning_status_widget.dart
            security_level_badge.dart
            trust_status_badge.dart
            
``` 
 
## Detailed File List 
 
### Files by Directory 
 
 
**C:\dev\pak_connect\lib\core** 
- app_core.dart 
 
**C:\dev\pak_connect\lib\data** 
 
**C:\dev\pak_connect\lib\domain** 
 
**C:\dev\pak_connect\lib\presentation** 
 
**C:\dev\pak_connect\lib\core\bluetooth** 
- bluetooth_state_monitor.dart 
- handshake_coordinator.dart 
- peripheral_initializer.dart 
- smart_handshake_manager.dart 
 
**C:\dev\pak_connect\lib\core\compression** 
- compression_config.dart 
- compression_stats.dart 
- compression_util.dart 
 
**C:\dev\pak_connect\lib\core\constants** 
- ble_constants.dart 
- special_recipients.dart 
 
**C:\dev\pak_connect\lib\core\demo** 
- mesh_demo_utils.dart 
 
**C:\dev\pak_connect\lib\core\discovery** 
- batch_processor.dart 
- device_deduplication_manager.dart 
 
**C:\dev\pak_connect\lib\core\integration** 
 
**C:\dev\pak_connect\lib\core\messaging** 
- gossip_sync_manager.dart 
- mesh_relay_engine.dart 
- message_router.dart 
- offline_message_queue.dart 
- queue_sync_manager.dart 
- relay_config_manager.dart 
- relay_policy.dart 
 
**C:\dev\pak_connect\lib\core\models** 
- archive_models.dart 
- connection_info.dart 
- connection_state.dart 
- connection_status.dart 
- contact_group.dart 
- mesh_relay_models.dart 
- message_priority.dart 
- message_queue.dart 
- network_topology.dart 
- pairing_state.dart 
- protocol_message.dart 
- qr_contact_data.dart 
- security_state.dart 
 
**C:\dev\pak_connect\lib\core\networking** 
- topology_manager.dart 
 
**C:\dev\pak_connect\lib\core\performance** 
- performance_monitor.dart 
 
**C:\dev\pak_connect\lib\core\power** 
- adaptive_power_manager.dart 
- battery_optimizer.dart 
- ephemeral_power_manager.dart 
 
**C:\dev\pak_connect\lib\core\routing** 
- connection_quality_monitor.dart 
- network_topology_analyzer.dart 
- route_calculator.dart 
- routing_models.dart 
- smart_mesh_router.dart 
 
**C:\dev\pak_connect\lib\core\scanning** 
- burst_scanning_controller.dart 
 
**C:\dev\pak_connect\lib\core\security** 
- background_cache_service.dart 
- contact_recognizer.dart 
- ephemeral_key_manager.dart 
- hint_cache_manager.dart 
- message_security.dart 
- signing_manager.dart 
- spam_prevention_manager.dart 
 
**C:\dev\pak_connect\lib\core\services** 
- hint_advertisement_service.dart 
- hint_scanner_service.dart 
- message_retry_coordinator.dart 
- navigation_service.dart 
- persistent_chat_state_manager.dart 
- security_manager.dart 
- simple_crypto.dart 
 
**C:\dev\pak_connect\lib\core\utils** 
- app_logger.dart 
- chat_utils.dart 
- gcs_filter.dart 
- mesh_debug_logger.dart 
- message_fragmenter.dart 
- service_disposal_coordinator.dart 
 
**C:\dev\pak_connect\lib\core\security\noise** 
- noise.dart 
- noise_encryption_service.dart 
- noise_handshake_exception.dart 
- noise_session.dart 
- noise_session_manager.dart 
 
**C:\dev\pak_connect\lib\core\security\noise\models** 
- noise_models.dart 
 
**C:\dev\pak_connect\lib\core\security\noise\primitives** 
- cipher_state.dart 
- dh_state.dart 
- handshake_state.dart 
- handshake_state_kk.dart 
- symmetric_state.dart 
 
**C:\dev\pak_connect\lib\data\database** 
- database_backup_service.dart 
- database_encryption.dart 
- database_helper.dart 
- database_monitor_service.dart 
- database_query_optimizer.dart 
- migration_service.dart 
 
**C:\dev\pak_connect\lib\data\exceptions** 
- connection_exceptions.dart 
 
**C:\dev\pak_connect\lib\data\models** 
- ble_client_connection.dart 
- ble_server_connection.dart 
- connection_limit_config.dart 
 
**C:\dev\pak_connect\lib\data\repositories** 
- archive_repository.dart 
- chats_repository.dart 
- contact_repository.dart 
- group_repository.dart 
- intro_hint_repository.dart 
- message_repository.dart 
- preferences_repository.dart 
- user_preferences.dart 
 
**C:\dev\pak_connect\lib\data\services** 
- ble_connection_manager.dart 
- ble_message_handler.dart 
- ble_service.dart 
- ble_state_manager.dart 
- chat_migration_service.dart 
- seen_message_store.dart 
 
**C:\dev\pak_connect\lib\data\services\export_import** 
- encryption_utils.dart 
- export_bundle.dart 
- export_service.dart 
- import_service.dart 
- selective_backup_service.dart 
- selective_restore_service.dart 
 
**C:\dev\pak_connect\lib\domain\entities** 
- archived_chat.dart 
- archived_message.dart 
- chat_list_item.dart 
- enhanced_contact.dart 
- enhanced_message.dart 
- ephemeral_discovery_hint.dart 
- message.dart 
- sensitive_contact_hint.dart 
 
**C:\dev\pak_connect\lib\domain\interfaces** 
- i_notification_handler.dart 
 
**C:\dev\pak_connect\lib\domain\services** 
- archive_management_service.dart 
- archive_search_service.dart 
- auto_archive_scheduler.dart 
- background_notification_handler_impl.dart 
- chat_management_service.dart 
- contact_management_service.dart 
- group_messaging_service.dart 
- mesh_networking_service.dart 
- notification_handler_factory.dart 
- notification_service.dart 
- security_state_computer.dart 
 
**C:\dev\pak_connect\lib\presentation\providers** 
- archive_provider.dart 
- ble_providers.dart 
- contact_provider.dart 
- group_providers.dart 
- mesh_networking_provider.dart 
- security_state_provider.dart 
- theme_provider.dart 
 
**C:\dev\pak_connect\lib\presentation\screens** 
- archive_detail_screen.dart 
- archive_screen.dart 
- chat_screen.dart 
- contacts_screen.dart 
- contact_detail_screen.dart 
- create_group_screen.dart 
- group_chat_screen.dart 
- group_list_screen.dart 
- home_screen.dart 
- network_topology_screen.dart 
- permission_screen.dart 
- profile_screen.dart 
- qr_contact_screen.dart 
- settings_screen.dart 
 
**C:\dev\pak_connect\lib\presentation\theme** 
- app_theme.dart 
 
**C:\dev\pak_connect\lib\presentation\widgets** 
- archived_chat_tile.dart 
- archive_context_menu.dart 
- archive_search_delegate.dart 
- archive_statistics_card.dart 
- bluetooth_status_widget.dart 
- burst_status_widget.dart 
- chat_search_bar.dart 
- contact_avatar.dart 
- contact_list_tile.dart 
- contact_request_dialog.dart 
- delete_confirmation_dialog.dart 
- device_tile.dart 
- discovery_overlay.dart 
- edit_name_dialog.dart 
- empty_contacts_view.dart 
- export_dialog.dart 
- import_dialog.dart 
- message_bubble.dart 
- message_context_menu.dart 
- modern_message_bubble.dart 
- modern_search_delegate.dart 
- pairing_dialog.dart 
- passphrase_strength_indicator.dart 
- queue_status_indicator.dart 
- relay_queue_widget.dart 
- restore_confirmation_dialog.dart 
- routing_status_indicator.dart 
- scanning_status_widget.dart 
- security_level_badge.dart 
- trust_status_badge.dart 
 
**C:\dev\pak_connect\lib (Root)** 
- folder_structure.bat 
- folder_structure_lib.md 
- main.dart 
 
