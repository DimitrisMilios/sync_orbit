# sync_orbit 🛰️

[![pub package](https://img.shields.io/badge/pub.dev-sync__orbit-blue.svg)](https://pub.dev/packages/sync_orbit)
[![license](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)
[![Dart](https://img.shields.io/badge/Dart-3.11+-0175C2.svg)](https://dart.dev)
[![Flutter](https://img.shields.io/badge/Flutter-Ready-02569B.svg)](https://flutter.dev)

A production-ready, offline-first synchronization engine and transactional outbox mutation queue for Flutter and Dart applications.

---

## 🌟 Features

- 📦 **Transactional Outbox Queue**: Safely queue mutations locally while offline and dispatch them sequentially in strict First-In-First-Out (FIFO) order when reconnected.
- 🔌 **Storage Agnostic (`SyncStorage`)**: Abstract interface ready for SQLite (`sqflite`, `drift`), Hive, Isar, ObjectBox, or the built-in `InMemorySyncStorage`.
- 🌐 **Network Monitoring**: Inject any connectivity stream (such as `connectivity_plus`) to trigger auto-flush on reconnect without polling loops.
- ⚔️ **Conflict Resolution Strategies**:
  - `ServerWinsResolver`: Remote server state takes precedence.
  - `ClientWinsResolver`: Client force-overwrites remote state.
  - `LastWriteWinsResolver`: Compares timestamps (client write vs. server record) to automatically resolve version drift.
  - `CustomConflictResolver`: Define domain-specific field merges and business rules.
- ⏳ **Exponential Backoff with Jitter**: Configurable delay growth ($1s \to 2s \to 4s \to \dots$), maximum bounds, max retries, and jitter to avoid thundering herd spikes.
- 🛡️ **Concurrency Protected**: Thread-safe async mutex prevents concurrent duplicate flushes and race conditions.
- ⚡ **Zero Unnecessary Dependencies**: Pure Dart core (`meta` only) compatible with Flutter, server-side Dart, and CLI tools.

---

## 📐 Architecture Overview

```mermaid
flowchart TD
    UI["📱 Flutter UI / Client Code"] -->|enqueue mutation| Queue["📦 Outbox Storage (SyncStorage)"]
    Queue -->|fetch FIFO| Engine["⚙️ SyncEngine"]

    Conn["📶 SyncConnectivity (connectivity_plus)"] -->|online event| Engine

    subgraph Flush Pass
        Engine -->|send(mutation)| Adapter["🌐 Remote SyncAdapter (REST / GraphQL / Supabase)"]
        Adapter -->|Success| Clean["✅ Delete / Mark Completed"]
        Adapter -->|Conflict| Conflict["⚔️ ConflictResolver (LWW / Server / Client / Merge)"]
        Adapter -->|Recoverable Failure| Backoff["⏳ Exponential Backoff + Retry Policy"]
    end

    Conflict -->|Resolved Payload| Adapter
    Conflict -->|Server Wins| Clean
```

---

## 📦 Installation

Add `sync_orbit` to your `pubspec.yaml`:

```yaml
dependencies:
  sync_orbit: ^0.1.0
```

Then run:

```bash
flutter pub get
```

---

## 🚀 Built-in Sync Adapters

`sync_orbit` comes with battle-tested adapters for popular backends:

### 1. `RestSyncAdapter` (Standard REST APIs)

Dispatches mutations via HTTP `POST`, `PUT`/`PATCH`, and `DELETE`.

```dart
import 'package:sync_orbit/sync_orbit.dart';

final restAdapter = RestSyncAdapter(
  baseUrl: 'https://api.example.com/v1',
  headersProvider: () async => {
    'Authorization': 'Bearer ${await authService.getAccessToken()}',
  },
  appendIdOnUpdateAndDelete: true, // Automatically appends '/{id}' for updates & deletes
  usePatchForUpdate: false,        // Use PUT (default) or set true for PATCH
  timeout: const Duration(seconds: 30),
);
```

### 2. `SupabaseSyncAdapter` (Supabase PostgREST)

Integrates directly with `supabase_flutter` to execute table inserts, updates, and deletes with conflict detection.

```dart
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:sync_orbit/sync_orbit.dart';

final supabaseClient = Supabase.instance.client;

final supabaseAdapter = SupabaseSyncAdapter(
  client: supabaseClient,
  primaryKey: 'id',                 // Primary key column name (defaults to 'id')
  fetchConflictRecord: true,        // Automatically queries conflicting remote row on 409 / 23505
);
```

### 3. `FirestoreSyncAdapter` (Cloud Firestore)

Applies mutations directly to Firestore document paths or collections.

```dart
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:sync_orbit/sync_orbit.dart';

final firestore = FirebaseFirestore.instance;

final firestoreAdapter = FirestoreSyncAdapter(
  firestore: firestore,
  useMergeSetForUpdate: true,               // Uses SetOptions(merge: true) for safe upserts
  detectExistingOnCreateAsConflict: true,   // Detects if document already exists on create
);
```

---

## 💡 Quick Start

```dart
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:sync_orbit/sync_orbit.dart';

void main() async {
  // 1. Storage (use InMemorySyncStorage for testing or custom Drift/Sqflite for persistence)
  final storage = InMemorySyncStorage();
  await storage.initialize();

  // 2. Connectivity stream from connectivity_plus
  final connectivityStream = Connectivity().onConnectivityChanged.map(
    (results) => !results.contains(ConnectivityResult.none),
  );

  // 3. Create the engine
  final syncEngine = SyncEngine(
    storage: storage,
    adapter: ApiSyncAdapter(baseUrl: 'https://api.example.com', client: http.Client()),
    connectivityStream: connectivityStream,
    conflictResolver: const LastWriteWinsResolver(),
    retryPolicy: const RetryPolicy(
      initialDelay: Duration(seconds: 1),
      backoffFactor: 2.0,
      maxDelay: Duration(minutes: 2),
      maxRetries: 5,
      useJitter: true,
    ),
    options: const SyncEngineOptions(
      deleteOnSuccess: true,
      autoFlushOnOnline: true,
      autoFlushOnEnqueue: true,
    ),
  );

  await syncEngine.initialize();

  // 4. Enqueue a mutation (e.g. user creates a todo item)
  await syncEngine.queue(
    endpoint: 'todos',
    action: SyncAction.create,
    payload: {
      'id': 'todo_123',
      'title': 'Buy groceries',
      'completed': false,
    },
  );
}
```

---

## 🗄️ Implementing Persistent Storage (SQLite / Drift / Sqflite)

`sync_orbit` exposes the abstract `SyncStorage` interface. Below is an example implementing `SyncStorage` using `sqflite`:

```dart
import 'package:sqflite/sqflite.dart';
import 'package:sync_orbit/sync_orbit.dart';
import 'dart:convert';

class SqfliteSyncStorage implements SyncStorage {
  final Database database;

  SqfliteSyncStorage(this.database);

  @override
  Future<void> initialize() async {
    await database.execute('''
      CREATE TABLE IF NOT EXISTS sync_outbox (
        id TEXT PRIMARY KEY,
        endpoint TEXT NOT NULL,
        action TEXT NOT NULL,
        payload TEXT NOT NULL,
        createdAt TEXT NOT NULL,
        retryCount INTEGER NOT NULL DEFAULT 0,
        status TEXT NOT NULL,
        lastAttemptedAt TEXT,
        lastError TEXT,
        metadata TEXT
      )
    ''');
  }

  @override
  Future<void> saveMutation(SyncMutation mutation) async {
    await database.insert(
      'sync_outbox',
      {
        'id': mutation.id,
        'endpoint': mutation.endpoint,
        'action': mutation.action.name,
        'payload': jsonEncode(mutation.payload),
        'createdAt': mutation.createdAt.toIso8601String(),
        'retryCount': mutation.retryCount,
        'status': mutation.status.name,
        'lastAttemptedAt': mutation.lastAttemptedAt?.toIso8601String(),
        'lastError': mutation.lastError,
        'metadata': mutation.metadata != null ? jsonEncode(mutation.metadata) : null,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  @override
  Future<List<SyncMutation>> getPendingMutations({int? limit}) async {
    final rows = await database.query(
      'sync_outbox',
      where: 'status IN (?, ?)',
      whereArgs: [SyncStatus.pending.name, SyncStatus.failed.name],
      orderBy: 'createdAt ASC',
      limit: limit,
    );

    return rows.map((row) => SyncMutation(
      id: row['id'] as String,
      endpoint: row['endpoint'] as String,
      action: SyncAction.fromString(row['action'] as String),
      payload: jsonDecode(row['payload'] as String) as Map<String, dynamic>,
      createdAt: DateTime.parse(row['createdAt'] as String),
      retryCount: row['retryCount'] as int,
      status: SyncStatus.fromString(row['status'] as String),
      lastAttemptedAt: row['lastAttemptedAt'] != null
          ? DateTime.parse(row['lastAttemptedAt'] as String)
          : null,
      lastError: row['lastError'] as String?,
      metadata: row['metadata'] != null
          ? jsonDecode(row['metadata'] as String) as Map<String, dynamic>
          : null,
    )).toList();
  }

  @override
  Future<void> deleteMutation(String id) async {
    await database.delete('sync_outbox', where: 'id = ?', whereArgs: [id]);
  }

  @override
  Future<void> markCompleted(String id) async {
    await database.update(
      'sync_outbox',
      {'status': SyncStatus.completed.name, 'lastAttemptedAt': DateTime.now().toUtc().toIso8601String()},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  @override
  Future<void> markFailed(String id, {String? error, DateTime? attemptedAt}) async {
    await database.rawUpdate('''
      UPDATE sync_outbox
      SET status = ?, retryCount = retryCount + 1, lastError = ?, lastAttemptedAt = ?
      WHERE id = ?
    ''', [SyncStatus.failed.name, error, (attemptedAt ?? DateTime.now().toUtc()).toIso8601String(), id]);
  }

  @override
  Future<int> getPendingCount() async {
    final result = await database.rawQuery(
      'SELECT COUNT(*) as count FROM sync_outbox WHERE status IN (?, ?)',
      [SyncStatus.pending.name, SyncStatus.failed.name],
    );
    return Sqflite.firstIntValue(result) ?? 0;
  }

  @override
  Future<SyncMutation?> getMutation(String id) async { /* ... */ return null; }
  @override
  Future<List<SyncMutation>> getAllMutations() async { /* ... */ return []; }
  @override
  Future<void> updateMutation(SyncMutation mutation) async { /* ... */ }
  @override
  Future<void> clear() async { await database.delete('sync_outbox'); }
  @override
  Future<void> dispose() async {}
}
```

---

## ⚔️ Conflict Resolution In Depth

When the backend detects a conflict and returns a `SyncAdapterConflict`, `SyncEngine` delegates the resolution to the configured `ConflictResolver`:

| Strategy | Description | Typical Use Case |
|---|---|---|
| `LastWriteWinsResolver` | Compares client mutation timestamp with server timestamp. The newer timestamp wins. | Collaborative document edits, user settings, profile updates. |
| `ServerWinsResolver` | Discards the client write and adopts remote data. | Inventory reservations, banking, server-authoritative counters. |
| `ClientWinsResolver` | Overwrites server record with client state (adds `forceWrite: true` metadata). | Offline-first personal notes, local drafts. |
| `CustomConflictResolver` | User-defined function merging keys from client and server. | Complex nested objects, field-level 3-way merges. |

### Custom Merge Example

```dart
final engine = SyncEngine(
  storage: storage,
  adapter: adapter,
  conflictResolver: CustomConflictResolver(({
    required clientMutation,
    required serverConflict,
  }) {
    // 3-way or key-by-key merge
    final merged = {
      ...serverConflict.serverPayload,
      ...clientMutation.payload,
      'mergedAt': DateTime.now().toUtc().toIso8601String(),
    };
    return ConflictResolution.merge(merged);
  }),
);
```

---

## ⏱️ Exponential Backoff & Retry Policies

Configure how network failures are retried:

```dart
const policy = RetryPolicy(
  initialDelay: Duration(seconds: 1), // Delay before retry #1
  backoffFactor: 2.0,                 // 1s -> 2s -> 4s -> 8s -> 16s...
  maxDelay: Duration(minutes: 5),     // Maximum ceiling
  maxRetries: 5,                      // Dead-letter after 5 failures
  useJitter: true,                    // Add random spread to prevent thundering herd
);
```

When a recoverable failure occurs (e.g. server timeout), `SyncEngine` halts sequential FIFO processing for that batch to maintain causal integrity, and waits for the backoff interval before retrying.

---

## 🧪 Testing

`sync_orbit` comes with a comprehensive test suite covering models, backoff math, conflict resolvers, in-memory storage, and async FIFO engine orchestration.

Run the test suite:

```bash
flutter test
```

Or run the interactive example:

```bash
dart run example/sync_orbit_example.dart
```

---

## 📄 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.
