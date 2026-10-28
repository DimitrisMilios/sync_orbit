import '../models/sync_mutation.dart';

/// Contract defining persistent storage operations for the outbox mutation queue.
///
/// Implementations can back this interface with SQLite (via `sqflite` or `drift`),
/// Hive, Isar, ObjectBox, or in-memory structures.
abstract interface class SyncStorage {
  /// Prepares the storage layer (e.g. opens connections, runs migrations).
  Future<void> initialize();

  /// Saves a new mutation or overwrites an existing mutation by its id.
  Future<void> saveMutation(SyncMutation mutation);

  /// Retrieves a specific mutation by its unique [id], or null if not found.
  Future<SyncMutation?> getMutation(String id);

  /// Retrieves all pending mutations ordered chronologically (FIFO: oldest first).
  ///
  /// If [limit] is provided, only up to [limit] mutations are returned.
  Future<List<SyncMutation>> getPendingMutations({int? limit});

  /// Retrieves all mutations in the queue regardless of their current status.
  Future<List<SyncMutation>> getAllMutations();

  /// Updates an existing mutation in the store (e.g., status, payload, retryCount).
  Future<void> updateMutation(SyncMutation mutation);

  /// Deletes a mutation permanently from storage by its [id].
  Future<void> deleteMutation(String id);

  /// Marks the mutation with [id] as successfully completed.
  Future<void> markCompleted(String id);

  /// Marks the mutation with [id] as failed, recording the latest error and attempt timestamp.
  Future<void> markFailed(String id, {String? error, DateTime? attemptedAt});

  /// Returns the total count of pending mutations waiting in the queue.
  Future<int> getPendingCount();

  /// Clears all mutations from the storage.
  Future<void> clear();

  /// Releases any open resources, streams, or database connections.
  Future<void> dispose();
}
