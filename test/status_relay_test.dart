import 'dart:async';

import 'package:test/test.dart';
import 'package:winche_database/src/facade/status_relay.dart';

void main() {
  late StatusRelay<int> relay;
  late List<int> seen;
  late bool done;

  setUp(() {
    relay = StatusRelay<int>(0);
    seen = [];
    done = false;
    relay.stream.listen(seen.add, onDone: () => done = true);
  });

  tearDown(() async => relay.close());

  test('forwards events from the attached source', () async {
    final source = StreamController<int>.broadcast();
    relay.attach(source.stream);

    source.add(1);
    source.add(2);
    await Future<void>.delayed(Duration.zero);

    expect(seen, [0, 1, 2],
        reason: 'setUp subscribed before attach, so the seeded initial '
            'value 0 is delivered first');
  });

  test('survives the source ending — the whole point', () async {
    final first = StreamController<int>.broadcast();
    relay.attach(first.stream);
    first.add(1);
    await Future<void>.delayed(Duration.zero);

    await first.close(); // a session was disposed
    await Future<void>.delayed(Duration.zero);

    expect(done, isFalse, reason: 'done leaked from the source and would kill every listener');

    final second = StreamController<int>.broadcast();
    relay.attach(second.stream);
    second.add(2);
    await Future<void>.delayed(Duration.zero);

    expect(seen, [0, 1, 2]);
  });

  test('stops forwarding from a replaced source', () async {
    final first = StreamController<int>.broadcast();
    final second = StreamController<int>.broadcast();
    relay.attach(first.stream);
    relay.attach(second.stream);

    first.add(99); // the old session must not be heard from again
    second.add(2);
    await Future<void>.delayed(Duration.zero);

    expect(seen, [0, 2]);
  });

  test('detach can emit a final value', () async {
    final source = StreamController<int>.broadcast();
    relay.attach(source.stream);
    source.add(1);
    await Future<void>.delayed(Duration.zero);

    relay.detach(finalValue: 0);
    await Future<void>.delayed(Duration.zero);

    expect(seen, [0, 1, 0]);
    expect(done, isFalse);
  });

  test('detach without a final value goes quiet but stays open', () async {
    final source = StreamController<int>.broadcast();
    relay.attach(source.stream);
    relay.detach();
    source.add(99);
    await Future<void>.delayed(Duration.zero);

    expect(seen, [0], reason: 'only the seeded initial value; detach happened '
        'before any real event arrived, and the detached source is ignored');
    expect(done, isFalse);
  });

  test('close does not signal done', () async {
    // ValueRelay deliberately never forwards done to its subscribers (see
    // WsTransport's "connectionStates does NOT complete" test) so a listener
    // can never be orphaned by an upstream ending. StatusRelay.close() simply
    // stops the relay from accepting further values; it does not complete the
    // stream.
    await relay.close();
    await Future<void>.delayed(Duration.zero);
    expect(done, isFalse);
  });

  test('is broadcast — several widgets can watch one status', () async {
    final other = <int>[];
    relay.stream.listen(other.add);
    final source = StreamController<int>.broadcast();
    relay.attach(source.stream);

    source.add(7);
    await Future<void>.delayed(Duration.zero);

    expect(seen, [0, 7]);
    expect(other, [0, 7]);
  });

  test('a late subscriber receives the current value', () async {
    final relay = StatusRelay<int>(0);
    addTearDown(relay.close);

    final source = StreamController<int>.broadcast();
    relay.attach(source.stream);
    source.add(7);
    await Future<void>.delayed(Duration.zero);

    final late_ = <int>[];
    relay.stream.listen(late_.add);
    await Future<void>.delayed(Duration.zero);

    expect(late_, equals([7]),
        reason: 'a widget built after the event must not sit on nothing');
  });

  test('the current value survives a source swap', () async {
    final relay = StatusRelay<int>(0);
    addTearDown(relay.close);

    final first = StreamController<int>.broadcast();
    relay.attach(first.stream);
    first.add(1);
    await Future<void>.delayed(Duration.zero);

    final second = StreamController<int>.broadcast();
    relay.attach(second.stream);
    second.add(2);
    await Future<void>.delayed(Duration.zero);

    final late_ = <int>[];
    relay.stream.listen(late_.add);
    await Future<void>.delayed(Duration.zero);

    expect(late_, equals([2]));
  });
}
