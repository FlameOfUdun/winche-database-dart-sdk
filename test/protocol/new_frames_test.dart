import 'package:test/test.dart';
import 'package:winche_database/src/protocol/messages.dart';
import 'package:winche_database/src/protocol/query_spec.dart';

void main() {
  test('aggregateFrame carries type, id, query and aggregations', () {
    final spec = QuerySpec('users');
    final frame = aggregateFrame('1', spec, [
      {'kind': 'count', 'alias': 'n'},
    ]);
    expect(frame['type'], 'aggregate');
    expect(frame['id'], '1');
    expect(frame['query'], spec.toJson());
    expect(frame['aggregations'], [
      {'kind': 'count', 'alias': 'n'},
    ]);
  });

  test('docListenFrame omits resumeToken when null', () {
    expect(docListenFrame('2', 'users/u1'),
        {'type': 'doc.listen', 'id': '2', 'path': 'users/u1'});
  });

  test('docListenFrame includes resumeToken when set', () {
    expect(docListenFrame('3', 'users/u1', resumeToken: 42)['resumeToken'], 42);
  });
}
