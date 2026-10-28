import 'dart:math';

/// Utility class for generating RFC-4122 compliant version 4 UUIDs.
class UuidGenerator {
  static final Random _random = Random.secure();

  /// Generates a random version 4 UUID string (e.g. `123e4567-e89b-12d3-a456-426614174000`).
  static String v4([Random? random]) {
    final r = random ?? _random;
    final bytes = List<int>.generate(16, (_) => r.nextInt(256));

    // Set version to 4 -> 0100xxxx
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    // Set variant to RFC 4122 -> 10xxxxxx
    bytes[8] = (bytes[8] & 0x3f) | 0x80;

    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).toList();

    return '${hex[0]}${hex[1]}${hex[2]}${hex[3]}-'
        '${hex[4]}${hex[5]}-'
        '${hex[6]}${hex[7]}-'
        '${hex[8]}${hex[9]}-'
        '${hex[10]}${hex[11]}${hex[12]}${hex[13]}${hex[14]}${hex[15]}';
  }
}
