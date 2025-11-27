# Performance Considerations

## BLE Performance

- **MTU Negotiation**: Always request max MTU (512 bytes) for fewer fragments
- **Characteristic Caching**: Cache characteristic references to avoid repeated discovery
- **Connection Pooling**: Limit concurrent connections (max 7 on Android)

## Database Performance

- **Batch Operations**: Use transactions for multiple inserts/updates
- **Indexed Queries**: Ensure foreign keys and frequently queried fields are indexed
- **FTS5 Search**: Use for text search, not for exact matches (use WHERE for exact)

## Mesh Performance

- **Relay Limits**: Cap relay hops (max 3-5) to prevent network flooding
- **Duplicate Detection**: Use bloom filters for memory-efficient seen message tracking
- **Topology Updates**: Cache topology for 5-10 seconds, don't recalculate on every message

## Known Limitations

- **BLE Range**: ~10-30m line-of-sight (hardware dependent)
- **Mesh Hops**: Max 3-5 hops before latency becomes noticeable
- **Concurrent Connections**: Android limits to ~7 simultaneous connections
- **Battery Life**: Continuous BLE scanning drains battery (use BALANCED mode)
- **iOS Background**: iOS heavily restricts background BLE (foreground recommended)
