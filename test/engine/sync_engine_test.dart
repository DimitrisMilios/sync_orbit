import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:sync_orbit/sync_orbit.dart';

class MockSyncAdapter implements SyncAdapter {
  final List<SyncMutation> dispatched = [];
  FutureOr<SyncAdapterResult> Function(SyncMutation mutation)? onSend;

  @override
  Future<SyncAdapterResult> send(SyncMutation mutation) async {
    dispatched.add(mutation);
    if (onSend != null) {
      return await onSend!(mutation);
    }
    return const SyncAdapterSuccess();
  }
}

void main() {
  late InMemorySyncStorage storage;
  late MockSyncAdapter adapter;
  late StreamController<bool> connectivityController;

  setUp(() async {
    storage = InMemorySyncStorage();
    await storage.initialize();
    adapter = MockSyncAdapter();
    connectivityController = StreamController<bool>.broadcast();
  });

  tearDown(() async {
    await storage.dispose();
    await connectivityController.close();
  });

  group('SyncEngine - Offline Enqueuing & FIFO Sequential Flush', () {
    test('enqueues mutations locally when offline and preserves FIFO order', () async {
      final engine = SyncEngine(
        storage: storage,
        adapter: adapter,
        connectivityStream: connectivityController.stream,
        options: const SyncEngineOptions(autoFlushOnEnqueue: true),
      );

      // Start offline
      connectivityController.add(false);
      await pumpEventQueue();

      expect(engine.isOnline, isFalse);

      final now = DateTime.utc(2026, 10, 28, 12, 0, 0);

      // Enqueue 3 mutations
      await engine.queue(
        id: '1',
        endpoint: 'todos',
        action: SyncAction.create,
        payload: {'title': 'First todo'},
        createdAt: now,
      );

      await engine.queue(
        id: '2',
        endpoint: 'todos',
        action: SyncAction.update,
        payload: {'title': 'Second todo'},
        createdAt: now.add(const Duration(seconds: 1)),
      );

      await engine.queue(
        id: '3',
        endpoint: 'todos',
        action: SyncAction.delete,
        payload: {'id': 99},
        createdAt: now.add(const Duration(seconds: 2)),
      );

      // Storage should have 3 pending mutations, but nothing dispatched to adapter
      expect(await storage.getPendingCount(), 3);
      expect(adapter.dispatched, isEmpty);

      // Go online -> engine should auto flush in FIFO order
      connectivityController.add(true);
      await pumpEventQueue();

      // Let async flush finish
      await engine.flush();

      expect(adapter.dispatched.length, 3);
      expect(adapter.dispatched.map((m) => m.id).toList(), ['1', '2', '3']);
      expect(await storage.getPendingCount(), 0);

      await engine.dispose();
    });

    test('retains mutations when deleteOnSuccess is false', () async {
      final engine = SyncEngine(
        storage: storage,
        adapter: adapter,
        options: const SyncEngineOptions(
          deleteOnSuccess: false,
          autoFlushOnEnqueue: false,
        ),
      );

      await engine.queue(
        id: 'keep-1',
        endpoint: 'users',
        action: SyncAction.create,
        payload: {'name': 'Bob'},
      );

      final flushResult = await engine.flush();
      expect(flushResult.successCount, 1);

      final saved = await storage.getMutation('keep-1');
      expect(saved, isNotNull);
      expect(saved?.status, SyncStatus.completed);

      await engine.dispose();
    });
  });

  group('SyncEngine - Conflict Resolution', () {
    test('ServerWinsResolver discards client mutation on conflict', () async {
      adapter.onSend = (mutation) {
        return SyncAdapterConflict(
          serverPayload: {'title': 'Server Wins Payload'},
          reason: 'Remote version higher',
        );
      };

      final engine = SyncEngine(
        storage: storage,
        adapter: adapter,
        conflictResolver: const ServerWinsResolver(),
        options: const SyncEngineOptions(
          deleteOnSuccess: true,
          autoFlushOnEnqueue: false,
        ),
      );

      await engine.queue(
        id: 'conf-1',
        endpoint: 'notes',
        action: SyncAction.update,
        payload: {'title': 'Client Payload'},
      );

      final flushResult = await engine.flush();
      expect(flushResult.conflictCount, 1);
      // Under ServerWins and deleteOnSuccess, mutation is cleaned up
      expect(await storage.getPendingCount(), 0);

      await engine.dispose();
    });

    test('ClientWinsResolver re-dispatches with forceWrite flag', () async {
      int callCount = 0;
      adapter.onSend = (mutation) {
        callCount++;
        if (callCount == 1) {
          // First attempt yields conflict
          return const SyncAdapterConflict(
            serverPayload: {'version': 2},
            reason: 'Conflict detected',
          );
        }
        // Second attempt with force write succeeds
        expect(mutation.metadata?['forceWrite'], isTrue);
        return const SyncAdapterSuccess();
      };

      final engine = SyncEngine(
        storage: storage,
        adapter: adapter,
        conflictResolver: const ClientWinsResolver(),
        options: const SyncEngineOptions(autoFlushOnEnqueue: false),
      );

      await engine.queue(
        id: 'client-wins-1',
        endpoint: 'notes',
        action: SyncAction.update,
        payload: {'version': 1},
      );

      final result = await engine.flush();
      expect(result.conflictCount, 1);
      expect(callCount, 2);
      expect(await storage.getPendingCount(), 0);

      await engine.dispose();
    });

    test('CustomConflictResolver merges payload and re-dispatches', () async {
      int callCount = 0;
      adapter.onSend = (mutation) {
        callCount++;
        if (callCount == 1) {
          return const SyncAdapterConflict(
            serverPayload: {'serverKey': 'serverVal'},
          );
        }
        expect(mutation.payload['serverKey'], 'serverVal');
        expect(mutation.payload['clientKey'], 'clientVal');
        return const SyncAdapterSuccess();
      };

      final engine = SyncEngine(
        storage: storage,
        adapter: adapter,
        conflictResolver: CustomConflictResolver(({
          required clientMutation,
          required serverConflict,
        }) {
          return ConflictResolution.merge({
            ...serverConflict.serverPayload,
            ...clientMutation.payload,
          });
        }),
        options: const SyncEngineOptions(autoFlushOnEnqueue: false),
      );

      await engine.queue(
        id: 'merge-1',
        endpoint: 'items',
        action: SyncAction.update,
        payload: {'clientKey': 'clientVal'},
      );

      final result = await engine.flush();
      expect(result.conflictCount, 1);
      expect(callCount, 2);
      expect(await storage.getPendingCount(), 0);

      await engine.dispose();
    });
  });

  group('SyncEngine - Exponential Backoff & Error Handling', () {
    test('halts sequential FIFO queue on recoverable failure', () async {
      int attempts = 0;
      adapter.onSend = (mutation) {
        attempts++;
        if (mutation.id == 'fail-1') {
          return const SyncAdapterFailure(
            error: '503 Service Unavailable',
            isRecoverable: true,
          );
        }
        return const SyncAdapterSuccess();
      };

      final engine = SyncEngine(
        storage: storage,
        adapter: adapter,
        options: const SyncEngineOptions(autoFlushOnEnqueue: false),
      );

      await engine.queue(
        id: 'fail-1',
        endpoint: 'orders',
        action: SyncAction.create,
        payload: {'item': 'A'},
        createdAt: DateTime.utc(2026, 10, 28, 10, 0, 0),
      );

      await engine.queue(
        id: 'next-2',
        endpoint: 'orders',
        action: SyncAction.create,
        payload: {'item': 'B'},
        createdAt: DateTime.utc(2026, 10, 28, 10, 0, 1),
      );

      final result = await engine.flush();

      // Only first mutation was attempted; second was halted to preserve FIFO
      expect(attempts, 1);
      expect(result.failureCount, 1);
      expect(result.isCompleted, isFalse);

      final failedMutation = await storage.getMutation('fail-1');
      expect(failedMutation?.status, SyncStatus.failed);
      expect(failedMutation?.retryCount, 1);
      expect(failedMutation?.lastError, '503 Service Unavailable');

      await engine.dispose();
    });
  });

  group('SyncEngine - Concurrency & Lifecycle', () {
    test('concurrent calls to flush return the same Future', () async {
      final completer = Completer<SyncAdapterResult>();
      adapter.onSend = (m) => completer.future;

      final engine = SyncEngine(
        storage: storage,
        adapter: adapter,
        options: const SyncEngineOptions(autoFlushOnEnqueue: false),
      );

      await engine.queue(
        id: 'async-1',
        endpoint: 'sync',
        action: SyncAction.create,
        payload: {},
      );

      final flushFuture1 = engine.flush();
      final flushFuture2 = engine.flush();

      // Both futures should reference the same flush execution
      expect(identical(flushFuture1, flushFuture2), isTrue);

      completer.complete(const SyncAdapterSuccess());
      final result1 = await flushFuture1;
      final result2 = await flushFuture2;

      expect(result1.successCount, 1);
      expect(result2.successCount, 1);

      await engine.dispose();
    });

    test('pause and resume halts and triggers flush', () async {
      final engine = SyncEngine(
        storage: storage,
        adapter: adapter,
        options: const SyncEngineOptions(autoFlushOnEnqueue: false),
      );

      engine.pause();
      expect(engine.isPaused, isTrue);

      await engine.queue(
        id: 'paused-1',
        endpoint: 'tasks',
        action: SyncAction.create,
        payload: {},
      );

      final flushResult = await engine.flush();
      expect(flushResult.totalAttempted, 0); // Nothing run while paused

      engine.resume();
      expect(engine.isPaused, isFalse);

      // resumed should auto flush or allow flush
      final resumeFlush = await engine.flush();
      expect(resumeFlush.successCount, 1);

      await engine.dispose();
    });
  });
}
