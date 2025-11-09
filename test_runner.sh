#!/bin/bash
# Quick test runner to identify failures

echo "=== TESTING INDIVIDUAL FILES ==="
echo ""

files=(
  "test/kk_protocol_integration_test.dart"
  "test/database_migration_test.dart"
  "test/migration_service_smoke_test.dart"
  "test/chats_repository_sqlite_test.dart"
  "test/message_repository_sqlite_test.dart"
  "test/offline_message_queue_sqlite_test.dart"
  "test/queue_sync_system_test.dart"
)

for file in "${files[@]}"; do
  echo "Testing: $file"
  flutter test "$file" --reporter=compact 2>&1 | grep -E "(^\+[0-9]+ |FAILED|passed|skipped)"
  echo ""
done
