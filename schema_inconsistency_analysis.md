# Critical Database Schema Inconsistency Detected

## Issue Summary
The extracted `ArchiveDbUtilities.createArchiveTables()` has **different schema constraints** than the original inline schema, creating inconsistency between fresh installs and migrated databases.

## Schema Differences

### archived_messages.original_message_id
**Original (main branch)**: `original_message_id TEXT NOT NULL`
**New (archive_db_utilities.dart)**: `original_message_id TEXT` (nullable!)

### archived_messages.priority  
**Original (main branch)**: `priority INTEGER DEFAULT 1`
**New (archive_db_utilities.dart)**: `priority INTEGER DEFAULT 0`

### archived_chats.estimated_size
**Original (main branch)**: `estimated_size INTEGER NOT NULL`
**New (archive_db_utilities.dart)**: `estimated_size INTEGER` (nullable!)

## Impact

**Fresh Installs (onCreate → v10)**:
- Calls `ArchiveDbUtilities.createArchiveTables()`
- Gets nullable `original_message_id` and `estimated_size`
- Gets priority default = 0

**Migrated Databases (v1 → v2 → ... → v10)**:
- Uses inline schema in migration code (line 540-569)
- Gets NOT NULL constraints
- Gets priority default = 1

**Result**: Same version (v10) with DIFFERENT schemas!

## Root Cause
Refactoring extracted schema to `archive_db_utilities.dart` but:
1. Changed constraints (removed NOT NULL)
2. Changed default value (priority 1→0)
3. Migration code wasn't updated to use the utility

## Affected Users
- Anyone upgrading from v1-v9 → v10 gets old schema
- Fresh v10 installs get new schema
- Tests create fresh DBs, so won't catch this!
