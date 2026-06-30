/// Tracks the document paths each active subscription currently references, so
/// the [EvictionManager] never evicts a document a live listener depends on.
/// Each owner (a listener instance) registers its current member paths and
/// replaces them as its membership changes; it unregisters when cancelled.
class ActiveTargets {
  final Map<Object, Set<String>> _byOwner = {};

  /// Sets [owner]'s current referenced paths (replacing any previous set).
  void pin(Object owner, Iterable<String> paths) {
    _byOwner[owner] = paths.toSet();
  }

  /// Removes [owner] and its referenced paths.
  void unpin(Object owner) => _byOwner.remove(owner);

  /// The union of all referenced paths across active owners.
  Set<String> all() => {for (final paths in _byOwner.values) ...paths};
}
