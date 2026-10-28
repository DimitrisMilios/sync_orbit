import '../models/sync_mutation.dart';
import 'sync_adapter_result.dart';

/// Contract for dispatching offline mutations to a remote backend service or API.
///
/// Implement this interface for HTTP/REST, GraphQL, gRPC, Firebase, or Supabase.
abstract interface class SyncAdapter {
  /// Sends the given [mutation] to the remote backend.
  ///
  /// Returns a [SyncAdapterResult] indicating either:
  /// - [SyncAdapterSuccess]: mutation was successfully accepted.
  /// - [SyncAdapterConflict]: remote state conflicts with client mutation.
  /// - [SyncAdapterFailure]: network or server error occurred.
  Future<SyncAdapterResult> send(SyncMutation mutation);
}
