import '../protocol/messages.dart';
import '../protocol/query_spec.dart';

/// Where a read should be served from.
enum Source {
  /// Read from the server when reachable (refreshing the cache); fall back to
  /// the cache when the server is unreachable. The default.
  serverOrCache,

  /// Read from the server only; throws when unreachable.
  server,

  /// Read from the local cache only; never contacts the server.
  cache,
}

/// Options for a one-shot read.
class GetOptions {
  const GetOptions({this.source = Source.serverOrCache});
  final Source source;
}

/// Result of a single-document read.
class DocReadResult {
  const DocReadResult({
    required this.document,
    required this.fromCache,
    this.hasPendingWrites = false,
  });

  /// The document, or null when it does not exist.
  final WireDocument? document;
  final bool fromCache;
  final bool hasPendingWrites;
}

/// Result of a query read.
class QueryReadResult {
  const QueryReadResult({
    required this.documents,
    required this.fromCache,
    required this.hasMore,
    this.hasPendingWrites = false,
  });

  final List<WireDocument> documents;
  final bool fromCache;
  final bool hasMore;
  final bool hasPendingWrites;
}

/// Routes reads to the server and/or local cache.
abstract interface class ReadCoordinator {
  Future<DocReadResult> getDocument(String path, GetOptions options);
  Future<List<DocReadResult>> getAll(List<String> paths, GetOptions options);
  Future<QueryReadResult> runQuery(QuerySpec spec, GetOptions options);
}
