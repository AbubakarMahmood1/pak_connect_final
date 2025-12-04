# Database Architecture (SQLite + SQLCipher)

## Schema Version 9 (Current)

**Critical Tables**:

```sql
-- CONTACTS: Three IDs per contact (see Identity Model)
CREATE TABLE contacts (
  public_key TEXT PRIMARY KEY,
  persistent_public_key TEXT,
  current_ephemeral_id TEXT,
  display_name TEXT,
  security_level INTEGER,
  last_seen INTEGER
);

-- CHATS: Chat list with contact relationships
CREATE TABLE chats (
  id TEXT PRIMARY KEY,
  contact_public_key TEXT,
  last_message TEXT,
  timestamp INTEGER,
  is_archived INTEGER DEFAULT 0,
  FOREIGN KEY(contact_public_key) REFERENCES contacts(public_key) ON DELETE CASCADE
);

-- MESSAGES: Message history with status tracking
CREATE TABLE messages (
  id TEXT PRIMARY KEY,
  chat_id TEXT,
  content TEXT,
  sender_key TEXT,
  timestamp INTEGER,
  is_read INTEGER DEFAULT 0,
  is_sent INTEGER DEFAULT 0,
  FOREIGN KEY(chat_id) REFERENCES chats(id) ON DELETE CASCADE
);

-- OFFLINE_MESSAGE_QUEUE: Persistence for unreliable mesh
CREATE TABLE offline_message_queue (
  id TEXT PRIMARY KEY,
  recipient_key TEXT,
  encrypted_message BLOB,
  retry_count INTEGER DEFAULT 0,
  created_at INTEGER
);

-- ARCHIVES_FTS: Full-text search for archived messages
CREATE VIRTUAL TABLE archives_fts USING fts5(
  message_id UNINDEXED,
  content,
  sender_name,
  tokenize = 'unicode61'
);
```

## Database Configuration

- **WAL Mode**: Enabled for concurrency
- **Foreign Keys**: Enforced (ON DELETE CASCADE)
- **Encryption**: SQLCipher v4
- **Location**: `${appDocDir}/databases/pakconnect_v9.db`

**Critical Files**:
- `lib/data/database/database_helper.dart`: Schema and migrations
- `lib/data/database/database_encryption.dart`: Encryption key derivation
- `lib/data/repositories/contact_repository.dart`: Contact CRUD (SQLite-backed)

## Database Performance

- **Batch Operations**: Use transactions for multiple inserts/updates
- **Indexed Queries**: Ensure foreign keys and frequently queried fields are indexed
- **FTS5 Search**: Use for text search, not for exact matches (use WHERE for exact)
