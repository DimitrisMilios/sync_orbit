/// `sync_orbit` is a production-ready, offline-first sync engine and outbox
/// mutation queue for Flutter and Dart applications.
///
/// ## Key Features
/// - **Pluggable Persistence**: Implement [SyncStorage] for SQLite (`sqflite`, `drift`), Hive, or use built-in [InMemorySyncStorage].
/// - **Outbox Queue**: Reliable FIFO sequential dispatch of [SyncMutation] operations.
/// - **Remote Adapters**: Built-in [RestSyncAdapter], [SupabaseSyncAdapter], and [FirestoreSyncAdapter].
/// - **Conflict Resolution Strategies**: Server Wins, Client Wins, and Last-Write-Wins (LWW) via [ConflictResolver].
/// - **Exponential Backoff**: Configurable backoff multipliers, max retries, and jitter via [RetryPolicy].
/// - **Network Reactivity**: Injected [SyncConnectivity] or `Stream<bool>` automatically triggers sync on reconnect.
library;

// Models
export 'src/models/sync_action.dart';
export 'src/models/sync_mutation.dart';
export 'src/models/sync_status.dart';

// Adapters
export 'src/adapter/firestore_sync_adapter.dart';
export 'src/adapter/rest_sync_adapter.dart';
export 'src/adapter/supabase_sync_adapter.dart';
export 'src/adapter/sync_adapter.dart';
export 'src/adapter/sync_adapter_result.dart';

// Storage
export 'src/storage/in_memory_sync_storage.dart';
export 'src/storage/sync_storage.dart';

// Conflict Resolution
export 'src/conflict/conflict_resolution.dart';
export 'src/conflict/conflict_resolver.dart';
export 'src/conflict/resolvers.dart';

// Retry & Backoff
export 'src/retry/retry_policy.dart';

// Connectivity
export 'src/connectivity/sync_connectivity.dart';

// Orchestration Engine
export 'src/engine/sync_engine.dart';
export 'src/engine/sync_engine_options.dart';
export 'src/engine/sync_events.dart';

// Utilities
export 'src/utils/uuid_generator.dart';
