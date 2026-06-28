import '../core/field_path.dart';
import '../core/paths.dart';
import '../core/timestamps.dart';
import '../core/value_order.dart';
import '../core/values.dart';
import '../protocol/messages.dart';
import '../protocol/writes.dart';
import 'records.dart';

/// The optimistic view of a document after applying pending writes.
class EffectiveDoc {
  const EffectiveDoc({
    required this.document,
    required this.hasPendingWrites,
  });

  /// The effective document, or null when effectively absent.
  final WireDocument? document;
  bool get exists => document != null;
  final bool hasPendingWrites;
}

/// Applies [pending] (ascending seq) over [base], producing the effective view.
EffectiveDoc applyOverlay(WireDocument? base, List<PendingWrite> pending) {
  // Working state: fields == null means the document is effectively absent.
  Map<String, Value>? fields = base == null ? null : Map.of(base.fields);
  String path = base?.path ?? (pending.isNotEmpty ? pending.first.path : '');

  for (final p in pending) {
    final w = p.write;
    if (w is DeleteWrite) {
      fields = null;
      continue;
    }
    fields ??= <String, Value>{};
    if (w is SetWrite) {
      path = w.path;
      if (w.mergeFields != null) {
        // Masked merge: write only the masked paths; a masked path absent from
        // the data (or carrying a delete sentinel) is removed. PROTOCOL §3.2.
        for (final mask in w.mergeFields!) {
          final v = resolvePath(w.fields, mask);
          if (v == null || v is DeleteFieldValue) {
            deletePath(fields, mask);
          } else {
            setPath(fields, mask, v);
          }
        }
      } else if (w.merge) {
        for (final e in w.fields.entries) {
          fields[e.key] = _mergeValue(fields[e.key], e.value);
        }
      } else {
        fields = Map.of(w.fields);
      }
      _applyTransforms(fields, w.transforms, p.localCommitTime);
    } else if (w is UpdateWrite) {
      path = w.path;
      for (final e in w.fields.entries) {
        if (e.value is DeleteFieldValue) {
          deletePath(fields, e.key);
        } else {
          setPath(fields, e.key, e.value);
        }
      }
      _applyTransforms(fields, w.transforms, p.localCommitTime);
    }
  }

  if (fields == null) {
    return EffectiveDoc(document: null, hasPendingWrites: pending.isNotEmpty);
  }
  final lastCommit = pending.isEmpty
      ? (base?.updateTime ?? '')
      : formatMetaTimestamp(pending.last.localCommitTime);
  final doc = WireDocument(
    path: path,
    id: docId(path),
    collection: collectionOf(path),
    fields: fields,
    createTime: base?.createTime ?? lastCommit,
    updateTime: lastCommit,
    version: base?.version ?? 0,
  );
  return EffectiveDoc(document: doc, hasPendingWrites: pending.isNotEmpty);
}

// --- Merge (set merge:true) ---
Value _mergeValue(Value? existing, Value incoming) {
  if (existing is MapValue && incoming is MapValue) {
    final merged = Map<String, Value>.of(existing.fields);
    for (final e in incoming.fields.entries) {
      if (e.value is DeleteFieldValue) {
        merged.remove(e.key);
      } else {
        merged[e.key] = _mergeValue(merged[e.key], e.value);
      }
    }
    return MapValue(merged);
  }
  return incoming;
}

// --- Transforms ---
void _applyTransforms(
    Map<String, Value> fields, List<FieldTransform>? transforms, DateTime now) {
  if (transforms == null) return;
  for (final t in transforms) {
    final current = resolvePath(fields, t.field);
    final result = switch (t.kind) {
      TransformKind.serverTimestamp => TimestampValue(now.toUtc()),
      TransformKind.increment => _numeric(current, t.operand, (a, b) => a + b),
      TransformKind.maximum =>
        _numeric(current, t.operand, (a, b) => a > b ? a : b),
      TransformKind.minimum =>
        _numeric(current, t.operand, (a, b) => a < b ? a : b),
      TransformKind.arrayUnion => _arrayUnion(current, t.operand),
      TransformKind.arrayRemove => _arrayRemove(current, t.operand),
    };
    setPath(fields, t.field, result);
  }
}

Value _numeric(Value? current, Value? operand, num Function(num, num) op) {
  // Server semantics: when the current field is missing or non-numeric, the
  // operand wins outright (no arithmetic against an implicit zero). This keeps
  // increment/maximum/minimum correct for first-write and type-mismatch cases.
  if (current is! IntegerValue && current is! DoubleValue) {
    return operand ?? const IntegerValue(0);
  }
  final a = asNum(current, orElse: 0);
  final b = asNum(operand, orElse: 0);
  final r = op(a, b);
  // integer op integer stays integer; any double → double.
  if (current is DoubleValue || operand is DoubleValue || r is double) {
    return DoubleValue(r.toDouble());
  }
  return IntegerValue(r.toInt());
}

// NOTE: Value's == uses typed equality where IntegerValue(5) != DoubleValue(5.0),
// so array membership here is a local approximation that the server ack later
// reconciles. Do NOT attempt to "fix" cross-type numeric equality in this phase.
Value _arrayUnion(Value? current, Value? operand) {
  final base =
      current is ArrayValue ? List<Value>.of(current.elements) : <Value>[];
  final add = operand is ArrayValue ? operand.elements : const <Value>[];
  for (final e in add) {
    if (!base.contains(e)) base.add(e);
  }
  return ArrayValue(base);
}

Value _arrayRemove(Value? current, Value? operand) {
  if (current is! ArrayValue) return const ArrayValue([]);
  final remove = operand is ArrayValue ? operand.elements : const <Value>[];
  return ArrayValue([
    for (final e in current.elements)
      if (!remove.contains(e)) e
  ]);
}

/// Returns a copy of [doc] containing only the [select] (dotted) paths;
/// id/path/collection and metadata are preserved. Paths that do not resolve
/// are skipped.
WireDocument projectFields(WireDocument doc, List<String> select) {
  final fields = <String, Value>{};
  for (final path in select) {
    final v = resolvePath(doc.fields, path);
    if (v != null) setPath(fields, path, v);
  }
  return WireDocument(
    path: doc.path,
    id: doc.id,
    collection: doc.collection,
    fields: fields,
    createTime: doc.createTime,
    updateTime: doc.updateTime,
    version: doc.version,
  );
}

/// Builds the effective document set for a collection: overlays [pendingByPath]
/// onto [base] (keyed by path), returning the surviving documents and whether
/// any path carried pending writes. Callers run their query over [docs].
({List<WireDocument> docs, bool anyPending}) buildEffectiveView(
  Iterable<WireDocument> base,
  Map<String, List<PendingWrite>> pendingByPath,
) {
  final baseByPath = {for (final d in base) d.path: d};
  final paths = <String>{...baseByPath.keys, ...pendingByPath.keys};
  final docs = <WireDocument>[];
  var anyPending = false;
  for (final path in paths) {
    final pending = pendingByPath[path] ?? const <PendingWrite>[];
    if (pending.isNotEmpty) anyPending = true;
    final eff = applyOverlay(baseByPath[path], pending);
    if (eff.document != null) docs.add(eff.document!);
  }
  return (docs: docs, anyPending: anyPending);
}
