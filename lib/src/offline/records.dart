import '../protocol/messages.dart';
import '../protocol/writes.dart';

/// A cached document: either a live document or a tombstone (known-absent).
class CachedDocument {
  CachedDocument.live(WireDocument doc)
      : document = doc,
        deleted = false,
        updateTime = doc.updateTime,
        path = doc.path;

  CachedDocument.tombstone(this.path, this.updateTime)
      : document = null,
        deleted = true;

  CachedDocument._({
    required this.document,
    required this.deleted,
    required this.updateTime,
    required this.path,
  });

  /// The live document, or null when [deleted].
  final WireDocument? document;
  final bool deleted;
  final String updateTime;
  final String path;

  Map<String, Object?> toRecord() {
    if (deleted) {
      return {'deleted': true, 'path': path, 'updateTime': updateTime};
    }
    return {...document!.toJson(), 'deleted': false};
  }

  static CachedDocument fromRecord(Map<String, Object?> record) {
    if (record['deleted'] == true) {
      return CachedDocument.tombstone(
          record['path'] as String, record['updateTime'] as String);
    }
    return CachedDocument._(
      document: WireDocument.fromJson(record),
      deleted: false,
      updateTime: record['updateTime'] as String,
      path: record['path'] as String,
    );
  }
}

/// The kind of a pending write, derived from the write type.
enum PendingKind { set, update, delete }

/// The version basis a pending write was made against (for version-checked
/// replay). Set [existsFalse] when the document was known-absent; set
/// [updateTime]/[version] when it had a confirmed value; all-null means the
/// base was unknown (the write replays last-write-wins).
class PendingBase {
  const PendingBase({this.version, this.updateTime, this.existsFalse});

  final int? version;
  final String? updateTime;
  final bool? existsFalse;

  Map<String, Object?> toRecord() => {
        if (version != null) 'version': version,
        if (updateTime != null) 'updateTime': updateTime,
        if (existsFalse != null) 'existsFalse': existsFalse,
      };

  static PendingBase? fromRecord(Map<String, Object?>? r) {
    if (r == null) return null;
    return PendingBase(
      version: r['version'] as int?,
      updateTime: r['updateTime'] as String?,
      existsFalse: r['existsFalse'] as bool?,
    );
  }
}

/// A durable pending write in the offline queue.
class PendingWrite {
  PendingWrite({
    required this.seq,
    required this.path,
    required this.write,
    required this.localCommitTime,
    this.base,
    this.appPrecondition,
    this.batchId,
  });

  final int seq;
  final String path;
  final Write write;
  final PendingBase? base;
  final Precondition? appPrecondition;
  final String? batchId;
  final DateTime localCommitTime;

  PendingKind get kind => switch (write) {
        SetWrite() => PendingKind.set,
        UpdateWrite() => PendingKind.update,
        DeleteWrite() => PendingKind.delete,
      };

  Map<String, Object?> toRecord() => {
        'seq': seq,
        'path': path,
        'write': write.toJson(),
        if (base != null) 'base': base!.toRecord(),
        if (appPrecondition != null)
          'appPrecondition': appPrecondition!.toJson(),
        if (batchId != null) 'batchId': batchId,
        'localCommitTime': localCommitTime.toUtc().toIso8601String(),
      };

  static PendingWrite fromRecord(Map<String, Object?> r) => PendingWrite(
        seq: r['seq'] as int,
        path: r['path'] as String,
        write: Write.fromJson((r['write'] as Map).cast<String, Object?>()),
        base: PendingBase.fromRecord(
            (r['base'] as Map?)?.cast<String, Object?>()),
        appPrecondition: Precondition.fromJson(
            (r['appPrecondition'] as Map?)?.cast<String, Object?>()),
        batchId: r['batchId'] as String?,
        localCommitTime: DateTime.parse(r['localCommitTime'] as String),
      );

  PendingWrite copyWith({PendingBase? base}) => PendingWrite(
        seq: seq,
        path: path,
        write: write,
        localCommitTime: localCommitTime,
        base: base ?? this.base,
        appPrecondition: appPrecondition,
        batchId: batchId,
      );
}
