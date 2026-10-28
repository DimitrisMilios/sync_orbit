import 'package:meta/meta.dart';

/// Represents the outcome of sending a [SyncMutation] to a remote server.
@immutable
sealed class SyncAdapterResult {
  const SyncAdapterResult();

  /// Creates a successful result.
  const factory SyncAdapterResult.success({
    Map<String, dynamic>? responseData,
    int? statusCode,
  }) = SyncAdapterSuccess;

  /// Creates a conflict result when the remote server reports that the local state
  /// conflicts with the remote record.
  const factory SyncAdapterResult.conflict({
    required Map<String, dynamic> serverPayload,
    DateTime? serverTimestamp,
    String? reason,
    int? statusCode,
  }) = SyncAdapterConflict;

  /// Creates a failure result representing a network, HTTP, or operational error.
  const factory SyncAdapterResult.failure({
    required String error,
    int? statusCode,
    bool isRecoverable,
  }) = SyncAdapterFailure;
}

/// A successful sync response.
class SyncAdapterSuccess extends SyncAdapterResult {
  /// Optional response data returned from the server after mutation.
  final Map<String, dynamic>? responseData;

  /// HTTP status code or remote status code.
  final int? statusCode;

  const SyncAdapterSuccess({
    this.responseData,
    this.statusCode,
  });

  @override
  String toString() =>
      'SyncAdapterSuccess(statusCode: $statusCode, data: $responseData)';
}

/// A conflict detected during sync execution.
class SyncAdapterConflict extends SyncAdapterResult {
  /// The current state/payload present on the remote server.
  final Map<String, dynamic> serverPayload;

  /// The timestamp of the server record (useful for Last-Write-Wins strategies).
  final DateTime? serverTimestamp;

  /// Human-readable explanation of why the conflict occurred.
  final String? reason;

  /// HTTP status code (e.g. 409 Conflict, 412 Precondition Failed).
  final int? statusCode;

  const SyncAdapterConflict({
    required this.serverPayload,
    this.serverTimestamp,
    this.reason,
    this.statusCode = 409,
  });

  @override
  String toString() =>
      'SyncAdapterConflict(reason: $reason, serverTimestamp: $serverTimestamp, statusCode: $statusCode)';
}

/// A failed sync attempt.
class SyncAdapterFailure extends SyncAdapterResult {
  /// Detailed description of the error encountered.
  final String error;

  /// Optional HTTP status code associated with the failure.
  final int? statusCode;

  /// Whether this failure is temporary/transient and should be retried.
  final bool isRecoverable;

  const SyncAdapterFailure({
    required this.error,
    this.statusCode,
    this.isRecoverable = true,
  });

  @override
  String toString() =>
      'SyncAdapterFailure(error: $error, statusCode: $statusCode, recoverable: $isRecoverable)';
}
