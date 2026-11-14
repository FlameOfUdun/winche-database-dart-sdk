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

  /// What expanded file and user references stand for, by `kind:value`.
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
  /// A reference field (to a document, a file or a user) is a [Link]: its
  /// `data()` is what `expand` brought, when it did.
  Map<String, Object?>? nativeData() {
    if (!exists || rawData == null) return null;
    final paths = _expand ?? const <ExpandPath>[];
    return {for (final e in rawData!.entries) e.key: _native(e.value, _below(paths, e.key))};
  }

  /// This snapshot with its data read through [converter], without reading the
  /// document again (its [reference] takes the converter too).
  DocumentSnapshot<R> withConverter<R>(Converter<R> converter) => DocumentSnapshot<R>._(
        reference: reference.withConverter(converter),
        exists: exists,
        rawData: rawData,
        createTime: createTime,
        updateTime: updateTime,
        updateTimeRaw: updateTimeRaw,
        version: version,
        metadata: metadata,
        included: _included,
        expand: _expand,
        resolved: _resolved,
      );

  /// The field at [fieldPath] (dotted, e.g. `address.city`) as [R], or null when
  /// it's absent or not an [R].
  R? get<R>(String fieldPath) {
    Object? value = nativeData();
    for (final segment in fieldPath.split('.')) {
      if (value is! Map<String, Object?>) return null;
      value = value[segment];
    }
    return value is R ? value : null;
  }

  /// The paths that go on under field [key].
  static List<ExpandPath> _below(List<ExpandPath> paths, String key) => [
        for (final p in paths)
          if (p.segments.isNotEmpty && p.segments.first == key) (segments: p.segments.sublist(1))
      ];

  /// [value] as native data, with references as [Link]s; [paths] is what's left of each expand path here.
  Object? _native(Value value, List<ExpandPath> paths) => switch (value) {
        ReferenceValue(:final path) => _documentLink(path, paths),
        FileRefValue(:final path) => _resolvedLink(LinkKind.file, path, paths),
        UserRefValue(:final uid) => _resolvedLink(LinkKind.user, uid, paths),
        ArrayValue(:final elements) => [for (final e in elements) _native(e, paths)],
        MapValue(:final fields) => {for (final e in fields.entries) e.key: _native(e.value, _below(paths, e.key))},
        _ => fromValue(value),
      };

  Link<Map<String, Object?>> _documentLink(String path, List<ExpandPath> paths) {
    final target = path.startsWith('/') ? path.substring(1) : path;
    final wire = _included?[target];
    final doc = wire == null
        ? null
        : DocumentSnapshot<Map<String, Object?>>._fromWire(reference._db.doc(target), wire,
            metadata: metadata, included: _included, resolved: _resolved,
            expand: [for (final p in paths) if (p.segments.isNotEmpty) p]);
    return Link<Map<String, Object?>>._(LinkKind.document, target, doc, null, Converter._identity);
  }

  /// A file or user [Link], with what the server resolved when an expand path ends here.
  Link<Map<String, Object?>> _resolvedLink(LinkKind kind, String target, List<ExpandPath> paths) {
    final expanded = paths.any((p) => p.segments.isEmpty);
    return Link<Map<String, Object?>>._(
        kind, target, null, expanded ? (_resolved?['${kind.name}:$target']) : null, Converter._identity);
  }

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

/// What a [Link] points at.
enum LinkKind {
  /// Another document (`docRefValue`).
  document,

  /// A file in Winche Storage (`fileRefValue`).
  file,

  /// A Winche Auth user (`userRefValue`).
  user,
}

/// A reference field: to a document, a file in Winche Storage, or a Winche
/// Auth user. Store one with [Link.document], [Link.file] or [Link.user].
///
/// [target] is always there: the document path, file path or uid. [data] is
/// what `expand` brought (the referenced document's fields, the file's record,
/// the user's public profile), and null when it didn't (not expanded, missing,
/// hidden from this user, or not cached offline).
///
/// Read-only: writing a [Link] stores the reference, never its data.
final class Link<T> {
  Link._(this.kind, this.target, this._doc, this._json, this._converter);

  /// A reference to the document at [path], to write.
  static Link<Map<String, Object?>> document(String path) =>
      Link._(LinkKind.document, path.startsWith('/') ? path.substring(1) : path, null, null, Converter._identity);

  /// A reference to the file at [path] in Winche Storage, to write.
  static Link<Map<String, Object?>> file(String path) =>
      Link._(LinkKind.file, path.startsWith('/') ? path.substring(1) : path, null, null, Converter._identity);

  /// A reference to the Winche Auth user [uid], to write.
  static Link<Map<String, Object?>> user(String uid) => Link._(LinkKind.user, uid, null, null, Converter._identity);

  /// What it points at.
  final LinkKind kind;

  /// The document path, file path or uid.
  final String target;

  final DocumentSnapshot<Map<String, Object?>>? _doc;
  final Map<String, Object?>? _json;
  final Converter<T> _converter;

  /// What `expand` brought, as `T` (a map until [withConverter]); null when it didn't.
  T? data() {
    final map = kind == LinkKind.document ? _doc?.nativeData() : _json;
    return map == null ? null : _converter.fromMap(Map<String, Object?>.of(map));
  }

  /// This link with its data read through [converter].
  Link<R> withConverter<R>(Converter<R> converter) => Link<R>._(kind, target, _doc, _json, converter);

  @override
  bool operator ==(Object other) => other is Link && other.kind == kind && other.target == target;

  @override
  int get hashCode => Object.hash(kind, target);

  @override
  String toString() => 'Link(${kind.name}:$target${_doc == null && _json == null ? '' : ', with data'})';
}
