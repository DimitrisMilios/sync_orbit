/// Represents the database or API operation performed by a mutation.
enum SyncAction {
  /// Create a new resource or row.
  create,

  /// Update an existing resource or row.
  update,

  /// Delete an existing resource or row.
  delete;

  /// Parses a string representation into a [SyncAction].
  ///
  /// Throws an [ArgumentError] if [name] does not match any action.
  static SyncAction fromString(String name) {
    return SyncAction.values.firstWhere(
      (action) => action.name.toLowerCase() == name.trim().toLowerCase(),
      orElse: () => throw ArgumentError('Unknown SyncAction value: "$name"'),
    );
  }

  /// Parses a string representation into a [SyncAction], returning null if invalid.
  static SyncAction? tryFromString(String? name) {
    if (name == null) return null;
    try {
      return fromString(name);
    } catch (_) {
      return null;
    }
  }
}
