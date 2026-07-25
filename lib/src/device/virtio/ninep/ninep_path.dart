/// Normalisation helpers for guest-absolute 9P paths.
///
/// A normalised path starts with `/`, uses `/` as the root, has no
/// trailing slash (except the root), and contains no `.` or `..`
/// segments — `..` is resolved, and cannot escape the root.
class NinePPath {
  const NinePPath._();

  static const separator = '/';
  static const root = '/';

  /// Normalises [path] to a guest-absolute canonical form.
  static String normalise(String path) {
    final segments = <String>[];
    for (final raw in path.split(separator)) {
      if (raw.isEmpty || raw == '.') continue;
      if (raw == '..') {
        if (segments.isNotEmpty) segments.removeLast();
        continue;
      }
      segments.add(raw);
    }
    if (segments.isEmpty) return root;
    return separator + segments.join(separator);
  }

  /// Joins normalised [parent] with a single child [name].
  static String join(String parent, String name) {
    final base = normalise(parent);
    return normalise(
      base == root ? '$root$name' : '$base$separator$name',
    );
  }

  /// Returns the parent directory of normalised [path] (root's parent is
  /// itself).
  static String parentOf(String path) {
    final norm = normalise(path);
    if (norm == root) return root;
    final idx = norm.lastIndexOf(separator);
    return idx <= 0 ? root : norm.substring(0, idx);
  }

  /// Returns the final segment of [path] (root's base name is `/`).
  static String baseName(String path) {
    final norm = normalise(path);
    if (norm == root) return root;
    return norm.substring(norm.lastIndexOf(separator) + 1);
  }
}
