# Non-Functional Requirements

This document details quality attributes and constraints extracted from implementation.

## NFR-1: Performance

### NFR-1.1: Response Time
| ID | Requirement | Target | Measurement |
|----|-------------|--------|-------------|
| NFR-1.1.1 | Message encryption latency | < 50ms | `PerformanceMonitor` tracking |
| NFR-1.1.2 | Message decryption latency | < 50ms | Crypto operation timing |
| NFR-1.1.3 | Database query response | < 100ms | SQLite query execution |
| NFR-1.1.4 | BLE characteristic write | < 200ms | MTU-dependent |
| NFR-1.1.5 | Handshake completion (XX pattern) | < 2 seconds | 3-message round-trip |
| NFR-1.1.6 | Handshake completion (KK pattern) | < 1 second | 2-message round-trip |

### NFR-1.2: Throughput
| ID | Requirement | Target | Implementation |
|----|-------------|--------|----------------|
| NFR-1.2.1 | Messages per second (1-to-1) | 5-10 messages/sec | BLE MTU limited |
| NFR-1.2.2 | Concurrent BLE connections | 7 (Android), 10 (iOS) | Platform limitation |
| NFR-1.2.3 | Database writes | 100+ inserts/sec | WAL mode enabled |
| NFR-1.2.4 | Relay throughput | 3-5 messages/sec/node | Duplicate detection overhead |
| NFR-1.2.5 | Fragment reassembly | < 500ms per message | 30-second timeout |

### NFR-1.3: Scalability
| ID | Requirement | Target | Notes |
|----|-------------|--------|-------|
| NFR-1.3.1 | Maximum contacts | 1000+ | SQLite indexed |
| NFR-1.3.2 | Maximum messages per chat | 100,000+ | Paginated queries |
| NFR-1.3.3 | Maximum message queue size | 10,000 messages | Persistent storage |
| NFR-1.3.4 | Maximum network nodes | 50-100 nodes | Mesh topology limits |
| NFR-1.3.5 | Maximum relay hops | 5 hops | Configurable limit |

## NFR-2: Security

### NFR-2.1: Cryptographic Strength
| ID | Requirement | Standard | Implementation |
|----|-------------|----------|----------------|
| NFR-2.1.1 | Key exchange algorithm | X25519 ECDH | `pinenacl` package |
| NFR-2.1.2 | Symmetric encryption | ChaCha20-Poly1305 | `cryptography` package |
| NFR-2.1.3 | Hash function | SHA-256 | `crypto` package |
| NFR-2.1.4 | Key size | 256 bits | X25519 standard |
| NFR-2.1.5 | Nonce/IV uniqueness | 64-bit counter + 32-bit random | Noise Protocol spec |
| NFR-2.1.6 | Forward secrecy | Ephemeral DH per session | XX/KK patterns |

### NFR-2.2: Data Protection
| ID | Requirement | Method | Implementation |
|----|-------------|--------|----------------|
| NFR-2.2.1 | Database encryption | SQLCipher AES-256 | `sqflite_sqlcipher` |
| NFR-2.2.2 | Key storage | Platform secure storage | `flutter_secure_storage` |
| NFR-2.2.3 | Memory clearing | Secure key destruction | `DHState.destroy()` |
| NFR-2.2.4 | Replay protection | Nonce sequence tracking | Per-session counters |
| NFR-2.2.5 | Message authentication | AEAD MAC tag | ChaCha20-Poly1305 |

### NFR-2.3: Privacy
| ID | Requirement | Implementation | Status |
|----|-------------|----------------|--------|
| NFR-2.3.1 | No cloud storage | All data local only | Implemented |
| NFR-2.3.2 | No telemetry/analytics | Zero data collection | Implemented |
| NFR-2.3.3 | Ephemeral identity rotation | `EphemeralKeyManager` | Implemented |
| NFR-2.3.4 | No metadata leakage | BLE advertises ephemeral IDs | Implemented |
| NFR-2.3.5 | Secure deletion | Overwrite sensitive memory | Partial (key objects only) |

## NFR-3: Reliability

### NFR-3.1: Availability
| ID | Requirement | Target | Mechanism |
|----|-------------|--------|-----------|
| NFR-3.1.1 | App uptime | 99% during active use | Error handling |
| NFR-3.1.2 | BLE connection stability | Reconnect within 30s | Auto-reconnect logic |
| NFR-3.1.3 | Database availability | 99.9% | SQLite robustness |
| NFR-3.1.4 | Message delivery (1-hop) | 95%+ success rate | Retry mechanism |
| NFR-3.1.5 | Message delivery (multi-hop) | 80%+ success rate | Best-effort relay |

### NFR-3.2: Fault Tolerance
| ID | Requirement | Mechanism | Implementation |
|----|-------------|-----------|----------------|
| NFR-3.2.1 | Crash recovery | Persist queue state | SQLite transactions |
| NFR-3.2.2 | Network partition handling | Offline queue | Persistent message queue |
| NFR-3.2.3 | Corrupted message handling | AEAD verification | Discard invalid messages |
| NFR-3.2.4 | Database corruption recovery | Integrity checks | `PRAGMA integrity_check` |
| NFR-3.2.5 | BLE adapter failures | Graceful degradation | State monitoring |

### NFR-3.3: Data Integrity
| ID | Requirement | Mechanism | Implementation |
|----|-------------|-----------|----------------|
| NFR-3.3.1 | Message authenticity | AEAD MAC | ChaCha20-Poly1305 tag |
| NFR-3.3.2 | Database constraints | Foreign keys, unique indexes | SQLite schema |
| NFR-3.3.3 | Transaction atomicity | ACID properties | SQLite transactions |
| NFR-3.3.4 | Backup integrity | Checksums | `MigrationService` validation |
| NFR-3.3.5 | Fragment integrity | Sequence validation | `MessageFragmenter` |

## NFR-4: Usability

### NFR-4.1: User Interface
| ID | Requirement | Target | Implementation |
|----|-------------|--------|----------------|
| NFR-4.1.1 | First-time setup | < 2 minutes | Key generation + onboarding |
| NFR-4.1.2 | Add contact via QR | < 10 seconds | QR scan + handshake |
| NFR-4.1.3 | Send message | < 2 seconds | UI responsiveness |
| NFR-4.1.4 | Search results | < 1 second | Indexed queries + FTS5 |
| NFR-4.1.5 | Chat list load | < 500ms | Paginated, cached |

### NFR-4.2: Accessibility
| ID | Requirement | Status | Notes |
|----|-------------|--------|-------|
| NFR-4.2.1 | Screen reader support | Partial | Flutter default semantics |
| NFR-4.2.2 | High contrast mode | Not implemented | Future enhancement |
| NFR-4.2.3 | Font scaling | Supported | Flutter automatic |
| NFR-4.2.4 | Keyboard navigation | Partial | Mobile-first design |
| NFR-4.2.5 | Color-blind friendly | Partial | Security indicators use icons |

### NFR-4.3: Learnability
| ID | Requirement | Mechanism | Implementation |
|----|-------------|-----------|----------------|
| NFR-4.3.1 | Intuitive UI | Familiar chat interface | Standard patterns |
| NFR-4.3.2 | Security indicators | Visual icons | Lock/shield icons |
| NFR-4.3.3 | Error messages | User-friendly text | Contextual errors |
| NFR-4.3.4 | Onboarding hints | Intro screens | `IntroHintRepository` |
| NFR-4.3.5 | Status feedback | Message status icons | Pending/sent/delivered |

## NFR-5: Maintainability

### NFR-5.1: Code Quality
| ID | Requirement | Metric | Status |
|----|-------------|--------|--------|
| NFR-5.1.1 | Code documentation | Doc comments on public APIs | Good |
| NFR-5.1.2 | Logging coverage | Emoji-prefixed structured logging | Excellent |
| NFR-5.1.3 | Error handling | Try-catch with logging | Good |
| NFR-5.1.4 | Architectural separation | Layered architecture (4 layers) | Excellent |
| NFR-5.1.5 | SOLID principles | Applied throughout | Good |

### NFR-5.2: Testability
| ID | Requirement | Implementation | Status |
|----|-------------|----------------|--------|
| NFR-5.2.1 | Unit test coverage | Arrange-Act-Assert pattern | Partial |
| NFR-5.2.2 | Mock support | Dependency injection | Good |
| NFR-5.2.3 | Test database | `sqflite_common_ffi` | Implemented |
| NFR-5.2.4 | Integration tests | Key flows covered | Partial |
| NFR-5.2.5 | Test isolation | Independent test cases | Good |

### NFR-5.3: Extensibility
| ID | Requirement | Mechanism | Implementation |
|----|-------------|-----------|----------------|
| NFR-5.3.1 | Plugin architecture | Riverpod providers | Yes |
| NFR-5.3.2 | Configurable policies | `RelayPolicy`, `ArchivePolicy` | Yes |
| NFR-5.3.3 | Database migrations | Version-based upgrades | Yes (v1-v9) |
| NFR-5.3.4 | Notification handlers | Factory pattern | Yes |
| NFR-5.3.5 | Power management strategies | Strategy pattern | Yes |

## NFR-6: Portability

### NFR-6.1: Platform Support
| ID | Platform | Status | Notes |
|----|----------|--------|-------|
| NFR-6.1.1 | Android 8.0+ | Supported | Primary platform |
| NFR-6.1.2 | iOS 13.0+ | Partial | BLE background limitations |
| NFR-6.1.3 | Windows | Desktop BLE limited | Dev/testing only |
| NFR-6.1.4 | Linux | Desktop BLE limited | Dev/testing only |
| NFR-6.1.5 | macOS | Desktop BLE limited | Dev/testing only |

### NFR-6.2: Environment
| ID | Requirement | Implementation | Notes |
|----|-------------|----------------|-------|
| NFR-6.2.1 | Flutter version | 3.9+ | Specified in pubspec |
| NFR-6.2.2 | Dart version | 3.9+ | Null safety |
| NFR-6.2.3 | Android SDK | 26+ (API 26) | BLE improvements |
| NFR-6.2.4 | iOS SDK | 13.0+ | Background BLE |
| NFR-6.2.5 | Storage requirement | 100MB minimum | Database + logs |

## NFR-7: Efficiency

### NFR-7.1: Battery Consumption
| ID | Requirement | Target | Mechanism |
|----|-------------|--------|-----------|
| NFR-7.1.1 | Continuous scanning drain | < 5%/hour | Burst scanning |
| NFR-7.1.2 | Idle battery drain | < 1%/hour | Duty cycling |
| NFR-7.1.3 | Active messaging drain | < 10%/hour | Optimized BLE writes |
| NFR-7.1.4 | Screen-off power mode | 90% reduction | LOW_POWER mode |
| NFR-7.1.5 | Battery level monitoring | Real-time | `BatteryOptimizer` |

### NFR-7.2: Resource Usage
| ID | Requirement | Target | Notes |
|----|-------------|--------|-------|
| NFR-7.2.1 | Memory footprint | < 150MB | Including UI |
| NFR-7.2.2 | Database size (typical) | < 50MB | 10k messages |
| NFR-7.2.3 | Network bandwidth | 1-5 KB/message | BLE limited |
| NFR-7.2.4 | CPU usage (idle) | < 2% | Background tasks |
| NFR-7.2.5 | CPU usage (active) | < 20% | Crypto operations |

### NFR-7.3: Storage Efficiency
| ID | Requirement | Mechanism | Implementation |
|----|-------------|-----------|----------------|
| NFR-7.3.1 | Message compression | Archive compression | Optional feature |
| NFR-7.3.2 | Database VACUUM | Monthly automatic | `DatabaseHelper.vacuumIfDue()` |
| NFR-7.3.3 | Image optimization | Not implemented | Future feature |
| NFR-7.3.4 | Log rotation | File-based logging | Partial |
| NFR-7.3.5 | Cache management | LRU caches | `HintCacheManager` |

## NFR-8: Compliance

### NFR-8.1: Legal
| ID | Requirement | Status | Notes |
|----|-------------|--------|-------|
| NFR-8.1.1 | Open source license | MIT License | Permissive |
| NFR-8.1.2 | GDPR compliance | Compliant | No personal data collection |
| NFR-8.1.3 | Export control (crypto) | Generally exempt | Open source exception |
| NFR-8.1.4 | Third-party licenses | Documented | Dependencies |
| NFR-8.1.5 | Privacy policy | Included | `assets/privacy_policy.md` |

### NFR-8.2: Standards
| ID | Requirement | Standard | Compliance |
|----|-------------|----------|------------|
| NFR-8.2.1 | Noise Protocol | Noise Protocol Framework (Rev 34) | Yes |
| NFR-8.2.2 | BLE GATT | Bluetooth 4.0+ GATT | Yes |
| NFR-8.2.3 | Cryptography | NIST approved algorithms | Yes (ChaCha20, SHA-256) |
| NFR-8.2.4 | SQL | SQL-92 subset | Yes (SQLite) |
| NFR-8.2.5 | UTF-8 encoding | Unicode standard | Yes |

## NFR-9: Localization

### NFR-9.1: Internationalization
| ID | Requirement | Status | Notes |
|----|-------------|--------|-------|
| NFR-9.1.1 | Multi-language support | Not implemented | English only |
| NFR-9.1.2 | UTF-8 message support | Implemented | Full Unicode |
| NFR-9.1.3 | RTL language support | Not implemented | Future feature |
| NFR-9.1.4 | Date/time formatting | Implemented | `intl` package |
| NFR-9.1.5 | Currency formatting | Not applicable | No financial features |

## NFR-10: Compatibility

### NFR-10.1: Backward Compatibility
| ID | Requirement | Mechanism | Status |
|----|-------------|-----------|--------|
| NFR-10.1.1 | Database schema migrations | Version-based upgrades | v1-v9 supported |
| NFR-10.1.2 | Protocol versioning | Not implemented | Future consideration |
| NFR-10.1.3 | Settings migration | SharedPreferences fallback | Partial |
| NFR-10.1.4 | Archive format versioning | Not implemented | Future feature |
| NFR-10.1.5 | API stability | Internal only | Not applicable |

### NFR-10.2: Interoperability
| ID | Requirement | Status | Notes |
|----|-------------|--------|-------|
| NFR-10.2.1 | Cross-platform messaging | Yes | Android ↔ iOS |
| NFR-10.2.2 | Protocol compatibility | Yes | Noise Protocol standard |
| NFR-10.2.3 | Different app versions | Partial | Same database schema required |
| NFR-10.2.4 | Third-party implementations | Theoretically yes | Noise Protocol based |
| NFR-10.2.5 | Export format portability | JSON/Text | Standard formats |

---

**Document Version**: 1.0
**Last Updated**: 2025-01-19
**Total Non-Functional Requirements**: 105
