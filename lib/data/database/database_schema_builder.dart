import 'package:logging/logging.dart';
import 'package:sqflite_sqlcipher/sqflite.dart' as sqlcipher;

import 'archive_db_utilities.dart';

/// Owns schema creation for fresh database installs.
class DatabaseSchemaBuilder {
  static Future<void> createSchema(
    sqlcipher.Database db,
    int version, {
    required Logger logger,
  }) async {
    logger.info('Creating database schema v$version...');

    // =========================
    // 1. CONTACTS TABLE
    // =========================
    await db.execute('''
      CREATE TABLE contacts (
        public_key TEXT PRIMARY KEY,
        persistent_public_key TEXT UNIQUE,
        current_ephemeral_id TEXT,
        ephemeral_id TEXT,
        display_name TEXT NOT NULL,
        trust_status INTEGER NOT NULL,
        security_level INTEGER NOT NULL,
        first_seen INTEGER NOT NULL,
        last_seen INTEGER NOT NULL,
        last_security_sync INTEGER,
        noise_public_key TEXT,
        noise_session_state TEXT,
        last_handshake_time INTEGER,
        is_favorite INTEGER DEFAULT 0,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL
      )
    ''');

    await db.execute('''
      CREATE INDEX idx_contacts_trust ON contacts(trust_status)
    ''');

    await db.execute('''
      CREATE INDEX idx_contacts_security ON contacts(security_level)
    ''');

    await db.execute('''
      CREATE INDEX idx_contacts_last_seen ON contacts(last_seen DESC)
    ''');

    await db.execute('''
      CREATE INDEX idx_contacts_favorite ON contacts(is_favorite) WHERE is_favorite = 1
    ''');

    // =========================
    // 2. CHATS TABLE
    // =========================
    await db.execute('''
      CREATE TABLE chats (
        chat_id TEXT PRIMARY KEY,
        contact_public_key TEXT,
        contact_name TEXT NOT NULL,
        last_message TEXT,
        last_message_time INTEGER,
        unread_count INTEGER DEFAULT 0,
        is_archived INTEGER DEFAULT 0,
        is_muted INTEGER DEFAULT 0,
        is_pinned INTEGER DEFAULT 0,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL,
        FOREIGN KEY (contact_public_key) REFERENCES contacts(public_key) ON DELETE SET NULL
      )
    ''');

    await db.execute('''
      CREATE INDEX idx_chats_contact ON chats(contact_public_key)
    ''');

    await db.execute('''
      CREATE INDEX idx_chats_last_message ON chats(last_message_time DESC)
    ''');

    await db.execute('''
      CREATE INDEX idx_chats_unread ON chats(unread_count) WHERE unread_count > 0
    ''');

    await db.execute('''
      CREATE INDEX idx_chats_pinned ON chats(is_pinned, last_message_time DESC) WHERE is_pinned = 1
    ''');

    // =========================
    // 3. MESSAGES TABLE (Enhanced with JSON blobs)
    // =========================
    await db.execute('''
      CREATE TABLE messages (
        id TEXT PRIMARY KEY,
        chat_id TEXT NOT NULL,
        content TEXT NOT NULL,
        timestamp INTEGER NOT NULL,
        is_from_me INTEGER NOT NULL,
        status INTEGER NOT NULL,

        -- Threading
        reply_to_message_id TEXT,
        thread_id TEXT,

        -- Status flags
        is_starred INTEGER DEFAULT 0,
        is_forwarded INTEGER DEFAULT 0,
        priority INTEGER DEFAULT 1,

        -- Edit tracking
        edited_at INTEGER,
        original_content TEXT,

        -- Media support
        has_media INTEGER DEFAULT 0,
        media_type TEXT,

        -- Complex objects as JSON blobs
        metadata_json TEXT,
        delivery_receipt_json TEXT,
        read_receipt_json TEXT,
        reactions_json TEXT,
        attachments_json TEXT,
        encryption_info_json TEXT,

        -- Timestamps
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL,

        FOREIGN KEY (chat_id) REFERENCES chats(chat_id) ON DELETE CASCADE
      )
    ''');

    await db.execute('''
      CREATE INDEX idx_messages_chat_time ON messages(chat_id, timestamp DESC)
    ''');

    await db.execute('''
      CREATE INDEX idx_messages_thread ON messages(thread_id) WHERE thread_id IS NOT NULL
    ''');

    await db.execute('''
      CREATE INDEX idx_messages_reply ON messages(reply_to_message_id) WHERE reply_to_message_id IS NOT NULL
    ''');

    await db.execute('''
      CREATE INDEX idx_messages_starred ON messages(is_starred) WHERE is_starred = 1
    ''');

    await db.execute('''
      CREATE INDEX idx_messages_media ON messages(chat_id, has_media) WHERE has_media = 1
    ''');

    // =========================
    // 4. OFFLINE MESSAGE QUEUE (CRITICAL for mesh networking)
    // =========================
    await db.execute('''
      CREATE TABLE offline_message_queue (
        queue_id TEXT PRIMARY KEY,
        message_id TEXT NOT NULL,
        chat_id TEXT NOT NULL,
        content TEXT NOT NULL,
        recipient_public_key TEXT NOT NULL,
        sender_public_key TEXT NOT NULL,

        -- Queue metadata
        queued_at INTEGER NOT NULL,
        retry_count INTEGER DEFAULT 0,
        max_retries INTEGER DEFAULT 5,
        next_retry_at INTEGER,
        priority INTEGER DEFAULT 1,

        -- Delivery tracking
        status INTEGER NOT NULL,
        attempts INTEGER DEFAULT 0,
        last_attempt_at INTEGER,
        delivered_at INTEGER,
        failed_at INTEGER,
        failure_reason TEXT,
        expires_at INTEGER,

        -- Relay metadata (for mesh networking)
        is_relay_message INTEGER DEFAULT 0,
        original_message_id TEXT,
        relay_node_id TEXT,
        message_hash TEXT,
        relay_metadata_json TEXT,

        -- Additional fields
        reply_to_message_id TEXT,
        attachments_json TEXT,
        sender_rate_count INTEGER DEFAULT 0,

        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL
      )
    ''');

    await db.execute('''
      CREATE INDEX idx_queue_status ON offline_message_queue(status, next_retry_at)
    ''');

    await db.execute('''
      CREATE INDEX idx_queue_recipient ON offline_message_queue(recipient_public_key, status)
    ''');

    await db.execute('''
      CREATE INDEX idx_queue_priority ON offline_message_queue(priority DESC, queued_at ASC)
    ''');

    await db.execute('''
      CREATE INDEX idx_queue_hash ON offline_message_queue(message_hash) WHERE message_hash IS NOT NULL
    ''');

    // =========================
    // 5. QUEUE SYNC STATE (for deleted messages tracking)
    // =========================
    await db.execute('''
      CREATE TABLE queue_sync_state (
        device_id TEXT PRIMARY KEY,
        last_sync_at INTEGER,
        pending_messages_count INTEGER DEFAULT 0,
        last_successful_delivery INTEGER,
        consecutive_failures INTEGER DEFAULT 0,
        sync_enabled INTEGER DEFAULT 1,
        metadata_json TEXT,
        updated_at INTEGER NOT NULL
      )
    ''');

    await db.execute('''
      CREATE INDEX idx_sync_pending ON queue_sync_state(pending_messages_count)
        WHERE pending_messages_count > 0
    ''');

    // =========================
    // 6. DELETED MESSAGE IDS (for queue sync)
    // =========================
    await db.execute('''
      CREATE TABLE deleted_message_ids (
        message_id TEXT PRIMARY KEY,
        deleted_at INTEGER NOT NULL,
        reason TEXT
      )
    ''');

    await db.execute('''
      CREATE INDEX idx_deleted_time ON deleted_message_ids(deleted_at)
    ''');

    // =========================
    // 7-9. ARCHIVES (delegated)
    // =========================
    await ArchiveDbUtilities.createArchiveTables(db);

    // =========================
    // 10. DEVICE MAPPINGS (for public key to device UUID tracking)
    // =========================
    await db.execute('''
      CREATE TABLE device_mappings (
        device_uuid TEXT PRIMARY KEY,
        public_key TEXT NOT NULL,
        last_seen INTEGER NOT NULL,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL
      )
    ''');

    await db.execute('''
      CREATE INDEX idx_device_public_key ON device_mappings(public_key)
    ''');

    // =========================
    // 11. CONTACT LAST SEEN (for online status tracking)
    // =========================
    await db.execute('''
      CREATE TABLE contact_last_seen (
        public_key TEXT PRIMARY KEY,
        last_seen_at INTEGER NOT NULL,
        was_online INTEGER DEFAULT 0,
        updated_at INTEGER NOT NULL,
        FOREIGN KEY (public_key) REFERENCES contacts(public_key) ON DELETE CASCADE
      )
    ''');

    await db.execute('''
      CREATE INDEX idx_last_seen_time ON contact_last_seen(last_seen_at DESC)
    ''');

    // =========================
    // 12. MIGRATION METADATA (track migration progress)
    // =========================
    await db.execute('''
      CREATE TABLE migration_metadata (
        key TEXT PRIMARY KEY,
        value TEXT,
        migrated_at INTEGER NOT NULL
      )
    ''');

    // =========================
    // 13. APP PREFERENCES (user settings and preferences)
    // =========================
    await db.execute('''
      CREATE TABLE app_preferences (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL,
        value_type TEXT NOT NULL,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL
      )
    ''');

    await db.execute('''
      CREATE INDEX idx_preferences_type ON app_preferences(value_type)
    ''');

    // =========================
    // 14. CONTACT GROUPS (for secure multi-unicast messaging)
    // =========================
    await db.execute('''
      CREATE TABLE contact_groups (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        description TEXT,
        created_at INTEGER NOT NULL,
        last_modified_at INTEGER NOT NULL
      )
    ''');

    await db.execute('''
      CREATE INDEX idx_groups_modified ON contact_groups(last_modified_at DESC)
    ''');

    // =========================
    // 15. GROUP MEMBERS (junction table)
    // =========================
    await db.execute('''
      CREATE TABLE group_members (
        group_id TEXT NOT NULL,
        member_key TEXT NOT NULL,
        added_at INTEGER NOT NULL,
        PRIMARY KEY (group_id, member_key),
        FOREIGN KEY (group_id) REFERENCES contact_groups(id) ON DELETE CASCADE
      )
    ''');

    await db.execute('''
      CREATE INDEX idx_group_members_key ON group_members(member_key)
    ''');

    // =========================
    // 16. GROUP MESSAGES (with per-member delivery tracking)
    // =========================
    await db.execute('''
      CREATE TABLE group_messages (
        id TEXT PRIMARY KEY,
        group_id TEXT NOT NULL,
        sender_key TEXT NOT NULL,
        content TEXT NOT NULL,
        timestamp INTEGER NOT NULL,
        FOREIGN KEY (group_id) REFERENCES contact_groups(id) ON DELETE CASCADE
      )
    ''');

    await db.execute('''
      CREATE INDEX idx_group_messages_group ON group_messages(group_id, timestamp DESC)
    ''');

    await db.execute('''
      CREATE INDEX idx_group_messages_sender ON group_messages(sender_key)
    ''');

    // =========================
    // 17. GROUP MESSAGE DELIVERY (per-member delivery status)
    // =========================
    await db.execute('''
      CREATE TABLE group_message_delivery (
        message_id TEXT NOT NULL,
        member_key TEXT NOT NULL,
        status INTEGER NOT NULL,
        timestamp INTEGER NOT NULL,
        PRIMARY KEY (message_id, member_key),
        FOREIGN KEY (message_id) REFERENCES group_messages(id) ON DELETE CASCADE
      )
    ''');

    await db.execute('''
      CREATE INDEX idx_delivery_status ON group_message_delivery(message_id, status)
    ''');

    // =========================
    // 18. SEEN MESSAGES (mesh deduplication)
    // =========================
    // FIX-005: Added in v10 for proper mesh relay deduplication
    await db.execute('''
      CREATE TABLE seen_messages (
        message_id TEXT NOT NULL,
        seen_type TEXT NOT NULL,
        seen_at INTEGER NOT NULL,
        PRIMARY KEY (message_id, seen_type)
      )
    ''');

    await db.execute('''
      CREATE INDEX idx_seen_messages_type ON seen_messages(seen_type, seen_at DESC)
    ''');

    await db.execute('''
      CREATE INDEX idx_seen_messages_time ON seen_messages(seen_at DESC)
    ''');

    logger.info(
      '✅ Database schema created successfully with 18 core tables + FTS5',
    );
  }
}
