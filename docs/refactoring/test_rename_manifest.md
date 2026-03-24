# Test Rename Manifest

Generated: 2026-03-24

## Naming Rule

- Drop `phaseNN` from the filename.
- Keep the file in the same directory.
- Use the first real `group()` / `test()` label as the behavior seed for the new suffix.
- If two files still collide after behavior naming, append a numeric suffix for uniqueness.

## Inventory

| Old Path | Proposed New Path | Basis |
| --- | --- | --- |
| `test/core/app_core_phase11_test.dart` | `test/core/app_core_lifecycle_test.dart` | AppCore lifecycle |
| `test/core/app_core_phase13_test.dart` | `test/core/app_core_singleton_test.dart` | AppCore singleton |
| `test/core/app_core_phase6_guardrails_test.dart` | `test/core/app_core_guardrail_behaviors_test.dart` | AppCore phase 6.4 guardrails |
| `test/core/config/relay_connection_compression_phase12_test.dart` | `test/core/config/relay_connection_compression_config_manager_test.dart` | RelayConfigManager |
| `test/core/di/phase3_integration_flows_test.dart` | `test/core/di/integration_flows_end_to_end_test.dart` | Phase 3: End-to-End Integration Flows |
| `test/core/messaging/mesh_relay_engine_phase12_test.dart` | `test/core/messaging/mesh_relay_engine_initialize_test.dart` | initialize |
| `test/core/messaging/mesh_relay_engine_phase13_test.dart` | `test/core/messaging/mesh_relay_engine_statistics_accumulation_test.dart` | statistics accumulation |
| `test/core/messaging/offline_message_queue_phase12_test.dart` | `test/core/messaging/offline_message_queue_store_test.dart` | QueueStore |
| `test/core/messaging/offline_message_queue_phase13_test.dart` | `test/core/messaging/offline_message_queue_change_priority_test.dart` | OfflineMessageQueue — changePriority |
| `test/core/messaging/offline_message_queue_phase13b_test.dart` | `test/core/messaging/offline_message_queue_mark_delivered_edge_cases_test.dart` | OfflineMessageQueue — markMessageDelivered edge cases |
| `test/core/messaging/offline_queue_maintenance_phase13_test.dart` | `test/core/messaging/offline_queue_maintenance_calculate_average_delivery_time_via_get_statistics_test.dart` | calculateAverageDeliveryTime (via getStatistics) |
| `test/core/messaging/offline_queue_store_phase13_test.dart` | `test/core/messaging/offline_queue_store_has_database_provider_test.dart` | hasDatabaseProvider |
| `test/core/messaging/relay_phase1_test.dart` | `test/core/messaging/relay_config_manager_test.dart` | Phase 1: Relay Config Manager |
| `test/core/messaging/relay_phase2_test.dart` | `test/core/messaging/relay_protocol_message_message_type_serialization_test.dart` | Phase 2: ProtocolMessage Message Type Serialization |
| `test/core/messaging/relay_phase3_test.dart` | `test/core/messaging/relay_network_size_tracking_test.dart` | Phase 3: Network Size Tracking |
| `test/core/messaging/relay_pipeline_decision_policy_phase12_test.dart` | `test/core/messaging/relay_pipeline_decision_policy_send_test.dart` | RelaySendPipeline |
| `test/core/security/peer_protocol_version_guard_phase13_test.dart` | `test/core/security/peer_protocol_version_guard_coverage_test.dart` | PeerProtocolVersionGuard |
| `test/core/services/security_manager_phase11_test.dart` | `test/core/services/security_manager_get_current_level_test.dart` | SecurityManager.getCurrentLevel |
| `test/core/services/security_manager_phase12_15_test.dart` | `test/core/services/security_manager_identity_mapping_null_guards_test.dart` | SecurityManager — identity mapping null guards |
| `test/core/services/security_manager_phase12_test.dart` | `test/core/services/security_manager_get_encryption_method_test.dart` | SecurityManager - getEncryptionMethod |
| `test/core/services/security_manager_phase13_test.dart` | `test/core/services/security_manager_get_current_level_session_id_for_noise_resolution_test.dart` | getCurrentLevel — sessionIdForNoise resolution |
| `test/core/services/security_manager_phase13b_test.dart` | `test/core/services/security_manager_has_established_noise_session_test.dart` | hasEstablishedNoiseSession |
| `test/core/services/security_manager_phase13c_test.dart` | `test/core/services/security_manager_initialize_failure_path_line_63_test.dart` | initialize — failure path (line 63) |
| `test/data/database/database_helper_phase13_test.dart` | `test/data/database/database_helper_set_test_name_test.dart` | DatabaseHelper.setTestDatabaseName |
| `test/data/database/database_helper_phase13b_test.dart` | `test/data/database/database_helper_index_verification_test.dart` | DatabaseHelper index verification |
| `test/data/database/database_helper_phase13c_test.dart` | `test/data/database/database_helper_test_on_configure_test.dart` | testOnConfigure |
| `test/data/database/database_monitor_service_phase12_test.dart` | `test/data/database/database_monitor_service_snapshot_serialization_test.dart` | DatabaseSnapshot serialization |
| `test/data/database/database_monitor_service_phase13_test.dart` | `test/data/database/database_monitor_service_snapshot_from_json_to_json_round_trip_test.dart` | DatabaseSnapshot — fromJson/toJson round-trip |
| `test/data/database/database_monitor_service_phase13b_test.dart` | `test/data/database/database_monitor_service_growth_statistics_growth_mb_test.dart` | GrowthStatistics — growthMB |
| `test/data/database/database_query_optimizer_phase12_test.dart` | `test/data/database/database_query_optimizer_statistics_model_test.dart` | QueryStatistics model |
| `test/data/database/migration_service_phase12_test.dart` | `test/data/database/migration_service_result_test.dart` | MigrationResult |
| `test/data/repositories/archive_repository_mapping_helper_phase13_test.dart` | `test/data/repositories/archive_repository_mapping_helper_map_to_archived_message_null_handling_test.dart` | mapToArchivedMessage — null handling |
| `test/data/repositories/archive_repository_phase12_test.dart` | `test/data/repositories/archive_repository_get_archived_chats_count_test.dart` | ArchiveRepository.getArchivedChatsCount |
| `test/data/repositories/archive_repository_phase13_test.dart` | `test/data/repositories/archive_repository_chat_test.dart` | ArchiveRepository.archiveChat |
| `test/data/repositories/contact_repository_phase12_test.dart` | `test/data/repositories/contact_repository_statistics_methods_test.dart` | ContactRepository — Statistics Methods |
| `test/data/services/inbound_text_processor_phase12_test.dart` | `test/data/services/inbound_text_processor_self_originated_message_drop_test.dart` | Self-originated message drop |
| `test/data/services/outbound_message_sender_phase13_test.dart` | `test/data/services/outbound_message_sender_send_binary_payload_test.dart` | sendBinaryPayload |
| `test/data/services/outbound_message_sender_phase13b_test.dart` | `test/data/services/outbound_message_sender_send_binary_payload_error_handling_test.dart` | sendBinaryPayload error handling |
| `test/data/services/outbound_message_sender_phase13c_test.dart` | `test/data/services/outbound_message_sender_send_central_test.dart` | sendCentralMessage |
| `test/data/services/pairing_flow_controller_phase12_test.dart` | `test/data/services/pairing_flow_controller_accessors_callbacks_test.dart` | PairingFlowController — accessors & callbacks |
| `test/data/services/pairing_lifecycle_service_phase12_test.dart` | `test/data/services/pairing_lifecycle_service_ensure_contact_exists_after_handshake_test.dart` | ensureContactExistsAfterHandshake |
| `test/data/services/pairing_service_phase12_test.dart` | `test/data/services/pairing_service_initiate_request_test.dart` | PairingService - initiatePairingRequest |
| `test/data/services/protocol_message_handler_phase12_test.dart` | `test/data/services/protocol_message_handler_contact_request_dispatch_test.dart` | contactRequest dispatch |
| `test/data/services/protocol_message_handler_phase13_test.dart` | `test/data/services/protocol_message_handler_dispatch_branches_test.dart` | contactRequest dispatch |
| `test/data/services/relay_coordinator_phase13_test.dart` | `test/data/services/relay_coordinator_edge_cases_test.dart` | RelayCoordinator — Phase 13.2 |
| `test/domain/messaging/gossip_sync_manager_phase12_test.dart` | `test/domain/messaging/gossip_sync_manager_battery_emergency_mode_test.dart` | GossipSyncManager — battery emergency mode |
| `test/domain/messaging/queue_sync_manager_phase11_test.dart` | `test/domain/messaging/queue_sync_manager_construction_test.dart` | QueueSyncManager construction |
| `test/domain/messaging/queue_sync_manager_phase13_test.dart` | `test/domain/messaging/queue_sync_manager_force_all_test.dart` | forceSyncAll |
| `test/domain/models/archive_models_phase12_test.dart` | `test/domain/models/archive_models_search_result_test.dart` | ArchiveSearchResult |
| `test/domain/routing/network_topology_analyzer_phase12_test.dart` | `test/domain/routing/network_topology_analyzer_basic_test.dart` | NetworkTopologyAnalyzer — basic topology |
| `test/domain/routing/network_topology_analyzer_phase13_test.dart` | `test/domain/routing/network_topology_analyzer_initialize_test.dart` | NetworkTopologyAnalyzer — initialize |
| `test/domain/routing/route_calculator_phase13_test.dart` | `test/domain/routing/route_calculator_direct_scoring_per_connection_quality_test.dart` | Direct route scoring per ConnectionQuality |
| `test/domain/services/adaptive_power_manager_phase13_test.dart` | `test/domain/services/adaptive_power_manager_rssi_threshold_and_max_connections_per_mode_test.dart` | rssiThreshold and maxConnections per power mode |
| `test/domain/services/archive_maintenance_policy_phase12_test.dart` | `test/domain/services/archive_maintenance_policy_coverage_test.dart` | ArchiveMaintenance |
| `test/domain/services/archive_management_service_phase12_test.dart` | `test/domain/services/archive_management_service_get_enhanced_summaries_test.dart` | getEnhancedArchiveSummaries |
| `test/domain/services/archive_management_service_phase13_test.dart` | `test/domain/services/archive_management_service_chat_validation_failures_test.dart` | archiveChat validation failures |
| `test/domain/services/archive_search_models_phase12_test.dart` | `test/domain/services/archive_search_models_service_config_test.dart` | SearchServiceConfig |
| `test/domain/services/archive_search_service_phase12_test.dart` | `test/domain/services/archive_search_service_fuzzy_test.dart` | fuzzySearch |
| `test/domain/services/background_notification_handler_impl_phase13_test.dart` | `test/domain/services/background_notification_handler_impl_initialize_test.dart` | initialize |
| `test/domain/services/bluetooth_state_monitor_phase11_test.dart` | `test/domain/services/bluetooth_state_monitor_info_test.dart` | BluetoothStateInfo |
| `test/domain/services/bluetooth_state_monitor_phase13_test.dart` | `test/domain/services/bluetooth_state_monitor_info_extended_test.dart` | BluetoothStateInfo extended |
| `test/domain/services/bluetooth_state_monitor_phase13b_test.dart` | `test/domain/services/bluetooth_state_monitor_stream_multi_listener_isolation_test.dart` | stateStream — multi-listener isolation |
| `test/domain/services/burst_bluetooth_supplement_phase12_test.dart` | `test/domain/services/burst_bluetooth_supplement_scanning_controller_test.dart` | BurstScanningController — supplement |
| `test/domain/services/burst_scanning_controller_phase12_test.dart` | `test/domain/services/burst_scanning_controller_uninitialized_state_test.dart` | BurstScanningController — uninitialized state |
| `test/domain/services/burst_scanning_controller_phase13_test.dart` | `test/domain/services/burst_scanning_controller_uninitialized_edge_cases_test.dart` | BurstScanningController — uninitialized edge cases |
| `test/domain/services/burst_scanning_controller_phase13b_test.dart` | `test/domain/services/burst_scanning_controller_status_model_extras_test.dart` | BurstScanningStatus model extras |
| `test/domain/services/burst_scanning_controller_phase13c_test.dart` | `test/domain/services/burst_scanning_controller_bt_ready_scan_start_happy_path_test.dart` | BT ready – scan start happy path |
| `test/domain/services/chat_lifecycle_service_phase11_test.dart` | `test/domain/services/chat_lifecycle_service_4_gap_coverage_test.dart` | ChatLifecycleService – Phase 11.4 gap coverage |
| `test/domain/services/chat_management_service_phase12_test.dart` | `test/domain/services/chat_management_service_static_config_test.dart` | ChatManagementService — static config |
| `test/domain/services/chat_notification_persistent_phase13_test.dart` | `test/domain/services/chat_notification_persistent_service_test.dart` | ChatNotificationService |
| `test/domain/services/contact_management_service_phase12_test.dart` | `test/domain/services/contact_management_service_clear_search_history_test.dart` | clearSearchHistory |
| `test/domain/services/contact_management_service_phase13d_test.dart` | `test/domain/services/contact_management_service_singleton_and_factory_constructors_test.dart` | singleton and factory constructors |
| `test/domain/services/device_deduplication_manager_phase12_test.dart` | `test/domain/services/device_deduplication_manager_static_state_test.dart` | DeviceDeduplicationManager — static state |
| `test/domain/services/device_deduplication_manager_phase13d_test.dart` | `test/domain/services/device_deduplication_manager_merge_duplicate_devices_by_hint_test.dart` | merge duplicate devices by hint |
| `test/domain/services/group_messaging_service_phase12_test.dart` | `test/domain/services/group_messaging_service_send_message_test.dart` | sendGroupMessage |
| `test/domain/services/mesh/mesh_queue_sync_coordinator_phase11_test.dart` | `test/domain/services/mesh/mesh_queue_sync_coordinator_initialize_test.dart` | MeshQueueSyncCoordinator.initialize |
| `test/domain/services/mesh/mesh_queue_sync_coordinator_phase12_test.dart` | `test/domain/services/mesh/mesh_queue_sync_coordinator_handle_send_message_via_callback_test.dart` | _handleSendMessage (via queue callback) |
| `test/domain/services/mesh_networking_service_phase12_test.dart` | `test/domain/services/mesh_networking_service_construction_initialization_test.dart` | Construction & initialization |
| `test/domain/services/mesh_networking_service_phase13d_test.dart` | `test/domain/services/mesh_networking_service_stream_property_getters_test.dart` | Stream property getters |
| `test/domain/services/pinning_service_phase12_test.dart` | `test/domain/services/pinning_service_initialize_test.dart` | initialize |
| `test/domain/services/search_cache_manager_phase12_test.dart` | `test/domain/services/search_cache_manager_result_get_cached_result_test.dart` | cacheSearchResult + getCachedResult |
| `test/domain/utils/message_fragmenter_phase12_test.dart` | `test/domain/utils/message_fragmenter_chunk_test.dart` | MessageChunk |
| `test/main_phase13_test.dart` | `test/main_pak_connect_app_widget_tree_test.dart` | PakConnectApp widget tree |
| `test/power_management_phase1_test.dart` | `test/power_management_duty_cycle_scanning_tests_test.dart` | Phase 1: Duty Cycle Scanning Tests |
| `test/presentation/controllers/chat_screen_controller_phase13_test.dart` | `test/presentation/controllers/chat_screen_controller_coverage_test.dart` | ChatScreenController – Phase 13 coverage |
| `test/presentation/controllers/chat_screen_controller_phase13b_test.dart` | `test/presentation/controllers/chat_screen_controller_message_actions_test.dart` | ChatScreenController – Phase 13b coverage |
| `test/presentation/controllers/chat_scrolling_controller_phase13_test.dart` | `test/presentation/controllers/chat_scrolling_controller_coverage_test.dart` | ChatScrollingController |
| `test/presentation/controllers/home_screen_controller_phase12_test.dart` | `test/presentation/controllers/home_screen_controller_search_and_paging_test.dart` | HomeScreenController – Phase 1-2 supplementary |
| `test/presentation/controllers/home_screen_controller_phase13_test.dart` | `test/presentation/controllers/home_screen_controller_navigation_and_refresh_test.dart` | HomeScreenController – Phase 13 supplementary |
| `test/presentation/controllers/home_screen_controller_phase13b_test.dart` | `test/presentation/controllers/home_screen_controller_unread_and_reload_test.dart` | HomeScreenController – Phase 13b supplementary |
| `test/presentation/controllers/home_screen_controller_phase13d_test.dart` | `test/presentation/controllers/home_screen_controller_provider_and_listener_test.dart` | HomeScreenController – Phase 13d supplementary |
| `test/presentation/providers/ble_providers_phase6_test.dart` | `test/presentation/providers/ble_providers_bootstrap_and_connectivity_test.dart` | ble_providers phase 6.3 |
| `test/presentation/providers/chat_messaging_view_model_phase12_test.dart` | `test/presentation/providers/chat_messaging_view_model_resolve_recipient_key_branches_test.dart` | ChatMessagingViewModel - resolveRecipientKey branches |
| `test/presentation/providers/chat_messaging_view_model_phase13_test.dart` | `test/presentation/providers/chat_messaging_view_model_map_queued_status_branches_test.dart` | ChatMessagingViewModel – _mapQueuedStatus branches |
| `test/presentation/providers/chat_session_providers_phase13_test.dart` | `test/presentation/providers/chat_session_providers_actions_test.dart` | ChatSessionActions |
| `test/presentation/providers/chat_session_providers_phase13b_test.dart` | `test/presentation/providers/chat_session_providers_handle_test.dart` | ChatSessionHandle |
| `test/presentation/providers/mesh_networking_provider_phase12_test.dart` | `test/presentation/providers/mesh_networking_provider_runtime_state_test.dart` | MeshRuntimeState |
| `test/presentation/providers/mesh_networking_provider_phase13_test.dart` | `test/presentation/providers/mesh_networking_provider_controller_send_message_success_test.dart` | MeshNetworkingController — sendMeshMessage success |
| `test/presentation/providers/mesh_networking_provider_phase13b_test.dart` | `test/presentation/providers/mesh_networking_provider_controller_send_message_priority_variations_test.dart` | MeshNetworkingController — sendMeshMessage priority variations |
| `test/presentation/providers/mesh_networking_provider_phase13c_test.dart` | `test/presentation/providers/mesh_networking_provider_runtime_notifier_test.dart` | MeshRuntimeNotifier |
| `test/presentation/providers/mesh_networking_provider_phase6_test.dart` | `test/presentation/providers/mesh_networking_provider_controller_and_inbox_test.dart` | mesh_networking_provider phase 6.3 |
| `test/presentation/screens/archive_screen_phase13_test.dart` | `test/presentation/screens/archive_screen_additional_states_test.dart` | ArchiveScreen – Phase 13.2 |
| `test/presentation/screens/chat_screen_phase13_test.dart` | `test/presentation/screens/chat_screen_basic_rendering_test.dart` | ChatScreen – basic rendering |
| `test/presentation/screens/chat_screen_phase13d_test.dart` | `test/presentation/screens/chat_screen_build_status_text_connection_aware_non_repo_mode_test.dart` | ChatScreen – _buildStatusText connection-aware (non-repo mode) |
| `test/presentation/screens/contacts_screen_phase13_test.dart` | `test/presentation/screens/contacts_screen_rendering_test.dart` | ContactsScreen rendering |
| `test/presentation/screens/home_screen_phase13_test.dart` | `test/presentation/screens/home_screen_additional_coverage_test.dart` | HomeScreen Phase 13 — additional coverage |
| `test/presentation/screens/permission_screen_phase13_test.dart` | `test/presentation/screens/permission_screen_ui_rendering_test.dart` | PermissionScreen – UI rendering |
| `test/presentation/services/chat_interaction_handler_phase11_test.dart` | `test/presentation/services/chat_interaction_handler_format_time_edge_cases_test.dart` | formatTime edge-cases |
| `test/presentation/services/chat_interaction_handler_phase12_test.dart` | `test/presentation/services/chat_interaction_handler_initialize_test.dart` | initialize |
| `test/presentation/services/chat_interaction_handler_phase13_test.dart` | `test/presentation/services/chat_interaction_handler_menu_and_delete_paths_test.dart` | initialize |
| `test/presentation/services/chat_interaction_handler_phase13b_test.dart` | `test/presentation/services/chat_interaction_handler_mark_as_read_error_handling_test.dart` | markChatAsRead error handling |
| `test/presentation/services/chat_interaction_handler_phase13c_test.dart` | `test/presentation/services/chat_interaction_handler_open_settings_with_real_context_test.dart` | openSettings with real context |
| `test/presentation/theme/app_theme_phase12_test.dart` | `test/presentation/theme/app_theme_coverage_test.dart` | AppTheme |
| `test/presentation/viewmodels/chat_session_view_model_phase11_test.dart` | `test/presentation/viewmodels/chat_session_view_model_apply_message_status_test.dart` | applyMessageStatus |
| `test/presentation/viewmodels/chat_session_view_model_phase12_test.dart` | `test/presentation/viewmodels/chat_session_view_model_send_message_error_path_test.dart` | ChatSessionViewModel - sendMessage error path |
| `test/presentation/viewmodels/chat_session_view_model_phase13_test.dart` | `test/presentation/viewmodels/chat_session_view_model_pure_state_transformers_test.dart` | ChatSessionViewModel – pure state transformers |
| `test/presentation/widgets/discovery_overlay_phase13_test.dart` | `test/presentation/widgets/discovery_overlay_build_branches_test.dart` | DiscoveryOverlay Phase 13 – build branches |
