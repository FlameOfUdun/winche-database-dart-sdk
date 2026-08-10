import 'dart:convert';

/// Matches the server's per-segment id byte limit (`DocumentPathParser`).
const int _maxSegmentBytes = 1500;

/// Validates [path] as a document path (an EVEN number of well-formed
/// segments: `collection/document/collection/document/...`), mirroring the
/// server's `DocumentPathParser.IsValidDocumentPath`.
///
/// Throws [ArgumentError] naming the failed rule. The rejected path is never
/// echoed into the message — a path can be arbitrarily long.
void validateDocumentPath(String path) => _validatePathShape(path, even: true);

/// Validates [path] as a collection path (an ODD number of well-formed
/// segments: `collection/document/collection/...`), mirroring the server's
/// `DocumentPathParser.IsValidCollectionPath`.
///
/// Throws [ArgumentError] naming the failed rule. The rejected path is never
/// echoed into the message — a path can be arbitrarily long.
void validateCollectionPath(String path) =>
    _validatePathShape(path, even: false);

void _validatePathShape(String path, {required bool even}) {
  if (path.isEmpty) {
    throw ArgumentError('Path must not be empty.');
  }
  // Split WITHOUT removing empty entries: a leading '/', trailing '/', or
  // doubled '//' all produce an empty segment here, which is rejected below
  // instead of silently normalized away (that silent normalization is what
  // let a non-canonical path masquerade as canonical and only fail after a
  // round trip to the server).
  final parts = path.split('/');
  for (final segment in parts) {
    _validateSegment(segment);
  }
  if (parts.length.isEven != even) {
    throw ArgumentError(
      even
          ? 'Invalid document path: expected an even number of segments '
                '(collection/document/collection/document/...).'
          : 'Invalid collection path: expected an odd number of segments '
                '(collection/document/collection/...).',
    );
  }
}

void _validateSegment(String segment) {
  if (segment.isEmpty) {
    throw ArgumentError(
      'Path segments must not be empty (no leading, trailing, or doubled "/").',
    );
  }
  if (segment == '.' || segment == '..') {
    throw ArgumentError('Path segments "." and ".." are not allowed.');
  }
  if (segment.length >= 4 &&
      segment.startsWith('__') &&
      segment.endsWith('__')) {
    throw ArgumentError('Path segments matching "__*__" are reserved.');
  }
  if (utf8.encode(segment).length > _maxSegmentBytes) {
    throw ArgumentError(
      'A path segment exceeds the $_maxSegmentBytes-byte limit.',
    );
  }
}

/// The document id: the final `/`-separated segment.
String docId(String path) {
  final i = path.lastIndexOf('/');
  return i < 0 ? path : path.substring(i + 1);
}

/// The parent collection path: everything before the final `/`.
/// Returns '' when [path] has no '/'.
String collectionOf(String path) {
  final i = path.lastIndexOf('/');
  return i < 0 ? '' : path.substring(0, i);
}

/// The parent collection path, or null when [path] is a top-level segment.
String? parentOf(String path) {
  final i = path.lastIndexOf('/');
  return i <= 0 ? null : path.substring(0, i);
}

/// The '/'-separated segments of [path].
List<String> segments(String path) => path.split('/');
