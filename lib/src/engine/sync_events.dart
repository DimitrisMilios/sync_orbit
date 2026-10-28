import 'package:meta/meta.dart';
import '../adapter/sync_adapter_result.dart';
import '../conflict/conflict_resolution.dart';
import '../models/sync_mutation.dart';

/// Processing state of the [SyncEngine].
enum SyncEngineState {
  /// The engine is idle, waiting for new mutations or network events.
  idle,

  /// The engine is actively synchronizing pending mutations with the remote adapter.
  syncing,

  /// The engine is currently offline; automatic flushing is paused.
  offline,

  /// The engine is manually paused by the application.
  paused,
}

/// Summary of a completed sync flush operation.
@immutable
class SyncFlushResult {
  /// Total number of mutations evaluated during this flush execution.
  final int totalAttempted;

  /// Count of mutations successfully accepted by the remote adapter.
  final int successCount;

  /// Count of mutations that triggered a conflict.
  final int conflictCount;

  /// Count of mutations that encountered an error.
  final int failureCount;

  /// Mutations that failed during this flush pass.
  final List<SyncMutation> failedMutations;

  /// Whether the queue was completely processed without encountering blocking network errors.
  final bool isCompleted;

  const SyncFlushResult({
    required this.totalAttempted,
    required this.successCount,
    required this.conflictCount,
    required this.failureCount,
    required this.failedMutations,
    required this.isCompleted,
  });

  /// An empty flush result indicating nothing was queued.
  static const empty = SyncFlushResult(
    totalAttempted: 0,
    successCount: 0,
    conflictCount: 0,
    failureCount: 0,
    failedMutations: [],
    isCompleted: true,
  );

  @override
  String toString() =>
      'SyncFlushResult(attempted: $totalAttempted, succeeded: $successCount, '
      'conflicts: $conflictCount, failed: $failureCount, completed: $isCompleted)';
}

/// Base sealed class for all sync orchestrator events.
@immutable
sealed class SyncEvent {
  const SyncEvent();
}

/// Emitted when a new mutation has been saved to the outbox queue.
class MutationQueuedEvent extends SyncEvent {
  final SyncMutation mutation;
  const MutationQueuedEvent(this.mutation);

  @override
  String toString() => 'MutationQueuedEvent(id: ${mutation.id}, endpoint: ${mutation.endpoint})';
}

/// Emitted when a mutation begins its dispatch to the remote adapter.
class MutationSyncStartedEvent extends SyncEvent {
  final SyncMutation mutation;
  const MutationSyncStartedEvent(this.mutation);

  @override
  String toString() => 'MutationSyncStartedEvent(id: ${mutation.id})';
}

/// Emitted when a mutation is successfully acknowledged by the remote adapter.
class MutationSyncedEvent extends SyncEvent {
  final SyncMutation mutation;
  final SyncAdapterSuccess result;
  const MutationSyncedEvent(this.mutation, this.result);

  @override
  String toString() => 'MutationSyncedEvent(id: ${mutation.id})';
}

/// Emitted when a conflict was detected and resolved.
class MutationConflictResolvedEvent extends SyncEvent {
  final SyncMutation mutation;
  final ConflictResolution resolution;
  final SyncAdapterConflict conflict;

  const MutationConflictResolvedEvent({
    required this.mutation,
    required this.resolution,
    required this.conflict,
  });

  @override
  String toString() =>
      'MutationConflictResolvedEvent(id: ${mutation.id}, resolution: $resolution)';
}

/// Emitted when a mutation failed during execution.
class MutationFailedEvent extends SyncEvent {
  final SyncMutation mutation;
  final SyncAdapterFailure failure;
  final bool willRetry;

  const MutationFailedEvent({
    required this.mutation,
    required this.failure,
    required this.willRetry,
  });

  @override
  String toString() =>
      'MutationFailedEvent(id: ${mutation.id}, error: ${failure.error}, willRetry: $willRetry)';
}

/// Emitted when a flush cycle starts.
class SyncFlushStartedEvent extends SyncEvent {
  const SyncFlushStartedEvent();

  @override
  String toString() => 'SyncFlushStartedEvent()';
}

/// Emitted when a flush cycle completes.
class SyncFlushCompletedEvent extends SyncEvent {
  final SyncFlushResult result;
  const SyncFlushCompletedEvent(this.result);

  @override
  String toString() => 'SyncFlushCompletedEvent($result)';
}
