import 'dart:async';
import '../adapter/sync_adapter_result.dart';
import '../models/sync_mutation.dart';
import 'conflict_resolution.dart';

/// Strategy interface for deciding how to reconcile differences when
/// the remote server returns a [SyncAdapterConflict].
abstract interface class ConflictResolver {
  /// Resolves a conflict between the [clientMutation] and the [serverConflict].
  ///
  /// Returns a [ConflictResolution] specifying the winning action.
  FutureOr<ConflictResolution> resolve({
    required SyncMutation clientMutation,
    required SyncAdapterConflict serverConflict,
  });
}
