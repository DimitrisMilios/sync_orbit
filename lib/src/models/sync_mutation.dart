import 'package:meta/meta.dart';
import '../utils/map_utils.dart';
import '../utils/uuid_generator.dart';
import 'sync_action.dart';
import 'sync_status.dart';

/// Represents a discrete offline change or mutation in the outbox queue.
///
/// Each mutation encapsulates the target [endpoint] (e.g. database table or API route),
/// the [action] to perform (create, update, delete), the data [payload], and metadata
/// for ordering (FIFO via [createdAt]) and retry policies.
@immutable
class SyncMutation {
  /// Unique identifier for this mutation.
  final String id;

  /// The target resource identifier, table name, or API endpoint.
  final String endpoint;

  /// The operation type: create, update, or delete.
  final SyncAction action;

  /// The mutation payload data.
  final Map<String, dynamic> payload;

  /// The timestamp when this mutation was originally recorded locally.
  final DateTime createdAt;

  /// Number of sync attempts performed so far for this mutation.
  final int retryCount;

  /// Current processing status in the outbox queue.
  final SyncStatus status;

  /// The timestamp of the most recent sync attempt, if any.
  final DateTime? lastAttemptedAt;

  /// The error message from the most recent failed sync attempt, if any.
  final String? lastError;

  /// Optional contextual metadata (e.g., client user ID, tenant ID, device info).
  final Map<String, dynamic>? metadata;

  /// Creates a [SyncMutation].
  ///
  /// If [id] is omitted, a random RFC-4122 v4 UUID is generated.
  /// If [createdAt] is omitted, the current UTC time is used.
  SyncMutation({
    String? id,
    required this.endpoint,
    required this.action,
    required this.payload,
    DateTime? createdAt,
    this.retryCount = 0,
    this.status = SyncStatus.pending,
    this.lastAttemptedAt,
    this.lastError,
    this.metadata,
  })  : id = id ?? UuidGenerator.v4(),
        createdAt = (createdAt ?? DateTime.now()).toUtc();

  /// Creates a copy of this [SyncMutation] with updated properties.
  SyncMutation copyWith({
    String? id,
    String? endpoint,
    SyncAction? action,
    Map<String, dynamic>? payload,
    DateTime? createdAt,
    int? retryCount,
    SyncStatus? status,
    DateTime? lastAttemptedAt,
    String? lastError,
    Map<String, dynamic>? metadata,
  }) {
    return SyncMutation(
      id: id ?? this.id,
      endpoint: endpoint ?? this.endpoint,
      action: action ?? this.action,
      payload: payload ?? this.payload,
      createdAt: createdAt ?? this.createdAt,
      retryCount: retryCount ?? this.retryCount,
      status: status ?? this.status,
      lastAttemptedAt: lastAttemptedAt ?? this.lastAttemptedAt,
      lastError: lastError ?? this.lastError,
      metadata: metadata ?? this.metadata,
    );
  }

  /// Converts this [SyncMutation] to a map suitable for serialization
  /// (e.g., JSON encoding or SQLite row insertion).
  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'endpoint': endpoint,
      'action': action.name,
      'payload': payload,
      'createdAt': createdAt.toIso8601String(),
      'retryCount': retryCount,
      'status': status.name,
      if (lastAttemptedAt != null)
        'lastAttemptedAt': lastAttemptedAt!.toIso8601String(),
      if (lastError != null) 'lastError': lastError,
      if (metadata != null) 'metadata': metadata,
    };
  }

  /// Converts this mutation to a JSON-compatible map.
  Map<String, dynamic> toJson() => toMap();

  /// Deserializes a [SyncMutation] from a map.
  factory SyncMutation.fromMap(Map<String, dynamic> map) {
    return SyncMutation(
      id: map['id'] as String,
      endpoint: map['endpoint'] as String,
      action: SyncAction.fromString(map['action'] as String),
      payload: Map<String, dynamic>.from(map['payload'] as Map),
      createdAt: DateTime.parse(map['createdAt'] as String).toUtc(),
      retryCount: (map['retryCount'] as num?)?.toInt() ?? 0,
      status: map['status'] != null
          ? SyncStatus.fromString(map['status'] as String)
          : SyncStatus.pending,
      lastAttemptedAt: map['lastAttemptedAt'] != null
          ? DateTime.parse(map['lastAttemptedAt'] as String).toUtc()
          : null,
      lastError: map['lastError'] as String?,
      metadata: map['metadata'] != null
          ? Map<String, dynamic>.from(map['metadata'] as Map)
          : null,
    );
  }

  /// Deserializes a [SyncMutation] from a JSON-compatible map.
  factory SyncMutation.fromJson(Map<String, dynamic> json) =>
      SyncMutation.fromMap(json);

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;

    return other is SyncMutation &&
        other.id == id &&
        other.endpoint == endpoint &&
        other.action == action &&
        mapEquals(other.payload, payload) &&
        other.createdAt.isAtSameMomentAs(createdAt) &&
        other.retryCount == retryCount &&
        other.status == status &&
        other.lastError == lastError &&
        mapEquals(other.metadata, metadata);
  }

  @override
  int get hashCode {
    return Object.hash(
      id,
      endpoint,
      action,
      createdAt.millisecondsSinceEpoch,
      retryCount,
      status,
      lastError,
    );
  }

  @override
  String toString() {
    return 'SyncMutation(id: $id, endpoint: $endpoint, action: ${action.name}, '
        'retryCount: $retryCount, status: ${status.name}, createdAt: ${createdAt.toIso8601String()})';
  }
}
