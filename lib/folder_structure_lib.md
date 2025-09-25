# Project Structure: lib 
 
Generated on: Thu 09/25/2025 13:04:10.60 
Location: C:\Users\theab\OneDrive\Desktop\pak_connect\lib 
 
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
|   +---constants
|   |       ble_constants.dart
|   |       
|   +---demo
|   |       mesh_demo_utils.dart
|   |       
|   +---discovery
|   |       batch_processor.dart
|   |       device_deduplication_manager.dart
|   |       
|   +---integration
|   |       app_integration_service.dart
|   |       
|   +---messaging
|   |       mesh_relay_engine.dart
|   |       offline_message_queue.dart
|   |       queue_sync_manager.dart
|   |       
|   +---models
|   |       archive_models.dart
|   |       connection_info.dart
|   |       connection_state.dart
|   |       connection_status.dart
|   |       mesh_relay_models.dart
|   |       message_priority.dart
|   |       message_queue.dart
|   |       pairing_state.dart
|   |       protocol_message.dart
|   |       qr_contact_data.dart
|   |       security_state.dart
|   |       
|   +---performance
|   |       performance_monitor.dart
|   |       
|   +---power
|   |       adaptive_power_manager.dart
|   |       ephemeral_power_manager.dart
|   |       
|   +---routing
|   |       connection_quality_monitor.dart
|   |       network_topology_analyzer.dart
|   |       route_calculator.dart
|   |       routing_models.dart
|   |       smart_mesh_router.dart
|   |       
|   +---security
|   |       background_cache_service.dart
|   |       contact_recognizer.dart
|   |       ephemeral_key_manager.dart
|   |       hint_cache_manager.dart
|   |       message_security.dart
|   |       signing_manager.dart
|   |       spam_prevention_manager.dart
|   |       
|   +---services
|   |       message_retry_coordinator.dart
|   |       persistent_chat_state_manager.dart
|   |       security_manager.dart
|   |       simple_crypto.dart
|   |       
|   \---utils
|           chat_utils.dart
|           mesh_debug_logger.dart
|           message_fragmenter.dart
|           service_disposal_coordinator.dart
|           
+---data
|   +---repositories
|   |       archive_repository.dart
|   |       chats_repository.dart
|   |       contact_repository.dart
|   |       message_queue_repository.dart
|   |       message_repository.dart
|   |       user_preferences.dart
|   |       
|   \---services
|           ble_connection_manager.dart
|           ble_message_handler.dart
|           ble_service.dart
|           ble_state_manager.dart
|           
+---domain
|   +---entities
|   |       archived_chat.dart
|   |       archived_message.dart
|   |       chat_list_item.dart
|   |       enhanced_contact.dart
|   |       enhanced_message.dart
|   |       message.dart
|   |       
|   \---services
|           archive_management_service.dart
|           archive_search_service.dart
|           chat_management_service.dart
|           contact_management_service.dart
|           mesh_networking_service.dart
|           security_state_computer.dart
|           
\---presentation
    +---providers
    |       archive_provider.dart
    |       ble_providers.dart
    |       mesh_networking_provider.dart
    |       security_state_provider.dart
    |       
    +---screens
    |       archive_detail_screen.dart
    |       archive_screen.dart
    |       chats_screen.dart
    |       chat_screen.dart
    |       permission_screen.dart
    |       qr_contact_screen.dart
    |       
    +---theme
    |       app_theme.dart
    |       
    \---widgets
            archived_chat_tile.dart
            archive_context_menu.dart
            archive_search_delegate.dart
            archive_statistics_card.dart
            chat_search_bar.dart
            contact_request_dialog.dart
            delete_confirmation_dialog.dart
            device_tile.dart
            discovery_overlay.dart
            edit_name_dialog.dart
            message_bubble.dart
            message_context_menu.dart
            modern_message_bubble.dart
            modern_search_delegate.dart
            pairing_dialog.dart
            queue_status_indicator.dart
            relay_queue_widget.dart
            restore_confirmation_dialog.dart
            routing_status_indicator.dart
            
``` 
 
## Detailed File List 
 
### Files by Directory 
 
 
**C:\Users\theab\OneDrive\Desktop\pak_connect\lib\core** 
- app_core.dart 
 
**C:\Users\theab\OneDrive\Desktop\pak_connect\lib\data** 
 
**C:\Users\theab\OneDrive\Desktop\pak_connect\lib\domain** 
 
**C:\Users\theab\OneDrive\Desktop\pak_connect\lib\presentation** 
 
**C:\Users\theab\OneDrive\Desktop\pak_connect\lib\core\constants** 
- ble_constants.dart 
 
**C:\Users\theab\OneDrive\Desktop\pak_connect\lib\core\demo** 
- mesh_demo_utils.dart 
 
**C:\Users\theab\OneDrive\Desktop\pak_connect\lib\core\discovery** 
- batch_processor.dart 
- device_deduplication_manager.dart 
 
**C:\Users\theab\OneDrive\Desktop\pak_connect\lib\core\integration** 
- app_integration_service.dart 
 
**C:\Users\theab\OneDrive\Desktop\pak_connect\lib\core\messaging** 
- mesh_relay_engine.dart 
- offline_message_queue.dart 
- queue_sync_manager.dart 
 
**C:\Users\theab\OneDrive\Desktop\pak_connect\lib\core\models** 
- archive_models.dart 
- connection_info.dart 
- connection_state.dart 
- connection_status.dart 
- mesh_relay_models.dart 
- message_priority.dart 
- message_queue.dart 
- pairing_state.dart 
- protocol_message.dart 
- qr_contact_data.dart 
- security_state.dart 
 
**C:\Users\theab\OneDrive\Desktop\pak_connect\lib\core\performance** 
- performance_monitor.dart 
 
**C:\Users\theab\OneDrive\Desktop\pak_connect\lib\core\power** 
- adaptive_power_manager.dart 
- ephemeral_power_manager.dart 
 
**C:\Users\theab\OneDrive\Desktop\pak_connect\lib\core\routing** 
- connection_quality_monitor.dart 
- network_topology_analyzer.dart 
- route_calculator.dart 
- routing_models.dart 
- smart_mesh_router.dart 
 
**C:\Users\theab\OneDrive\Desktop\pak_connect\lib\core\security** 
- background_cache_service.dart 
- contact_recognizer.dart 
- ephemeral_key_manager.dart 
- hint_cache_manager.dart 
- message_security.dart 
- signing_manager.dart 
- spam_prevention_manager.dart 
 
**C:\Users\theab\OneDrive\Desktop\pak_connect\lib\core\services** 
- message_retry_coordinator.dart 
- persistent_chat_state_manager.dart 
- security_manager.dart 
- simple_crypto.dart 
 
**C:\Users\theab\OneDrive\Desktop\pak_connect\lib\core\utils** 
- chat_utils.dart 
- mesh_debug_logger.dart 
- message_fragmenter.dart 
- service_disposal_coordinator.dart 
 
**C:\Users\theab\OneDrive\Desktop\pak_connect\lib\data\repositories** 
- archive_repository.dart 
- chats_repository.dart 
- contact_repository.dart 
- message_queue_repository.dart 
- message_repository.dart 
- user_preferences.dart 
 
**C:\Users\theab\OneDrive\Desktop\pak_connect\lib\data\services** 
- ble_connection_manager.dart 
- ble_message_handler.dart 
- ble_service.dart 
- ble_state_manager.dart 
 
**C:\Users\theab\OneDrive\Desktop\pak_connect\lib\domain\entities** 
- archived_chat.dart 
- archived_message.dart 
- chat_list_item.dart 
- enhanced_contact.dart 
- enhanced_message.dart 
- message.dart 
 
**C:\Users\theab\OneDrive\Desktop\pak_connect\lib\domain\services** 
- archive_management_service.dart 
- archive_search_service.dart 
- chat_management_service.dart 
- contact_management_service.dart 
- mesh_networking_service.dart 
- security_state_computer.dart 
 
**C:\Users\theab\OneDrive\Desktop\pak_connect\lib\presentation\providers** 
- archive_provider.dart 
- ble_providers.dart 
- mesh_networking_provider.dart 
- security_state_provider.dart 
 
**C:\Users\theab\OneDrive\Desktop\pak_connect\lib\presentation\screens** 
- archive_detail_screen.dart 
- archive_screen.dart 
- chats_screen.dart 
- chat_screen.dart 
- permission_screen.dart 
- qr_contact_screen.dart 
 
**C:\Users\theab\OneDrive\Desktop\pak_connect\lib\presentation\theme** 
- app_theme.dart 
 
**C:\Users\theab\OneDrive\Desktop\pak_connect\lib\presentation\widgets** 
- archived_chat_tile.dart 
- archive_context_menu.dart 
- archive_search_delegate.dart 
- archive_statistics_card.dart 
- chat_search_bar.dart 
- contact_request_dialog.dart 
- delete_confirmation_dialog.dart 
- device_tile.dart 
- discovery_overlay.dart 
- edit_name_dialog.dart 
- message_bubble.dart 
- message_context_menu.dart 
- modern_message_bubble.dart 
- modern_search_delegate.dart 
- pairing_dialog.dart 
- queue_status_indicator.dart 
- relay_queue_widget.dart 
- restore_confirmation_dialog.dart 
- routing_status_indicator.dart 
 
**C:\Users\theab\OneDrive\Desktop\pak_connect\lib (Root)** 
- folder_structure.bat 
- folder_structure_lib.md 
- main.dart 
 
