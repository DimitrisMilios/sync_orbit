import 'dart:async';
import '../models/sync_mutation.dart';
import '../models/sync_status.dart';
import 'sync_storage.dart';

/// An in-memory implementation of [SyncStorage].
///
/// Useful for unit testing, integration tests, or mock environments without
/// requiring an SQLite or native database setup.
class InMemorySyncStorage implements SyncStorage {
  final Map<String, SyncMutation> _mutations = {};
  bool _isDisposed = false;

  void _checkDisposed() {
    if (_isDisposed) {
      throw StateError('InMemorySyncStorage has already been disposed.');
    }
  }

  @override
  Future<void> initialize() async {
    _checkDisposed();
    // In-memory requires no initialization.
  }

  @override
  Future<void> saveMutation(SyncMutation mutation) async {
    _checkDisposed();
    _mutations[mutation.id] = mutation;
  }

  @override
  Future<SyncMutation?> getMutation(String id) async {
    _checkDisposed();
    return _mutations[id];
  }

  @override
  Future<List<SyncMutation>> getPendingMutations({int? limit}) async {
    _checkDisposed();
    final pending = _mutations.values
        .where((m) => m.status == SyncStatus.pending || m.status == SyncStatus.failed)
        .toList()
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));

    if (limit != null && limit > 0) {
      return pending.take(limit).toList();
    }
    return pending;
  }

  @override
  Future<List<SyncMutation>> getAllMutations() async {
    _checkDisposed();
    final list = _mutations.values.toList()
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    return list;
  }

  @override
  Future<void> updateMutation(SyncMutation mutation) async {
    _checkDisposed();
    if (_mutations.containsKey(mutation.id)) {
      _mutations[mutation.id] = mutation;
    }
  }

  @override
  Future<void> deleteMutation(String id) async {
    _checkDisposed();
    _mutations.remove(id);
  }

  @override
  Future<void> markCompleted(String id) async {
    _checkDisposed();
    final mutation = _mutations[id];
    if (mutation != null) {
      _mutations[id] = mutation.copyWith(
        status: SyncStatus.completed,
        lastAttemptedAt: DateTime.now().toUtc(),
      );
    }
  }

  @override
  Future<void> markFailed(String id, {String? error, DateTime? attemptedAt}) async {
    _checkDisposed();
    final mutation = _mutations[id];
    if (mutation != null) {
      _mutations[id] = mutation.copyWith(
        status: SyncStatus.failed,
        retryCount: mutation.retryCount + 1,
        lastAttemptedAt: attemptedAt ?? DateTime.now().toUtc(),
        lastError: error,
      );
    }
  }

  @override
  Future<int> getPendingCount() async {
    _checkDisposed();
    return _mutations.values
        .where((m) => m.status == SyncStatus.pending || m.status == SyncStatus.failed)
        .length;
  }

  @override
  Future<void> clear() async {
    _checkDisposed();
    _mutations.clear();
  }

  @override
  Future<void> dispose() async {
    _mutations.clear();
    _isDisposed = true;
  }
}
