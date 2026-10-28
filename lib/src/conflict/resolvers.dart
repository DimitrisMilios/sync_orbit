import 'dart:async';
import '../adapter/sync_adapter_result.dart';
import '../models/sync_mutation.dart';
import 'conflict_resolution.dart';
import 'conflict_resolver.dart';

/// Conflict resolver that always prefers the server's state.
///
/// Any client mutation that conflicts with the server is abandoned.
class ServerWinsResolver implements ConflictResolver {
  const ServerWinsResolver();

  @override
  ConflictResolution resolve({
    required SyncMutation clientMutation,
    required SyncAdapterConflict serverConflict,
  }) {
    return const ConflictResolution.serverWins();
  }
}

/// Conflict resolver that always prefers the client's state.
///
/// Forces the client mutation to overwrite conflicting server changes.
class ClientWinsResolver implements ConflictResolver {
  const ClientWinsResolver();

  @override
  ConflictResolution resolve({
    required SyncMutation clientMutation,
    required SyncAdapterConflict serverConflict,
  }) {
    return const ConflictResolution.clientWins();
  }
}

/// Signature for extracting a [DateTime] timestamp from a payload map.
typedef TimestampExtractor = DateTime? Function(Map<String, dynamic> payload);

/// Conflict resolver that compares timestamps to determine the winning write.
///
/// If the client write occurred at the same time or after the server write,
/// the client wins. Otherwise, the server wins.
class LastWriteWinsResolver implements ConflictResolver {
  /// Optional custom extractor for retrieving the client's timestamp from its payload.
  /// If omitted or returns null, [SyncMutation.createdAt] is used.
  final TimestampExtractor? clientTimestampExtractor;

  /// Optional custom extractor for retrieving the server's timestamp from [serverConflict.serverPayload].
  /// If omitted or returns null, [SyncAdapterConflict.serverTimestamp] is used.
  final TimestampExtractor? serverTimestampExtractor;

  const LastWriteWinsResolver({
    this.clientTimestampExtractor,
    this.serverTimestampExtractor,
  });

  @override
  ConflictResolution resolve({
    required SyncMutation clientMutation,
    required SyncAdapterConflict serverConflict,
  }) {
    final clientTime = clientTimestampExtractor?.call(clientMutation.payload) ??
        clientMutation.createdAt;

    DateTime? serverTime = serverConflict.serverTimestamp;
    if (serverTime == null && serverTimestampExtractor != null) {
      serverTime = serverTimestampExtractor!(serverConflict.serverPayload);
    }
    // Also check standard payload keys if serverTime is still null
    if (serverTime == null) {
      final possibleKeys = ['updated_at', 'updatedAt', 'timestamp', 'modified_at'];
      for (final key in possibleKeys) {
        final val = serverConflict.serverPayload[key];
        if (val is String) {
          final parsed = DateTime.tryParse(val);
          if (parsed != null) {
            serverTime = parsed.toUtc();
            break;
          }
        } else if (val is int) {
          // Assume millis
          serverTime = DateTime.fromMillisecondsSinceEpoch(val, isUtc: true);
          break;
        }
      }
    }

    // If server timestamp cannot be determined, default to client wins
    if (serverTime == null) {
      return const ConflictResolution.clientWins();
    }

    if (clientTime.isAfter(serverTime) || clientTime.isAtSameMomentAs(serverTime)) {
      return const ConflictResolution.clientWins();
    } else {
      return const ConflictResolution.serverWins();
    }
  }
}

/// Conflict resolver that delegates resolution to a custom callback function.
class CustomConflictResolver implements ConflictResolver {
  final FutureOr<ConflictResolution> Function({
    required SyncMutation clientMutation,
    required SyncAdapterConflict serverConflict,
  }) _resolver;

  const CustomConflictResolver(this._resolver);

  @override
  FutureOr<ConflictResolution> resolve({
    required SyncMutation clientMutation,
    required SyncAdapterConflict serverConflict,
  }) {
    return _resolver(
      clientMutation: clientMutation,
      serverConflict: serverConflict,
    );
  }
}
