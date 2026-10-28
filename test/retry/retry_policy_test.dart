import 'package:flutter_test/flutter_test.dart';
import 'package:sync_orbit/sync_orbit.dart';

void main() {
  group('RetryPolicy', () {
    test('calculates exponential backoff delay correctly', () {
      const policy = RetryPolicy(
        initialDelay: Duration(seconds: 1),
        backoffFactor: 2.0,
        maxDelay: Duration(seconds: 30),
        maxRetries: 4,
      );

      expect(policy.calculateDelay(0), Duration.zero);
      expect(policy.calculateDelay(1), const Duration(seconds: 1)); // 1 * 2^0
      expect(policy.calculateDelay(2), const Duration(seconds: 2)); // 1 * 2^1
      expect(policy.calculateDelay(3), const Duration(seconds: 4)); // 1 * 2^2
      expect(policy.calculateDelay(4), const Duration(seconds: 8)); // 1 * 2^3
      expect(policy.calculateDelay(5), const Duration(seconds: 16)); // 1 * 2^4
      expect(policy.calculateDelay(6), const Duration(seconds: 30)); // Capped at maxDelay
    });

    test('shouldRetry enforces maxRetries and isRecoverable', () {
      const policy = RetryPolicy(maxRetries: 3);

      final m0 = SyncMutation(endpoint: 'e', action: SyncAction.create, payload: {}, retryCount: 0);
      final m2 = SyncMutation(endpoint: 'e', action: SyncAction.create, payload: {}, retryCount: 2);
      final m3 = SyncMutation(endpoint: 'e', action: SyncAction.create, payload: {}, retryCount: 3);

      expect(policy.shouldRetry(m0, isRecoverable: true), isTrue);
      expect(policy.shouldRetry(m2, isRecoverable: true), isTrue);
      expect(policy.shouldRetry(m3, isRecoverable: true), isFalse); // Max reached
      expect(policy.shouldRetry(m0, isRecoverable: false), isFalse); // Non-recoverable
    });

    test('isReadyForRetry respects elapsed duration', () {
      const policy = RetryPolicy(
        initialDelay: Duration(seconds: 10),
        backoffFactor: 2.0,
      );

      final now = DateTime.utc(2026, 10, 28, 12, 0, 0);

      // retryCount: 1 => delay is 10s
      final m1 = SyncMutation(
        endpoint: 'e',
        action: SyncAction.create,
        payload: {},
        retryCount: 1,
        lastAttemptedAt: now,
      );

      // 5 seconds elapsed -> not ready
      expect(
        policy.isReadyForRetry(m1, now: now.add(const Duration(seconds: 5))),
        isFalse,
      );

      // 10 seconds elapsed -> ready
      expect(
        policy.isReadyForRetry(m1, now: now.add(const Duration(seconds: 10))),
        isTrue,
      );

      // 15 seconds elapsed -> ready
      expect(
        policy.isReadyForRetry(m1, now: now.add(const Duration(seconds: 15))),
        isTrue,
      );
    });
  });
}
