import 'exceptions.dart';
import '../core/values.dart';
import 'writes.dart';
import 'query_spec.dart';

// ---------------------------------------------------------------------------
// WireDocument
// ---------------------------------------------------------------------------

/// A document as received from the server wire format (PROTOCOL §2.1).
///
/// **Metadata timestamps** (`createTime`, `updateTime`) are stored as raw
/// strings in the server's format (`+00:00` offset, trailing zeros trimmed)
/// to allow verbatim echo-back via [Precondition.updateTimeRaw].
/// Use [createdAt] / [updatedAt] for parsed [DateTime] values.
class WireDocument {
  const WireDocument({
    required this.path,
    required this.id,
    required this.collection,
    required this.fields,
    required this.createTime,
    required this.updateTime,
    required this.version,
  });

  final String path;
  final String id;
  final String collection;
  final Map<String, Value> fields;

  /// Raw server-format string, e.g. `"2026-06-07T10:05:00+00:00"`.
  final String createTime;

  /// Raw server-format string, e.g. `"2026-06-07T10:05:00+00:00"`.
  final String updateTime;

  final int version;

  /// Lazily-parsed [createTime] as a UTC [DateTime].
  DateTime get createdAt => DateTime.parse(createTime).toUtc();

  /// Lazily-parsed [updateTime] as a UTC [DateTime].
  DateTime get updatedAt => DateTime.parse(updateTime).toUtc();

  /// Parses a document from wire JSON, or returns null when [raw] is null.
  static WireDocument? fromAny(Object? raw) =>
      raw == null ? null : fromJson((raw as Map).cast<String, Object?>());

  /// Parses a document from wire JSON (PROTOCOL §2.1).
  static WireDocument fromJson(Map<String, Object?> json) {
    final fieldsRaw = json['fields'] as Map<String, Object?>? ?? {};
    return WireDocument(
      path: json['path'] as String,
      id: json['id'] as String,
      collection: json['collection'] as String,
      fields: {
        for (final entry in fieldsRaw.entries)
          entry.key: Value.fromJson(entry.value),
      },
      createTime: json['createTime'] as String,
      updateTime: json['updateTime'] as String,
      version: (json['version'] as num).toInt(),
    );
  }

  Map<String, Object?> toJson() => {
        'path': path,
        'id': id,
        'collection': collection,
        'fields': {for (final e in fields.entries) e.key: e.value.toJson()},
        'createTime': createTime,
        'updateTime': updateTime,
        'version': version,
      };
}

// ---------------------------------------------------------------------------
// WireChange — listener delta change
// ---------------------------------------------------------------------------

/// The kind of a change in a listen.delta frame (PROTOCOL §7.6).
enum ChangeKind { added, modified, removed, deleted }

/// A single change in a listen.delta frame (PROTOCOL §7.6).
class WireChange {
  const WireChange({
    required this.kind,
    required this.document,
    required this.oldIndex,
    required this.newIndex,
  });

  final ChangeKind kind;
  final WireDocument document;
  final int oldIndex;
  final int newIndex;

  static WireChange fromJson(Map<String, Object?> json) {
    final kindStr = json['kind'] as String;
    final kind = switch (kindStr) {
      'added' => ChangeKind.added,
      'modified' => ChangeKind.modified,
      'removed' => ChangeKind.removed,
      'deleted' => ChangeKind.deleted,
      _ => throw FormatException('Unknown WireChange kind: "$kindStr"'),
    };
    return WireChange(
      kind: kind,
      document: WireDocument.fromJson(json['document'] as Map<String, Object?>),
      oldIndex: (json['oldIndex'] as num).toInt(),
      newIndex: (json['newIndex'] as num).toInt(),
    );
  }
}

// ---------------------------------------------------------------------------
// ServerFrame hierarchy
// ---------------------------------------------------------------------------

/// Sealed base class for all server-sent frames (PROTOCOL §7).
sealed class ServerFrame {
  const ServerFrame();

  /// Parses a server frame from a decoded JSON map.
  ///
  /// Throws [FormatException] if the frame type is missing, non-string, or the
  /// shape is invalid for a known type. Unknown types return [UnknownFrame] —
  /// the caller may log-and-ignore.
  static ServerFrame parse(Map<String, Object?> json) {
    final type = json['type'];
    if (type is! String) {
      throw FormatException(
          'Server frame missing or non-string "type" field: $json');
    }

    // Checked field extraction — throws FormatException (not TypeError) on bad data.
    T req<T>(String key) {
      final v = json[key];
      if (v is! T) {
        throw FormatException(
          'Frame type "$type": expected $T for key "$key", '
          'got ${v.runtimeType}: $v',
        );
      }
      return v;
    }

    T? opt<T>(String key) {
      final v = json[key];
      if (v == null) return null;
      if (v is! T) {
        throw FormatException(
          'Frame type "$type": expected $T? for key "$key", '
          'got ${v.runtimeType}: $v',
        );
      }
      return v as T;
    }

    return switch (type) {
      'welcome' => WelcomeFrame(
          connectionId: req<String>('connectionId'),
          protocol: opt<num>('protocol')?.toInt(),
        ),
      'response' => ResponseFrame(
          id: req<String>('id'),
          result: req<Map<String, Object?>>('result'),
        ),
      'error' => ErrorFrame(
          id: opt<String>('id'),
          status: req<String>('status'),
          message: req<String>('message'),
          details: opt<Map<String, Object?>>('details'),
        ),
      'listen.snapshot' => ListenSnapshotFrame(
          subscriptionId: req<String>('subscriptionId'),
          documents: [
            for (final d in req<List<Object?>>('documents'))
              WireDocument.fromJson(d as Map<String, Object?>),
          ],
          readTime: req<String>('readTime'),
          resumeToken: json['resumeToken'] != null
              ? (json['resumeToken'] as num).toInt()
              : null,
        ),
      'listen.delta' => ListenDeltaFrame(
          subscriptionId: req<String>('subscriptionId'),
          changes: [
            for (final c in req<List<Object?>>('changes'))
              WireChange.fromJson(c as Map<String, Object?>),
          ],
          count: req<num>('count').toInt(),
          readTime: req<String>('readTime'),
          resumeToken: json['resumeToken'] != null
              ? (json['resumeToken'] as num).toInt()
              : null,
        ),
      'listen.current' => ListenCurrentFrame(
          subscriptionId: req<String>('subscriptionId'),
          resumeToken: req<num>('resumeToken').toInt(),
        ),
      _ => UnknownFrame(type, json),
    };
  }
}

/// `{"type": "welcome", "connectionId": "...", "protocol"?: 3}`
final class WelcomeFrame extends ServerFrame {
  const WelcomeFrame({required this.connectionId, this.protocol});

  final String connectionId;
  final int? protocol;
}

/// `{"type": "response", "id": "...", "result": {...}}`
final class ResponseFrame extends ServerFrame {
  const ResponseFrame({required this.id, required this.result});

  final String id;
  final Map<String, Object?> result;
}

/// `{"type": "error", "id"?: "...", "status": "...", "message": "...", "details"?: {...}}`
final class ErrorFrame extends ServerFrame {
  const ErrorFrame({
    required this.id,
    required this.status,
    required this.message,
    this.details,
  });

  final String? id;
  final String status;
  final String message;
  final Map<String, Object?>? details;

  /// Creates a [WincheException] from this frame.
  WincheException toException() =>
      WincheException.fromError(status, message, details);
}

/// `{"type": "listen.snapshot", ...}` — full state snapshot (PROTOCOL §7.6).
final class ListenSnapshotFrame extends ServerFrame {
  const ListenSnapshotFrame({
    required this.subscriptionId,
    required this.documents,
    required this.readTime,
    this.resumeToken,
  });

  final String subscriptionId;
  final List<WireDocument> documents;

  /// Raw metadata timestamp string.
  final String readTime;
  final int? resumeToken;
}

/// `{"type": "listen.delta", ...}` — incremental mutation (PROTOCOL §7.6).
final class ListenDeltaFrame extends ServerFrame {
  const ListenDeltaFrame({
    required this.subscriptionId,
    required this.changes,
    required this.count,
    required this.readTime,
    this.resumeToken,
  });

  final String subscriptionId;
  final List<WireChange> changes;
  final int count;

  /// Raw metadata timestamp string.
  final String readTime;
  final int? resumeToken;
}

/// `{"type": "listen.current", "subscriptionId": "...", "resumeToken": ...}`
/// — a covered resume: the subscription is live and up to date; no documents.
final class ListenCurrentFrame extends ServerFrame {
  const ListenCurrentFrame({
    required this.subscriptionId,
    required this.resumeToken,
  });

  final String subscriptionId;
  final int resumeToken;
}

/// A frame type not recognized by this client version.
/// The [ProtocolConnection] logs and ignores these.
final class UnknownFrame extends ServerFrame {
  const UnknownFrame(this.type, this.raw);

  final String type;
  final Map<String, Object?> raw;
}

// ---------------------------------------------------------------------------
// Client frame builders — plain functions returning Map<String, Object?>
// (PROTOCOL §7)
// ---------------------------------------------------------------------------

/// `{"type": "ping", "id": "..."}` (PROTOCOL §7.4)
Map<String, Object?> pingFrame(String id) => {'type': 'ping', 'id': id};

/// `{"type": "doc.get", "id": "...", "path": "..."}` (PROTOCOL §7.4)
Map<String, Object?> docGetFrame(String id, String path) => {
      'type': 'doc.get',
      'id': id,
      'path': path,
    };

/// `{"type": "doc.getAll", "id": "...", "paths": [...]}` (PROTOCOL §7.4)
Map<String, Object?> docGetAllFrame(String id, List<String> paths) => {
      'type': 'doc.getAll',
      'id': id,
      'paths': paths,
    };

/// `{"type": "query", "id": "...", "query": {...}}` (PROTOCOL §7.4)
Map<String, Object?> queryFrame(String id, QuerySpec query) => {
      'type': 'query',
      'id': id,
      'query': query.toJson(),
    };

/// `{"type": "count", "id": "...", "query": {...}}`
Map<String, Object?> countFrame(String id, QuerySpec query) => {
      'type': 'count',
      'id': id,
      'query': query.toJson(),
    };

/// The wire protocol version this SDK speaks. v2 introduces the `deleted`
/// change kind; the server only emits `deleted` to clients advertising >= 2.
const int wireProtocolVersion = 2;

/// `{"type": "aggregate", "id": "...", "query": {...}, "aggregations": [...]}`
Map<String, Object?> aggregateFrame(
        String id, QuerySpec query, List<Object?> aggregations) =>
    {
      'type': 'aggregate',
      'id': id,
      'query': query.toJson(),
      'aggregations': aggregations,
    };

/// `{"type": "doc.listen", "id": "...", "path": "...", "protocol": ..., "resumeToken"?: ...}`
Map<String, Object?> docListenFrame(String id, String path, {int? resumeToken}) {
  final frame = <String, Object?>{
    'type': 'doc.listen',
    'id': id,
    'path': path,
    'protocol': wireProtocolVersion,
  };
  if (resumeToken != null) frame['resumeToken'] = resumeToken;
  return frame;
}

/// `{"type": "write", "id": "...", "writes": [...]}` (PROTOCOL §7.4)
Map<String, Object?> writeFrame(String id, List<Write> writes) => {
      'type': 'write',
      'id': id,
      'writes': [for (final w in writes) w.toJson()],
    };

/// `{"type": "tx.begin", "id": "..."}` (PROTOCOL §7.5)
Map<String, Object?> txBeginFrame(String id) => {'type': 'tx.begin', 'id': id};

/// `{"type": "tx.get", "id": "...", "transactionId": "...", "path": "..."}` (PROTOCOL §7.5)
Map<String, Object?> txGetFrame(String id, String transactionId, String path) =>
    {
      'type': 'tx.get',
      'id': id,
      'transactionId': transactionId,
      'path': path,
    };

/// `{"type": "tx.query", "id": "...", "transactionId": "...", "query": {...}}` (PROTOCOL §7.5)
Map<String, Object?> txQueryFrame(
        String id, String transactionId, QuerySpec query) =>
    {
      'type': 'tx.query',
      'id': id,
      'transactionId': transactionId,
      'query': query.toJson(),
    };

/// `{"type": "tx.commit", "id": "...", "transactionId": "...", "writes": [...]}` (PROTOCOL §7.5)
Map<String, Object?> txCommitFrame(
  String id,
  String transactionId,
  List<Write> writes,
) =>
    {
      'type': 'tx.commit',
      'id': id,
      'transactionId': transactionId,
      'writes': [for (final w in writes) w.toJson()],
    };

/// `{"type": "tx.rollback", "id": "...", "transactionId": "..."}` (PROTOCOL §7.5)
Map<String, Object?> txRollbackFrame(String id, String transactionId) => {
      'type': 'tx.rollback',
      'id': id,
      'transactionId': transactionId,
    };

/// `{"type": "listen", "id": "...", "query": {...}, "protocol": ..., "resumeToken"?: ...}` (PROTOCOL §7.6)
Map<String, Object?> listenFrame(
  String id,
  QuerySpec query, {
  int? resumeToken,
}) {
  final frame = <String, Object?>{
    'type': 'listen',
    'id': id,
    'query': query.toJson(),
    'protocol': wireProtocolVersion,
  };
  if (resumeToken != null) frame['resumeToken'] = resumeToken;
  return frame;
}

/// `{"type": "unlisten", "id": "...", "subscriptionId": "..."}` (PROTOCOL §7.6)
Map<String, Object?> unlistenFrame(String id, String subscriptionId) => {
      'type': 'unlisten',
      'id': id,
      'subscriptionId': subscriptionId,
    };
