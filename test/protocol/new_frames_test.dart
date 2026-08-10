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
    expect(
      docListenFrame('3', 'users/u1', resumeToken: '42:0')['resumeToken'],
      '42:0',
    );
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

  test(
      'resumeToken round-trips as an opaque string through snapshot, delta, '
      'current, and back out onto a re-subscribe frame', () {
    // A value shaped like "{xid}:{seq}" where the xid exceeds the safe
    // integer range of a JSON number (2^53) — the whole reason it is a
    // string on the wire now. Never parsed, ordered, or done arithmetic on;
    // this test only checks it survives verbatim.
    const token = '18446744073709551615:42';

    final snapshot = ServerFrame.parse({
      'type': 'listen.snapshot',
      'subscriptionId': 'sub-1',
      'documents': <Object?>[],
      'readTime': '2026-06-07T12:00:00+00:00',
      'resumeToken': token,
    }) as ListenSnapshotFrame;
    expect(snapshot.resumeToken, token);

    final delta = ServerFrame.parse({
      'type': 'listen.delta',
      'subscriptionId': 'sub-1',
      'changes': <Object?>[],
      'count': 0,
      'readTime': '2026-06-07T12:00:01+00:00',
      'resumeToken': token,
    }) as ListenDeltaFrame;
    expect(delta.resumeToken, token);

    final current = ServerFrame.parse({
      'type': 'listen.current',
      'subscriptionId': 'sub-1',
      'resumeToken': token,
    }) as ListenCurrentFrame;
    expect(current.resumeToken, token);

    // Whichever frame supplied the freshest token, it is echoed back verbatim
    // on the next subscribe/re-subscribe — the client never mutates it.
    final relisten = listenFrame('4', QuerySpec('users'), resumeToken: token);
    expect(relisten['resumeToken'], token);

    final redocListen = docListenFrame('5', 'users/u1', resumeToken: token);
    expect(redocListen['resumeToken'], token);
  });

  test('parses a listen.current frame', () {
    final frame = ServerFrame.parse({
      'type': 'listen.current',
      'subscriptionId': 'sub-1',
      'resumeToken': '57:0',
    });
    expect(frame, isA<ListenCurrentFrame>());
    final c = frame as ListenCurrentFrame;
    expect(c.subscriptionId, 'sub-1');
    expect(c.resumeToken, '57:0');
  });
}
