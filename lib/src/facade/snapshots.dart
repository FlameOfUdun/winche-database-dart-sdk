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
  /// or null when [exists] is false. References are their documents' paths and
  /// files and users their paths and uids, expanded or not: what `expand`
  /// brought is read through [link] and [links].
  Map<String, Object?>? nativeData() {
    if (!exists || rawData == null) return null;
    return {
      for (final entry in rawData!.entries) entry.key: fromValue(entry.value),
    };
  }

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

  /// The link at [path]: a reference (`patient`), a file or user (`scan`,
  /// `author`, when expanded as `file:` / `user:`), or one reached through
  /// referenced documents (`patient.doctor`). Null when [path] doesn't lead to
  /// one (or crosses a document that didn't come with the read). For lists, see
  /// [links].
  Link<Map<String, Object?>>? link(String path) {
    final found = _links(path);
    return found.length == 1 && !found.first.$2 ? found.first.$1 : null;
  }

  /// The links at [path] when it holds a list (`team`), one per item that is a
  /// link; a single link gives a list of one.
  Links<Map<String, Object?>> links(String path) => Links._([for (final (l, _) in _links(path)) l]);

  /// The links [path] reaches, each marked when it came from a list.
  List<(Link<Map<String, Object?>>, bool)> _links(String path) {
    final out = <(Link<Map<String, Object?>>, bool)>[];
    final segments = path.split('.');
    void step(Value value, int i, DocumentSnapshot<Map<String, Object?>> owner, List<String> inOwner, bool inList) {
      if (i == segments.length) {
        switch (value) {
          case ReferenceValue(:final path):
            out.add((owner._documentLink(path, inOwner), inList));
          case StringValue(:final value):
            if (owner._kindAt(inOwner) case final kind?) out.add((owner._kindedLink(kind, value), inList));
          case ArrayValue(:final elements):
            for (final e in elements) {
              step(e, i, owner, inOwner, true);
            }
          default:
            break;
        }
        return;
      }
      switch (value) {
        case MapValue(:final fields):
          final child = fields[segments[i]];
          if (child != null) step(child, i + 1, owner, [...inOwner, segments[i]], inList);
        case ArrayValue(:final elements):
          for (final e in elements) {
            step(e, i, owner, inOwner, true);
          }
        case ReferenceValue(:final path):
          final doc = owner._documentLink(path, inOwner).doc;
          if (doc?.rawData != null) step(MapValue(doc!.rawData!), i, doc, const [], inList);
        default:
          break;
      }
    }
    if (rawData != null) step(MapValue(rawData!), 0, _untyped, const [], false);
    return out;
  }

  /// This snapshot as a map-typed one (links are untyped until given a converter).
  DocumentSnapshot<Map<String, Object?>> get _untyped => DocumentSnapshot<Map<String, Object?>>._(
        reference: reference._db.doc(path), exists: exists, rawData: rawData, createTime: createTime,
        updateTime: updateTime, updateTimeRaw: updateTimeRaw, version: version, metadata: metadata,
        included: _included, expand: _expand, resolved: _resolved);

  /// The kind of the expand path that ends at [inOwner] in this document (`file`, `user`), or null.
  String? _kindAt(List<String> inOwner) {
    for (final p in _expand ?? const <ExpandPath>[]) {
      if (p.kind != null && p.segments.length == inOwner.length && _same(p.segments, inOwner)) return p.kind;
    }
    return null;
  }

  static bool _same(List<String> a, List<String> b) {
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  /// The document link for a reference to [target] found at [inOwner]: its document, if it came with the read, with
  /// the expand paths that go on through it.
  Link<Map<String, Object?>> _documentLink(String target, List<String> inOwner) {
    final path = target.startsWith('/') ? target.substring(1) : target;
    final rest = [
      for (final p in _expand ?? const <ExpandPath>[])
        if (p.segments.length > inOwner.length && _same(p.segments.sublist(0, inOwner.length), inOwner))
          (segments: p.segments.sublist(inOwner.length), kind: p.kind)
    ];
    return Link._(reference._db, 'document', path, null, Converter._identity, _included?[path],
        _included, _resolved, rest, metadata);
  }

  Link<Map<String, Object?>> _kindedLink(String kind, String value) =>
      Link._(reference._db, kind, value, _resolved?['$kind:$value'], Converter._identity, null, null, null, null, metadata);

  /// The referenced documents that came with this read (`expand`), by path:
  /// those the caller may read. Empty without `expand`.
  Map<String, DocumentSnapshot<Map<String, Object?>>> get included => {
        for (final e in (_included ?? const <String, WireDocument>{}).entries)
          e.key: DocumentSnapshot<Map<String, Object?>>._fromWire(reference._db.doc(e.key), e.value,
              metadata: metadata, included: _included, resolved: _resolved),
      };

  /// What kinded expand paths (`file:scan`, `user:author`) resolved to, by
  /// `kind:value`. Empty without them.
  Map<String, Map<String, Object?>> get resolved => Map.unmodifiable(_resolved ?? const <String, Map<String, Object?>>{});

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

/// Something a reference reaches that implements a converter: a [DocumentReference], a
/// [CollectionReference] or a [QueryReference]. [Link.like] borrows it.
abstract interface class TypedReference<T> {
  /// How this reference's documents become `T` and back.
  Converter<T> get converter;
}

/// A field the read's `expand` followed (see [DocumentSnapshot.link]). For a
/// reference ([kind] `document`), [doc] is the referenced document when it came
/// with the read and [docRef] reaches it either way; `winche_storage` and
/// `winche_auth` add `file` / `fileRef` and `user` for their kinds.
///
/// Untyped (`Map`) until given a converter, exactly like a [DocumentReference]:
/// [withConverter], or [like] to borrow one a reference already has.
final class Link<T> extends WincheLink {
  Link._(this._db, String kind, String target, Map<String, Object?>? json, this._converter, this._wire,
      this._included, this._resolved, this._expand, this._metadata)
      : super(_db.app, kind, target, json);

  final WincheDatabase _db;
  final Converter<T> _converter;
  final WireDocument? _wire;
  final Map<String, WireDocument>? _included;
  final Map<String, Map<String, Object?>>? _resolved;
  final List<ExpandPath>? _expand;
  final SnapshotMetadata _metadata;

  /// A document link counts as resolved when its document came with the read.
  @override
  bool get isResolved => kind == 'document' ? _wire != null : json != null;

  /// The referenced document, when it came with the read (null for other kinds,
  /// and when it's missing, hidden from this user, or not cached offline). Its own
  /// links go on along the rest of the expand path.
  DocumentSnapshot<T>? get doc {
    final wire = _wire;
    if (kind != 'document' || wire == null) return null;
    return DocumentSnapshot<T>._fromWire(docRef, wire,
        metadata: _metadata, included: _included, resolved: _resolved, expand: _expand);
  }

  /// The referenced document's reference, typed like this link: `get()`, `snapshots()`, `update()`…
  DocumentReference<T> get docRef {
    if (kind != 'document') throw StateError('A $kind link has no document reference; its target is "$target".');
    return DocumentReference<T>._(_db, target, _converter);
  }

  /// This link with [converter] for its document.
  Link<R> withConverter<R>(Converter<R> converter) =>
      Link<R>._(_db, kind, target, json, converter, _wire, _included, _resolved, _expand, _metadata);

  /// This link with the converter [reference] has (e.g. `db.collection('patients').withConverter(…)`).
  Link<R> like<R>(TypedReference<R> reference) => withConverter(reference.converter);
}

/// The links a list field holds (see [DocumentSnapshot.links]).
final class Links<T> extends Iterable<Link<T>> {
  Links._(this._links);

  final List<Link<T>> _links;

  @override
  Iterator<Link<T>> get iterator => _links.iterator;

  /// These links with [converter] for their documents.
  Links<R> withConverter<R>(Converter<R> converter) => Links._([for (final l in _links) l.withConverter(converter)]);

  /// These links with the converter [reference] has.
  Links<R> like<R>(TypedReference<R> reference) => withConverter(reference.converter);
}
