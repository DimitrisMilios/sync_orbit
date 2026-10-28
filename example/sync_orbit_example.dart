// ignore_for_file: avoid_print

import 'dart:async';
import 'package:sync_orbit/sync_orbit.dart';

/// A sample HTTP REST adapter demonstrating how to integrate `sync_orbit`
/// with your remote backend.
class ExampleRestAdapter implements SyncAdapter {
  final bool simulateConflict;

  ExampleRestAdapter({this.simulateConflict = false});

  @override
  Future<SyncAdapterResult> send(SyncMutation mutation) async {
    // Simulate remote network latency
    await Future<void>.delayed(const Duration(milliseconds: 150));

    print('📡 [Remote Adapter] Processing ${mutation.action.name.toUpperCase()} on /${mutation.endpoint}');
    print('   Payload: ${mutation.payload}');

    if (simulateConflict && mutation.endpoint == 'documents') {
      print('⚠️  [Remote Adapter] Conflict detected! Remote has version 2.');
      return SyncAdapterConflict(
        serverPayload: {
          'id': mutation.payload['id'],
          'title': 'Remote Server Title',
          'updated_at': DateTime.now().toUtc().toIso8601String(),
        },
        serverTimestamp: DateTime.now().toUtc(),
        reason: 'Revision conflict',
      );
    }

    // Success response
    return SyncAdapterSuccess(
      statusCode: 200,
      responseData: {'status': 'saved', 'id': mutation.id},
    );
  }
}

void main() async {
  print('=== Sync Orbit Demo: Offline-First Synchronization ===\n');

  // 1. Initialize local storage (InMemory for demo; replace with Sqflite or Drift in production)
  final storage = InMemorySyncStorage();
  await storage.initialize();

  // 2. Setup a simulated connectivity stream
  final connectivityController = StreamController<bool>.broadcast();

  // 3. Configure the SyncEngine
  final engine = SyncEngine(
    storage: storage,
    adapter: ExampleRestAdapter(simulateConflict: false),
    connectivityStream: connectivityController.stream,
    conflictResolver: const LastWriteWinsResolver(),
    retryPolicy: const RetryPolicy(
      initialDelay: Duration(seconds: 1),
      backoffFactor: 2.0,
      maxRetries: 3,
    ),
    options: const SyncEngineOptions(
      deleteOnSuccess: true,
      autoFlushOnOnline: true,
      autoFlushOnEnqueue: true,
    ),
  );

  await engine.initialize();

  // Listen to engine state and events
  engine.onStateChanged.listen((state) {
    print('🔄 [Engine State] -> ${state.name}');
  });

  engine.onEvent.listen((event) {
    print('🔔 [Event] $event');
  });

  // 4. Simulate device going offline
  print('\n📴 Device goes OFFLINE...');
  connectivityController.add(false);
  await Future<void>.delayed(const Duration(milliseconds: 50));

  // 5. User performs operations while offline (mutations queue in local outbox)
  print('\n📝 Queuing mutations while offline...');
  await engine.queue(
    endpoint: 'users',
    action: SyncAction.create,
    payload: {'id': 'usr_1', 'name': 'John Doe', 'email': 'john@example.com'},
  );

  await engine.queue(
    endpoint: 'users',
    action: SyncAction.update,
    payload: {'id': 'usr_1', 'status': 'active'},
  );

  final pendingCount = await storage.getPendingCount();
  print('📦 Local Outbox Pending Count: $pendingCount');

  // 6. Device reconnects to network
  print('\n📶 Device goes ONLINE! Auto-flush triggered...');
  connectivityController.add(true);

  // Give the async flush a moment to execute
  await Future<void>.delayed(const Duration(milliseconds: 600));

  final remainingPending = await storage.getPendingCount();
  print('🏁 Outbox Flush complete! Remaining pending mutations: $remainingPending');

  // 7. Cleanup
  await engine.dispose();
  await connectivityController.close();
  print('\n✨ SyncOrbit demo completed.');
}
