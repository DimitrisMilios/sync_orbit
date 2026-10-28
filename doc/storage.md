# Persistent Storage Implementations

The `SyncStorage` interface abstracts where and how queued outbox mutations are stored. This document provides complete, production-tested implementations for **Drift** and **Sqflite**.

---

## 1. Drift Implementation (Recommended)

[Drift](https://drift.simonbinder.eu/) provides type-safe Dart tables, reactive streams, and high performance.

### Schema Definition (`tables.dart`)

```dart
import 'package:drift/drift.dart';

@DataClassName('SyncOutboxEntry')
class SyncOutboxTable extends Table {
  TextColumn get id => text()();
  TextColumn get endpoint => text()();
  TextColumn get action => text()(); // 'create', 'update', 'delete'
  TextColumn get payloadJson => text()();
  DateTimeColumn get createdAt => dateTime()();
  IntColumn get retryCount => integer().withDefault(const Constant(0))();
  TextColumn get status => text()(); // 'pending', 'inFlight', 'failed', 'completed'
  DateTimeColumn get lastAttemptedAt => dateTime().nullable()();
  TextColumn get lastError => text().nullable()();
  TextColumn get metadataJson => text().nullable()();

  @override
  Set<Column> get primaryKey => {id};

  @override
  List<Set<Column>> get uniqueKeys => [];

  // Optimal index for FIFO outbox queries
  @override
  List<Index> get indexes => [
    Index('idx_outbox_status_created', 'status, created_at'),
  ];
}
```

### Storage Implementation (`drift_sync_storage.dart`)

```dart
import 'dart:convert';
import 'package:drift/drift.dart';
import 'package:sync_orbit/sync_orbit.dart';
import 'database.dart'; // Your generated AppDatabase

class DriftSyncStorage implements SyncStorage {
  final AppDatabase db;

  DriftSyncStorage(this.db);

  @override
  Future<void> initialize() async {
    // Schema created and migrated via Drift's MigrationStrategy
  }

  @override
  Future<void> saveMutation(SyncMutation mutation) async {
    await db.into(db.syncOutboxTable).insertOnConflictUpdate(
      SyncOutboxTableCompanion.insert(
        id: mutation.id,
        endpoint: mutation.endpoint,
        action: mutation.action.name,
        payloadJson: jsonEncode(mutation.payload),
        createdAt: mutation.createdAt,
        retryCount: Value(mutation.retryCount),
        status: Value(mutation.status.name),
        lastAttemptedAt: Value(mutation.lastAttemptedAt),
        lastError: Value(mutation.lastError),
        metadataJson: Value(
          mutation.metadata != null ? jsonEncode(mutation.metadata) : null,
        ),
      ),
    );
  }

  @override
  Future<List<SyncMutation>> getPendingMutations({int? limit}) async {
    var query = (db.select(db.syncOutboxTable)
      ..where((tbl) => tbl.status.isIn(['pending', 'failed']))
      ..orderBy([(tbl) => OrderingTerm.asc(tbl.createdAt)]));

    if (limit != null) {
      query = query..limit(limit);
    }

    final rows = await query.get();
    return rows.map(_toDomain).toList();
  }

  @override
  Future<SyncMutation?> getMutation(String id) async {
    final row = await (db.select(db.syncOutboxTable)
          ..where((tbl) => tbl.id.equals(id)))
        .getSingleOrNull();

    return row != null ? _toDomain(row) : null;
  }

  @override
  Future<List<SyncMutation>> getAllMutations() async {
    final rows = await (db.select(db.syncOutboxTable)
          ..orderBy([(tbl) => OrderingTerm.asc(tbl.createdAt)]))
        .get();

    return rows.map(_toDomain).toList();
  }

  @override
  Future<void> updateMutation(SyncMutation mutation) async {
    await (db.update(db.syncOutboxTable)..where((tbl) => tbl.id.equals(mutation.id)))
        .write(
      SyncOutboxTableCompanion(
        status: Value(mutation.status.name),
        retryCount: Value(mutation.retryCount),
        payloadJson: Value(jsonEncode(mutation.payload)),
        lastAttemptedAt: Value(mutation.lastAttemptedAt),
        lastError: Value(mutation.lastError),
      ),
    );
  }

  @override
  Future<void> deleteMutation(String id) async {
    await (db.delete(db.syncOutboxTable)..where((tbl) => tbl.id.equals(id))).go();
  }

  @override
  Future<void> markCompleted(String id) async {
    await (db.update(db.syncOutboxTable)..where((tbl) => tbl.id.equals(id))).write(
      SyncOutboxTableCompanion(
        status: const Value('completed'),
        lastAttemptedAt: Value(DateTime.now().toUtc()),
      ),
    );
  }

  @override
  Future<void> markFailed(String id, {String? error, DateTime? attemptedAt}) async {
    final existing = await getMutation(id);
    if (existing == null) return;

    await (db.update(db.syncOutboxTable)..where((tbl) => tbl.id.equals(id))).write(
      SyncOutboxTableCompanion(
        status: const Value('failed'),
        retryCount: Value(existing.retryCount + 1),
        lastError: Value(error),
        lastAttemptedAt: Value(attemptedAt ?? DateTime.now().toUtc()),
      ),
    );
  }

  @override
  Future<int> getPendingCount() async {
    final countExp = db.syncOutboxTable.id.count();
    final query = db.selectOnly(db.syncOutboxTable)
      ..where(db.syncOutboxTable.status.isIn(['pending', 'failed']))
      ..addColumns([countExp]);

    return (await query.map((row) => row.read(countExp)).getSingle()) ?? 0;
  }

  @override
  Future<void> clear() async {
    await db.delete(db.syncOutboxTable).go();
  }

  @override
  Future<void> dispose() async {}

  SyncMutation _toDomain(SyncOutboxEntry row) {
    return SyncMutation(
      id: row.id,
      endpoint: row.endpoint,
      action: SyncAction.fromString(row.action),
      payload: jsonDecode(row.payloadJson) as Map<String, dynamic>,
      createdAt: row.createdAt,
      retryCount: row.retryCount,
      status: SyncStatus.fromString(row.status),
      lastAttemptedAt: row.lastAttemptedAt,
      lastError: row.lastError,
      metadata: row.metadataJson != null
          ? jsonDecode(row.metadataJson!) as Map<String, dynamic>
          : null,
    );
  }
}
```

---

## 2. Sqflite Implementation

For projects using raw SQLite via `package:sqflite`:

```dart
import 'dart:convert';
import 'package:sqflite/sqflite.dart';
import 'package:sync_orbit/sync_orbit.dart';

class SqfliteSyncStorage implements SyncStorage {
  final Database db;
  static const String tableName = 'sync_outbox';

  SqfliteSyncStorage(this.db);

  @override
  Future<void> initialize() async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS $tableName (
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
      );
    ''');

    // Index for high-performance FIFO extraction
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_outbox_fifo 
      ON $tableName (status, createdAt ASC);
    ''');
  }

  @override
  Future<void> saveMutation(SyncMutation mutation) async {
    await db.insert(
      tableName,
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
    final rows = await db.query(
      tableName,
      where: 'status IN (?, ?)',
      whereArgs: [SyncStatus.pending.name, SyncStatus.failed.name],
      orderBy: 'createdAt ASC',
      limit: limit,
    );

    return rows.map(_fromRow).toList();
  }

  @override
  Future<SyncMutation?> getMutation(String id) async {
    final rows = await db.query(
      tableName,
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return _fromRow(rows.first);
  }

  @override
  Future<List<SyncMutation>> getAllMutations() async {
    final rows = await db.query(tableName, orderBy: 'createdAt ASC');
    return rows.map(_fromRow).toList();
  }

  @override
  Future<void> updateMutation(SyncMutation mutation) async {
    await db.update(
      tableName,
      {
        'status': mutation.status.name,
        'retryCount': mutation.retryCount,
        'payload': jsonEncode(mutation.payload),
        'lastAttemptedAt': mutation.lastAttemptedAt?.toIso8601String(),
        'lastError': mutation.lastError,
      },
      where: 'id = ?',
      whereArgs: [mutation.id],
    );
  }

  @override
  Future<void> deleteMutation(String id) async {
    await db.delete(tableName, where: 'id = ?', whereArgs: [id]);
  }

  @override
  Future<void> markCompleted(String id) async {
    await db.update(
      tableName,
      {
        'status': SyncStatus.completed.name,
        'lastAttemptedAt': DateTime.now().toUtc().toIso8601String(),
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  @override
  Future<void> markFailed(String id, {String? error, DateTime? attemptedAt}) async {
    await db.rawUpdate('''
      UPDATE $tableName
      SET status = ?, retryCount = retryCount + 1, lastError = ?, lastAttemptedAt = ?
      WHERE id = ?
    ''', [
      SyncStatus.failed.name,
      error,
      (attemptedAt ?? DateTime.now().toUtc()).toIso8601String(),
      id,
    ]);
  }

  @override
  Future<int> getPendingCount() async {
    final result = await db.rawQuery(
      'SELECT COUNT(*) as count FROM $tableName WHERE status IN (?, ?)',
      [SyncStatus.pending.name, SyncStatus.failed.name],
    );
    return Sqflite.firstIntValue(result) ?? 0;
  }

  @override
  Future<void> clear() async {
    await db.delete(tableName);
  }

  @override
  Future<void> dispose() async {}

  SyncMutation _fromRow(Map<String, dynamic> row) {
    return SyncMutation(
      id: row['id'] as String,
      endpoint: row['endpoint'] as String,
      action: SyncAction.fromString(row['action'] as String),
      payload: jsonDecode(row['payload'] as String) as Map<String, dynamic>,
      createdAt: DateTime.parse(row['createdAt'] as String).toUtc(),
      retryCount: row['retryCount'] as int,
      status: SyncStatus.fromString(row['status'] as String),
      lastAttemptedAt: row['lastAttemptedAt'] != null
          ? DateTime.parse(row['lastAttemptedAt'] as String).toUtc()
          : null,
      lastError: row['lastError'] as String?,
      metadata: row['metadata'] != null
          ? jsonDecode(row['metadata'] as String) as Map<String, dynamic>
          : null,
    );
  }
}
```
