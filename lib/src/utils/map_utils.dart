/// Compares two maps for element-by-element equality.
bool mapEquals<K, V>(Map<K, V>? a, Map<K, V>? b) {
  if (identical(a, b)) return true;
  if (a == null || b == null) return false;
  if (a.length != b.length) return false;
  for (final key in a.keys) {
    if (!b.containsKey(key) || b[key] != a[key]) return false;
  }
  return true;
}
