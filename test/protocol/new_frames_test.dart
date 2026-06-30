import 'package:test/test.dart';
import 'package:winche_database/src/protocol/messages.dart';
import 'package:winche_database/src/protocol/query_spec.dart';
import '../facade/facade_harness.dart' show wireDoc, wireFields;

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
    expect(docListenFrame('2', 'users/u1'), {
      'type': 'doc.listen',
      'id': '2',
      'path': 'users/u1',
      'protocol': wireProtocolVersion,
    });
  });

  test('docListenFrame includes resumeToken when set', () {
    expect(docListenFrame('3', 'users/u1', resumeToken: 42)['resumeToken'], 42);
  });

  test('WireChange parses the deleted kind', () {
    final change = WireChange.fromJson({
      'kind': 'deleted',
      'document': wireDoc('users/u1', wireFields({'name': 'Alice'})),
      'oldIndex': 2,
      'newIndex': -1,
    });
    expect(change.kind, ChangeKind.deleted);
    expect(change.document.path, 'users/u1');
    expect(change.oldIndex, 2);
  });

  test('listen and doc.listen frames advertise the wire protocol version', () {
    expect(wireProtocolVersion, greaterThanOrEqualTo(2));

    final listen = listenFrame('1', QuerySpec('users'));
    expect(listen['protocol'], wireProtocolVersion);

    final docListen = docListenFrame('2', 'users/u1');
    expect(docListen['protocol'], wireProtocolVersion);
  });

  test('parses a listen.current frame', () {
    final frame = ServerFrame.parse({
      'type': 'listen.current',
      'subscriptionId': 'sub-1',
      'resumeToken': 57,
    });
    expect(frame, isA<ListenCurrentFrame>());
    final c = frame as ListenCurrentFrame;
    expect(c.subscriptionId, 'sub-1');
    expect(c.resumeToken, 57);
  });
}
