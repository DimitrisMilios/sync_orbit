# Production Readiness Checklist

Deploying offline-first synchronization in mission-critical applications requires addressing edge cases around network failure, duplicate processing, battery constraints, and background scheduling.

---

## 1. Idempotency Keys

In unreliable networks, timeouts frequently occur *after* the server has already executed the request but *before* the client receives the response. Retrying without idempotency tokens creates duplicate rows.

### Recommended Pattern
Every `SyncMutation` generates a unique RFC-4122 v4 UUID (`mutation.id`). Transmit this ID as the `Idempotency-Key` HTTP header:

```dart
final restAdapter = RestSyncAdapter(
  baseUrl: 'https://api.myapp.com/v1',
  headersProvider: () => {
    'Idempotency-Key': currentMutationId,
  },
  urlResolver: (mutation, baseUri) {
    // You can also pass the idempotency key in headers or payload
    return Uri.parse('$baseUri/${mutation.endpoint}');
  },
);
```

On your backend, store processed `Idempotency-Key`s in Redis or PostgreSQL for 24 hours. If a request with an identical key arrives, return the cached response immediately rather than executing a second write.

---

## 2. Exponential Backoff & Jitter

When a server experiences an outage or rate-limiting spike, naive retries compound the failure through the **Thundering Herd** problem.

```dart
const policy = RetryPolicy(
  initialDelay: Duration(seconds: 1), // Delay before retry #1
  backoffFactor: 2.0,                 // 1s -> 2s -> 4s -> 8s -> 16s...
  maxDelay: Duration(minutes: 5),     // Cap backoff at 5 minutes
  maxRetries: 5,                      // Dead-letter queue after 5 failures
  useJitter: true,                    // Full jitter spread: random(0, calculatedDelay)
);
```

Enabling `useJitter: true` spreads retry attempts evenly across time, smoothing server request spikes.

---

## 3. Background Sync with `workmanager`

When users close or background the app, sync should continue periodically when the device is connected to unmetered network power.

```dart
import 'package:workmanager/workmanager.dart';
import 'package:sync_orbit/sync_orbit.dart';

@pragma('vm:entry-point')
void callbackDispatcher() {
  Workmanager().executeTask((taskName, inputData) async {
    // 1. Initialize DB & dependencies
    final storage = SqfliteSyncStorage(await openDb());
    await storage.initialize();

    final engine = SyncEngine(
      storage: storage,
      adapter: RestSyncAdapter(baseUrl: 'https://api.myapp.com'),
      options: const SyncEngineOptions(deleteOnSuccess: true),
    );

    // 2. Perform one flush pass
    final result = await engine.flush();
    await engine.dispose();

    return result.isCompleted;
  });
}

// In your main Flutter app startup:
void configureBackgroundSync() {
  Workmanager().initialize(callbackDispatcher);
  Workmanager().registerPeriodicTask(
    'sync_orbit_periodic',
    'syncOutbox',
    frequency: const Duration(minutes: 15),
    constraints: Constraints(
      networkType: NetworkType.connected,
      requiresBatteryNotLow: true,
    ),
  );
}
```

---

## 4. Telemetry & Dead-Letter Alerts

Monitor queue health by listening to `SyncEngine.onEvent`:

```dart
syncEngine.onEvent.listen((event) {
  switch (event) {
    case MutationFailedEvent(:final mutation, :final failure, :final willRetry):
      if (!willRetry) {
        // Dead-letter reached! Report to Sentry / Datadog
        Sentry.captureMessage(
          'SyncMutation Dead-Lettered: ${mutation.endpoint} - ${failure.error}',
          level: SentryLevel.error,
          params: [mutation.toMap()],
        );
      }

    case SyncFlushCompletedEvent(:final result):
      // Emit metrics to Datadog or Prometheus
      metrics.recordCount('sync.mutations.succeeded', result.successCount);
      metrics.recordCount('sync.mutations.failed', result.failureCount);
      metrics.recordCount('sync.conflicts.resolved', result.conflictCount);

    default:
      break;
  }
});
```

---

## 5. App Lifecycle & Data Saver Awareness

When users enable "Data Saver" or enter low-power mode, pause the engine to conserve battery and cellular data:

```dart
class AppLifecycleObserver with WidgetsBindingObserver {
  final SyncEngine engine;
  AppLifecycleObserver(this.engine);

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      engine.resume();
    } else if (state == AppLifecycleState.paused) {
      // Pause active background polling if unneeded
    }
  }
}
```
