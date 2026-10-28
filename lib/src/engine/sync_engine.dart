import 'dart:async';

import '../adapter/sync_adapter.dart';
import '../adapter/sync_adapter_result.dart';
import '../conflict/conflict_resolution.dart';
import '../conflict/conflict_resolver.dart';
import '../conflict/resolvers.dart';
import '../connectivity/sync_connectivity.dart';
import '../models/sync_action.dart';
import '../models/sync_mutation.dart';
import '../models/sync_status.dart';
import '../retry/retry_policy.dart';
import '../storage/sync_storage.dart';
import 'sync_engine_options.dart';
import 'sync_events.dart';

/// The central coordinator for offline-first local synchronization and outbox management.
///
/// [SyncEngine] manages:
/// - Enqueueing mutations locally when offline.
/// - Monitoring network connectivity via an injected [SyncConnectivity] or [Stream<bool>].
/// - Sequentially flushing mutations (FIFO) to the remote [SyncAdapter].
/// - Resolving merge and version conflicts using a pluggable [ConflictResolver].
/// - Calculating exponential backoff delays on transient network failures.
class SyncEngine {
  /// The local persistence layer storing queued mutations.
  final SyncStorage storage;

  /// The remote network adapter sending mutations to the backend.
  final SyncAdapter adapter;

  /// Injected network connectivity monitor. If null, engine assumes continuous connectivity.
  final SyncConnectivity? connectivity;

  /// Pluggable strategy for resolving server/client version conflicts.
  final ConflictResolver conflictResolver;

  /// Policy controlling retry limits and exponential backoff timing.
  final RetryPolicy retryPolicy;

  /// Operational settings for flush behaviors and queue pruning.
  final SyncEngineOptions options;

  final StreamController<SyncEngineState> _stateController =
      StreamController<SyncEngineState>.broadcast();
  final StreamController<SyncEvent> _eventsController =
      StreamController<SyncEvent>.broadcast();

  StreamSubscription<bool>? _connectivitySubscription;
  Future<SyncFlushResult>? _activeFlush;
  SyncEngineState _currentState = SyncEngineState.idle;
  bool _isPaused = false;
  bool _isDisposed = false;

  /// Creates a [SyncEngine].
  ///
  /// Either [connectivity] or [connectivityStream] can be provided to monitor network status.
  SyncEngine({
    required this.storage,
    required this.adapter,
    SyncConnectivity? connectivity,
    Stream<bool>? connectivityStream,
    ConflictResolver? conflictResolver,
    RetryPolicy? retryPolicy,
    SyncEngineOptions? options,
  })  : connectivity = connectivity ??
            (connectivityStream != null
                ? SyncConnectivity.fromStream(connectivityStream)
                : null),
        conflictResolver = conflictResolver ?? const LastWriteWinsResolver(),
        retryPolicy = retryPolicy ?? const RetryPolicy(),
        options = options ?? const SyncEngineOptions() {
    if (this.connectivity != null) {
      _initConnectivity(this.connectivity!);
    } else {
      _currentState = SyncEngineState.idle;
    }
  }

  /// Current processing state of the engine.
  SyncEngineState get state => _currentState;

  /// Whether the engine is currently paused.
  bool get isPaused => _isPaused;

  /// Whether the engine currently has network connectivity.
  bool get isOnline => connectivity?.isOnline ?? true;

  /// Stream of engine state transitions (idle, syncing, offline, paused).
  Stream<SyncEngineState> get onStateChanged => _stateController.stream;

  /// Stream of detailed sync events (mutation queued, synced, conflict resolved, failed).
  Stream<SyncEvent> get onEvent => _eventsController.stream;

  void _initConnectivity(SyncConnectivity conn) {
    _currentState = conn.isOnline ? SyncEngineState.idle : SyncEngineState.offline;

    _connectivitySubscription = conn.onConnectivityChanged.listen((online) {
      if (_isDisposed || _isPaused) return;

      if (online) {
        _setState(SyncEngineState.idle);
        if (options.autoFlushOnOnline) {
          flush();
        }
      } else {
        _setState(SyncEngineState.offline);
      }
    });
  }

  void _setState(SyncEngineState newState) {
    if (_currentState != newState && !_stateController.isClosed) {
      _currentState = newState;
      _stateController.add(newState);
    }
  }

  void _emit(SyncEvent event) {
    if (!_eventsController.isClosed) {
      _eventsController.add(event);
    }
  }

  void _checkDisposed() {
    if (_isDisposed) {
      throw StateError('SyncEngine has already been disposed.');
    }
  }

  /// Initializes the storage layer and prepares the sync engine.
  Future<void> initialize() async {
    _checkDisposed();
    await storage.initialize();

    if (isOnline && options.autoFlushOnOnline && !_isPaused) {
      // Trigger initial flush in background if pending mutations exist
      unawaited(flush());
    }
  }

  /// Helper to create and enqueue a mutation in a single call.
  ///
  /// Returns the newly created [SyncMutation].
  Future<SyncMutation> queue({
    String? id,
    required String endpoint,
    required SyncAction action,
    required Map<String, dynamic> payload,
    DateTime? createdAt,
    Map<String, dynamic>? metadata,
  }) async {
    final mutation = SyncMutation(
      id: id,
      endpoint: endpoint,
      action: action,
      payload: payload,
      createdAt: createdAt,
      metadata: metadata,
    );
    await enqueue(mutation);
    return mutation;
  }

  /// Enqueues an existing [SyncMutation] into the outbox storage.
  ///
  /// If the engine is online, not paused, and [SyncEngineOptions.autoFlushOnEnqueue]
  /// is enabled, an asynchronous flush is initiated.
  Future<void> enqueue(SyncMutation mutation) async {
    _checkDisposed();
    await storage.saveMutation(mutation);
    _emit(MutationQueuedEvent(mutation));

    if (isOnline && !_isPaused && options.autoFlushOnEnqueue) {
      // Trigger flush without awaiting to not block the enqueue caller
      unawaited(flush());
    }
  }

  /// Flushes all pending mutations sequentially in First-In-First-Out (FIFO) order.
  ///
  /// If a flush operation is already running, returns the existing in-flight [Future]
  /// to ensure safe concurrency and prevent duplicate execution.
  Future<SyncFlushResult> flush() {
    _checkDisposed();

    if (_activeFlush != null) {
      return _activeFlush!;
    }

    final flushCompleter = Completer<SyncFlushResult>();
    _activeFlush = flushCompleter.future;

    () async {
      try {
        final result = await _executeFlush();
        flushCompleter.complete(result);
      } catch (error, stackTrace) {
        flushCompleter.completeError(error, stackTrace);
      } finally {
        _activeFlush = null;
      }
    }();

    return _activeFlush!;
  }

  Future<SyncFlushResult> _executeFlush() async {
    if (_isPaused) {
      return SyncFlushResult.empty;
    }

    if (!isOnline) {
      _setState(SyncEngineState.offline);
      return SyncFlushResult.empty;
    }

    _setState(SyncEngineState.syncing);
    _emit(const SyncFlushStartedEvent());

    int successCount = 0;
    int conflictCount = 0;
    int failureCount = 0;
    final List<SyncMutation> failedMutations = [];
    bool isCompleted = true;

    try {
      final pendingMutations = await storage.getPendingMutations(
        limit: options.batchSize,
      );

      if (pendingMutations.isEmpty) {
        return SyncFlushResult.empty;
      }

      flushLoop:
      for (final mutation in pendingMutations) {
        // If engine was paused or went offline during the loop, stop immediately
        if (_isPaused || !isOnline) {
          isCompleted = false;
          break flushLoop;
        }

        // Verify exponential backoff delay has passed for previously failed mutations
        if (!retryPolicy.isReadyForRetry(mutation)) {
          // In strict FIFO ordering, wait until backoff delay elapses before proceeding
          isCompleted = false;
          break flushLoop;
        }

        // Mark in flight
        final inFlightMutation = mutation.copyWith(status: SyncStatus.inFlight);
        await storage.updateMutation(inFlightMutation);
        _emit(MutationSyncStartedEvent(inFlightMutation));

        // Dispatch to remote adapter
        final adapterResult = await adapter.send(inFlightMutation);

        switch (adapterResult) {
          case SyncAdapterSuccess():
            successCount++;
            if (options.deleteOnSuccess) {
              await storage.deleteMutation(mutation.id);
            } else {
              await storage.markCompleted(mutation.id);
            }
            _emit(MutationSyncedEvent(inFlightMutation, adapterResult));

          case SyncAdapterConflict():
            conflictCount++;
            final resolution = await conflictResolver.resolve(
              clientMutation: inFlightMutation,
              serverConflict: adapterResult,
            );

            _emit(MutationConflictResolvedEvent(
              mutation: inFlightMutation,
              resolution: resolution,
              conflict: adapterResult,
            ));

            await _handleConflictResolution(
              inFlightMutation,
              adapterResult,
              resolution,
            );

          case SyncAdapterFailure():
            failureCount++;
            final willRetry = retryPolicy.shouldRetry(
              inFlightMutation,
              isRecoverable: adapterResult.isRecoverable,
            );

            await storage.markFailed(
              mutation.id,
              error: adapterResult.error,
              attemptedAt: DateTime.now().toUtc(),
            );

            final updatedFailedMutation = (await storage.getMutation(mutation.id)) ??
                inFlightMutation.copyWith(
                  status: SyncStatus.failed,
                  retryCount: inFlightMutation.retryCount + 1,
                  lastError: adapterResult.error,
                );

            failedMutations.add(updatedFailedMutation);

            _emit(MutationFailedEvent(
              mutation: updatedFailedMutation,
              failure: adapterResult,
              willRetry: willRetry,
            ));

            // If error is recoverable (e.g. server down / network drop), halt sequential processing
            if (adapterResult.isRecoverable) {
              isCompleted = false;
              break flushLoop;
            }
        }
      }

      final result = SyncFlushResult(
        totalAttempted: successCount + conflictCount + failureCount,
        successCount: successCount,
        conflictCount: conflictCount,
        failureCount: failureCount,
        failedMutations: failedMutations,
        isCompleted: isCompleted,
      );

      _emit(SyncFlushCompletedEvent(result));
      return result;
    } finally {
      _setState(_isPaused
          ? SyncEngineState.paused
          : (!isOnline ? SyncEngineState.offline : SyncEngineState.idle));
    }
  }

  Future<void> _handleConflictResolution(
    SyncMutation mutation,
    SyncAdapterConflict conflict,
    ConflictResolution resolution,
  ) async {
    switch (resolution) {
      case ServerWinsResolution():
        // Remote server version wins. Mark completed or delete local mutation.
        if (options.deleteOnSuccess) {
          await storage.deleteMutation(mutation.id);
        } else {
          await storage.markCompleted(mutation.id);
        }

      case ClientWinsResolution():
        // Client wins: re-dispatch with a forced flag in metadata
        final forcedMetadata = {
          ...?mutation.metadata,
          'forceWrite': true,
          'conflictResolution': 'clientWins',
        };
        final forcedMutation = mutation.copyWith(metadata: forcedMetadata);
        final forceResult = await adapter.send(forcedMutation);

        if (forceResult is SyncAdapterSuccess) {
          if (options.deleteOnSuccess) {
            await storage.deleteMutation(mutation.id);
          } else {
            await storage.markCompleted(mutation.id);
          }
          _emit(MutationSyncedEvent(forcedMutation, forceResult));
        } else {
          // If force write failed, mark as failed for standard retry
          await storage.markFailed(
            mutation.id,
            error: forceResult is SyncAdapterFailure
                ? forceResult.error
                : 'ClientWins override rejected by adapter',
          );
        }

      case MergeResolution(:final mergedPayload):
        // Update payload with merged state and send to adapter
        final mergedMutation = mutation.copyWith(
          payload: mergedPayload,
          metadata: {
            ...?mutation.metadata,
            'conflictResolution': 'merged',
          },
        );
        await storage.updateMutation(mergedMutation);
        final mergeResult = await adapter.send(mergedMutation);

        if (mergeResult is SyncAdapterSuccess) {
          if (options.deleteOnSuccess) {
            await storage.deleteMutation(mutation.id);
          } else {
            await storage.markCompleted(mutation.id);
          }
          _emit(MutationSyncedEvent(mergedMutation, mergeResult));
        } else {
          await storage.markFailed(
            mutation.id,
            error: mergeResult is SyncAdapterFailure
                ? mergeResult.error
                : 'Merge payload rejected by adapter',
          );
        }

      case DiscardResolution():
        // Discard the conflicting mutation
        await storage.deleteMutation(mutation.id);
    }
  }

  /// Pauses the sync engine. No flushes will execute while paused.
  void pause() {
    _isPaused = true;
    _setState(SyncEngineState.paused);
  }

  /// Resumes the sync engine and triggers a flush if online.
  void resume() {
    _isPaused = false;
    _setState(isOnline ? SyncEngineState.idle : SyncEngineState.offline);
    if (isOnline && options.autoFlushOnOnline) {
      flush();
    }
  }

  /// Releases all stream controllers, subscriptions, and storage resources.
  Future<void> dispose() async {
    if (_isDisposed) return;
    _isDisposed = true;

    await _connectivitySubscription?.cancel();
    connectivity?.dispose();
    await _stateController.close();
    await _eventsController.close();
    await storage.dispose();
  }
}
