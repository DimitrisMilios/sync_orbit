/// Represents the lifecycle state of a mutation within the outbox queue.
enum SyncStatus {
  /// The mutation is queued locally and waiting to be synchronized.
  pending,

  /// The mutation is currently being sent to the remote adapter.
  inFlight,

  /// The mutation encountered an error during its last sync attempt.
  failed,

  /// The mutation was successfully synchronized or superseded remotely.
  completed;

  /// Parses a string representation into a [SyncStatus].
  static SyncStatus fromString(String name) {
    return SyncStatus.values.firstWhere(
      (status) => status.name.toLowerCase() == name.trim().toLowerCase(),
      orElse: () => throw ArgumentError('Unknown SyncStatus value: "$name"'),
    );
  }

  /// Parses a string representation into a [SyncStatus], returning null if invalid.
  static SyncStatus? tryFromString(String? name) {
    if (name == null) return null;
    try {
      return fromString(name);
    } catch (_) {
      return null;
    }
  }
}
