part of '../../winche_database.dart';

/// Provenance flags for a snapshot.
///
/// When both flags are false, the snapshot reflects a server-confirmed read
/// with no un-acknowledged local writes. [fromCache] marks data served from the
/// local cache; [hasPendingWrites] marks data that includes local writes not yet
/// confirmed by the server.
final class SnapshotMetadata {
  const SnapshotMetadata({
    this.fromCache = false,
    this.hasPendingWrites = false,
  });

  /// True when the snapshot was served from the local cache rather than a
  /// server-confirmed read.
  final bool fromCache;

  /// True when the snapshot reflects local writes not yet acknowledged by the
  /// server.
  final bool hasPendingWrites;

  @override
  bool operator ==(Object other) =>
      other is SnapshotMetadata &&
      other.fromCache == fromCache &&
      other.hasPendingWrites == hasPendingWrites;

  @override
  int get hashCode => Object.hash(fromCache, hasPendingWrites);

  @override
  String toString() =>
      'SnapshotMetadata(fromCache: $fromCache, hasPendingWrites: $hasPendingWrites)';
}

/// The result of a single write in a batch or transaction commit.
final class WriteResult {
  const WriteResult({
    required this.updateTime,
    required this.transformResults,
  });

  /// The commit timestamp for this write.
  final DateTime updateTime;

  /// Native-converted transform results, keyed by field path.
  /// Null when the write had no transforms.
  final Map<String, Object?>? transformResults;

  /// Parses a single write result from wire JSON.
  static WriteResult fromJson(
    Map<String, Object?> json,
    Object? Function(String) refFromPath,
  ) {
    final transformResultsRaw =
        json['transformResults'] as Map<String, Object?>?;
    final transformResults = transformResultsRaw == null
        ? null
        : {
            for (final entry in transformResultsRaw.entries)
              entry.key: fromValue(Value.fromJson(entry.value)),
          };
    return WriteResult(
      updateTime: DateTime.parse(json['updateTime'] as String).toUtc(),
      transformResults: transformResults,
    );
  }
}

/// Typed converter pair attached by `withConverter`.
class Converter<T> {
  final T Function(Map<String, Object?> data) fromMap;
  final Map<String, Object?> Function(T value) toMap;

  const Converter(this.fromMap, this.toMap);

  /// An identity converter for `Map<String, Object?>`
  static final _identity = Converter<Map<String, Object?>>(
    (data) => data,
    (value) => value,
  );
}

/// An immutable snapshot of a single document.
///
/// [exists] is false when the document is not present.
/// [data()] returns the document data as `T`, or null when [exists] is false.
/// Without a converter (`withConverter`), `T` is `Map<String, Object?>`.
final class DocumentSnapshot<T> {
  DocumentSnapshot._({
    required this.reference,
    required this.exists,
    required this.rawData,
    required this.createTime,
    required this.updateTime,
    required this.updateTimeRaw,
    required this.version,
    this.metadata = const SnapshotMetadata(),
    Map<String, WireDocument>? included,
    List<ExpandPath>? expand,
    Map<String, Map<String, Object?>>? resolved,
  })  : _included = included,
        _expand = expand,
        _resolved = resolved;

  /// What kinded expand paths (`file:`, `user:`) stand for, by `kind:value`.
  final Map<String, Map<String, Object?>>? _resolved;

  /// Referenced documents that came with this read (`expand`), by path.
  final Map<String, WireDocument>? _included;

  /// The reference paths still to follow from this document, split into fields.
  final List<ExpandPath>? _expand;

  /// The [DocumentReference] for this document.
  final DocumentReference<T> reference;

  /// Whether the document currently exists in the database.
  final bool exists;

  /// The raw typed fields from the wire format, or null when [exists] is false.
  final Map<String, Value>? rawData;

  /// The time the document was created (null when [exists] is false).
  final DateTime? createTime;

  /// The time the document was last updated (null when [exists] is false).
  final DateTime? updateTime;

  /// Raw server-format updateTime string, used for [Precondition.updateTimeRaw].
  final String? updateTimeRaw;

  /// The document version (null when [exists] is false).
  final int? version;

  /// Provenance flags indicating whether this snapshot came from cache
  /// and whether it contains pending local writes.
  final SnapshotMetadata metadata;

  /// The document ID (last path segment).
  String get id => reference.id;

  /// The full document path.
  String get path => reference.path;

  /// Returns the document data as `T`, or null when [exists] is false.
  T? data() {
    final native = nativeData();
    if (native == null) return null;
    return reference._converter.fromMap(native);
  }

  /// Returns the document data as a native map regardless of `T`,
  /// or null when [exists] is false.
  ///
  /// A reference is its document's path, unless it was expanded (`expand`) and
  /// its document came with the read: then it's that document's
  /// [DocumentSnapshot] (whose own data has the rest of the path expanded).
  Map<String, Object?>? nativeData() {
    if (!exists || rawData == null) return null;
    final expand = _expand;
    if (expand == null || expand.isEmpty || (_included == null && _resolved == null)) {
      return {
        for (final entry in rawData!.entries) entry.key: fromValue(entry.value),
      };
    }
    return {
      for (final entry in rawData!.entries)
        entry.key: _native(entry.value, _below(expand, entry.key)),
    };
  }

  /// The paths that go on under field [key].
  static List<ExpandPath> _below(List<ExpandPath> paths, String key) => [
        for (final p in paths)
          if (p.segments.isNotEmpty && p.segments.first == key) (segments: p.segments.sublist(1), kind: p.kind)
      ];

  /// [value] as native data, expanding the references [paths] (what's left of
  /// each expand path at this point) reach.
  Object? _native(Value value, List<ExpandPath> paths) {
    if (paths.isEmpty) return fromValue(value);
    return switch (value) {
      StringValue(:final value) => _resolvedFor(value, paths) ?? value,
      ReferenceValue(:final path) => _expanded(path, paths) ?? path,
      ArrayValue(:final elements) => [for (final e in elements) _native(e, paths)],
      MapValue(:final fields) => {
          for (final entry in fields.entries) entry.key: _native(entry.value, _below(paths, entry.key)),
        },
      _ => fromValue(value),
    };
  }

  /// What a kinded path ending at [value] resolved to (a file's record, a user's profile), or null.
  Map<String, Object?>? _resolvedFor(String value, List<ExpandPath> paths) {
    for (final p in paths) {
      if (p.kind == null || p.segments.isNotEmpty) continue;
      final found = _resolved?['${p.kind}:$value'];
      if (found != null) return Map<String, Object?>.of(found);
    }
    return null;
  }

  DocumentSnapshot<Map<String, Object?>>? _expanded(String path, List<ExpandPath> paths) {
    // Only plain paths end at a reference; kinded ones go on through it.
    final rest = [for (final p in paths) if (p.kind == null || p.segments.isNotEmpty) p];
    if (rest.isEmpty) return null;
    final target = path.startsWith('/') ? path.substring(1) : path;
    final wire = _included?[target];
    if (wire == null) return null;   // missing or not readable: stays a pointer
    return DocumentSnapshot<Map<String, Object?>>._fromWire(reference._db.doc(target), wire,
        metadata: metadata, included: _included, resolved: _resolved, expand: [for (final p in rest) if (p.segments.isNotEmpty) p]);
  }

  /// What kinded expand paths (`file:scan`, `user:author`) resolved to, by `kind:value`: a file's record, a user's
  /// public profile. Empty without them.
  Map<String, Map<String, Object?>> get resolved => Map.unmodifiable(_resolved ?? const <String, Map<String, Object?>>{});

  /// The referenced documents that came with this read (`expand`), by path:
  /// those the caller may read. Empty without `expand`.
  Map<String, DocumentSnapshot<Map<String, Object?>>> get included => {
        for (final e in (_included ?? const <String, WireDocument>{}).entries)
          e.key: DocumentSnapshot<Map<String, Object?>>._fromWire(reference._db.doc(e.key), e.value,
              metadata: metadata, included: _included, resolved: _resolved),
      };

  /// Creates a [DocumentSnapshot] from a [WireDocument].
  factory DocumentSnapshot._fromWire(
    DocumentReference<T> reference,
    WireDocument wire, {
    SnapshotMetadata metadata = const SnapshotMetadata(),
    Map<String, WireDocument>? included,
    List<ExpandPath>? expand,
    Map<String, Map<String, Object?>>? resolved,
  }) {
    return DocumentSnapshot._(
      reference: reference,
      exists: true,
      rawData: wire.fields,
      createTime: wire.createdAt,
      updateTime: wire.updatedAt,
      updateTimeRaw: wire.updateTime,
      version: wire.version,
      metadata: metadata,
      included: included,
      expand: expand,
      resolved: resolved,
    );
  }

  /// Creates a non-existent [DocumentSnapshot] for [reference].
  factory DocumentSnapshot._missing(
    DocumentReference<T> reference, {
    SnapshotMetadata metadata = const SnapshotMetadata(),
  }) {
    return DocumentSnapshot._(
      reference: reference,
      exists: false,
      rawData: null,
      createTime: null,
      updateTime: null,
      updateTimeRaw: null,
      version: null,
      metadata: metadata,
    );
  }
}

/// The type of change in a [DocumentChange].
enum DocumentChangeType { added, modified, removed }

/// A single document change within a [QuerySnapshot].
class DocumentChange<T> {
  const DocumentChange({
    required this.type,
    required this.oldIndex,
    required this.newIndex,
    required this.doc,
  });

  final DocumentChangeType type;

  /// The index in the previous snapshot (-1 for [DocumentChangeType.added]).
  final int oldIndex;

  /// The index in the new snapshot (-1 for [DocumentChangeType.removed]).
  final int newIndex;

  final DocumentSnapshot<T> doc;
}

/// An immutable snapshot of a query result set.
class QuerySnapshot<T> {
  const QuerySnapshot({
    required this.docs,
    required this.docChanges,
    required this.readTime,
    required this.resumeToken,
    this.hasMore = false,
    this.metadata = const SnapshotMetadata(),
  });

  /// The documents in the result set, in query order.
  final List<DocumentSnapshot<T>> docs;

  /// Changes from the previous snapshot (or all-added for the first snapshot).
  final List<DocumentChange<T>> docChanges;

  /// The read timestamp for this snapshot.
  final DateTime readTime;

  /// The resume token for resuming this listener (see PROTOCOL §7.6).
  final int? resumeToken;

  /// Whether more results are available beyond those in [docs].
  ///
  /// Only meaningful for [QueryReference.get] responses — set from the `hasMore` field
  /// of the server response. Always `false` for live listener snapshots.
  final bool hasMore;

  /// Provenance flags indicating whether this snapshot came from cache
  /// and whether it contains pending local writes.
  final SnapshotMetadata metadata;
}
