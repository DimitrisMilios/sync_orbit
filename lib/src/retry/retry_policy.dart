import 'dart:math';
import '../models/sync_mutation.dart';

/// Configuration and calculation strategy for exponential backoff and retry attempts.
class RetryPolicy {
  /// Base delay before the first retry attempt.
  final Duration initialDelay;

  /// Multiplier applied to the delay on each subsequent retry attempt.
  final double backoffFactor;

  /// Upper bound ceiling for the calculated delay.
  final Duration maxDelay;

  /// Maximum allowed retry attempts before a mutation is considered permanently failed.
  final int maxRetries;

  /// Whether to add random jitter to mitigate stampeding herd problems.
  final bool useJitter;

  /// Creates a [RetryPolicy].
  const RetryPolicy({
    this.initialDelay = const Duration(seconds: 1),
    this.backoffFactor = 2.0,
    this.maxDelay = const Duration(minutes: 5),
    this.maxRetries = 5,
    this.useJitter = false,
  })  : assert(backoffFactor >= 1.0, 'backoffFactor must be >= 1.0'),
        assert(maxRetries >= 0, 'maxRetries must be >= 0');

  /// Calculates the backoff duration for the specified [retryCount].
  ///
  /// For [retryCount] <= 0, returns [Duration.zero].
  /// For [retryCount] > 0, calculates:
  /// `min(initialDelay * (backoffFactor ^ (retryCount - 1)), maxDelay)`.
  ///
  /// If [useJitter] is true, applies full-jitter randomized spread in `[0, calculatedDelay]`.
  Duration calculateDelay(int retryCount, [Random? random]) {
    if (retryCount <= 0) return Duration.zero;

    final exponentialMultiplier = pow(backoffFactor, retryCount - 1).toDouble();
    final calculatedMillis =
        (initialDelay.inMilliseconds * exponentialMultiplier).round();

    final cappedMillis = min(calculatedMillis, maxDelay.inMilliseconds);

    if (useJitter) {
      final r = random ?? Random();
      final jitteredMillis = (r.nextDouble() * cappedMillis).round();
      return Duration(milliseconds: jitteredMillis);
    }

    return Duration(milliseconds: cappedMillis);
  }

  /// Determines whether the [mutation] can be retried.
  bool shouldRetry(SyncMutation mutation, {bool isRecoverable = true}) {
    if (!isRecoverable) return false;
    return mutation.retryCount < maxRetries;
  }

  /// Determines whether sufficient backoff time has elapsed since the mutation's
  /// [SyncMutation.lastAttemptedAt] to attempt a retry.
  bool isReadyForRetry(SyncMutation mutation, {DateTime? now}) {
    if (mutation.retryCount == 0 || mutation.lastAttemptedAt == null) {
      return true;
    }

    final currentTime = (now ?? DateTime.now()).toUtc();
    final delay = calculateDelay(mutation.retryCount);
    final earliestRetryTime = mutation.lastAttemptedAt!.add(delay);

    return currentTime.isAfter(earliestRetryTime) ||
        currentTime.isAtSameMomentAs(earliestRetryTime);
  }
}
