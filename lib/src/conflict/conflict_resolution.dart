import 'package:meta/meta.dart';

/// The outcome returned by a [ConflictResolver] when determining how to resolve
/// a collision between a local [SyncMutation] and remote server state.
@immutable
sealed class ConflictResolution {
  const ConflictResolution();

  /// Server state takes precedence. Local mutation is marked completed or discarded.
  const factory ConflictResolution.serverWins() = ServerWinsResolution;

  /// Client state takes precedence. Local mutation will be reapplied to overwrite server state.
  const factory ConflictResolution.clientWins() = ClientWinsResolution;

  /// Merge client and server state together with the provided [mergedPayload].
  const factory ConflictResolution.merge(Map<String, dynamic> mergedPayload) =
      MergeResolution;

  /// Discard the mutation entirely (dead-letter).
  const factory ConflictResolution.discard({String? reason}) = DiscardResolution;
}

/// Resolution where the remote server's version is authoritative.
class ServerWinsResolution extends ConflictResolution {
  const ServerWinsResolution();

  @override
  String toString() => 'ConflictResolution.serverWins';
}

/// Resolution where the client's mutation is authoritative and forces an overwrite.
class ClientWinsResolution extends ConflictResolution {
  const ClientWinsResolution();

  @override
  String toString() => 'ConflictResolution.clientWins';
}

/// Resolution where client and server payloads are merged into a unified payload.
class MergeResolution extends ConflictResolution {
  /// The combined payload to be sent to the remote source.
  final Map<String, dynamic> mergedPayload;

  const MergeResolution(this.mergedPayload);

  @override
  String toString() => 'ConflictResolution.merge(payload: $mergedPayload)';
}

/// Resolution indicating the mutation should be dropped without being applied.
class DiscardResolution extends ConflictResolution {
  /// Optional reason explaining why this mutation was discarded.
  final String? reason;

  const DiscardResolution({this.reason});

  @override
  String toString() => 'ConflictResolution.discard(reason: $reason)';
}
