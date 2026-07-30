import 'dart:async';

import 'package:test/test.dart';
import 'package:winche_database/src/core/value_relay.dart';

void main() {
  test('a subscriber receives the current value immediately', () async {
    final relay = ValueRelay<String>('connecting');
    addTearDown(relay.close);

    final seen = <String>[];
    relay.stream.listen(seen.add);
    await Future<void>.delayed(Duration.zero);

    expect(seen, equals(['connecting']));
  });

  test('subsequent changes are forwarded', () async {
    final relay = ValueRelay<String>('connecting');
    addTearDown(relay.close);

    final seen = <String>[];
    relay.stream.listen(seen.add);
    relay.add('ready');
    await Future<void>.delayed(Duration.zero);

    expect(seen, equals(['connecting', 'ready']));
  });

  // The whole point: this is what the old edge-triggered signal could not do,
  // and why every consumer had to seed itself.
  test('a LATE subscriber receives the current value, not nothing', () async {
    final relay = ValueRelay<String>('connecting');
    addTearDown(relay.close);

    relay.add('ready');
    await Future<void>.delayed(Duration.zero);

    final late_ = <String>[];
    relay.stream.listen(late_.add);
    await Future<void>.delayed(Duration.zero);

    expect(late_, equals(['ready']));
  });

  // Load-bearing, not cosmetic: LiveFeed._resubscribe tears down before it
  // subscribes, so a repeated `ready` would kill a healthy subscription.
  test('consecutive duplicates are suppressed per subscriber', () async {
    final relay = ValueRelay<String>('ready');
    addTearDown(relay.close);

    final seen = <String>[];
    relay.stream.listen(seen.add);
    relay.add('ready');
    relay.add('ready');
    await Future<void>.delayed(Duration.zero);

    expect(seen, equals(['ready']));
  });

  // Guards against silently regressing connectionStates from broadcast to
  // single-subscription, which would throw at the second listen site.
  test('a stored stream can be listened to twice, seeding both', () async {
    final relay = ValueRelay<String>('ready');
    addTearDown(relay.close);

    final stored = relay.stream;
    final a = <String>[];
    final b = <String>[];
    stored.listen(a.add);
    stored.listen(b.add);
    await Future<void>.delayed(Duration.zero);

    expect(a, equals(['ready']));
    expect(b, equals(['ready']));
    expect(stored.isBroadcast, isTrue);
  });

  test('two independent subscribers both see later changes', () async {
    final relay = ValueRelay<String>('connecting');
    addTearDown(relay.close);

    final a = <String>[];
    relay.stream.listen(a.add);
    await Future<void>.delayed(Duration.zero);
    final b = <String>[];
    relay.stream.listen(b.add);
    await Future<void>.delayed(Duration.zero);

    relay.add('disconnected');
    await Future<void>.delayed(Duration.zero);

    expect(a, equals(['connecting', 'disconnected']));
    expect(b, equals(['connecting', 'disconnected']));
  });

  test('value exposes the latest without subscribing', () {
    final relay = ValueRelay<int>(1);
    addTearDown(relay.close);

    expect(relay.value, equals(1));
    relay.add(2);
    expect(relay.value, equals(2));
  });

  // Without this, every subscriber outlives the relay holding an open
  // Stream.multi controller, and a disposed facade can never release its
  // listeners. Distinct from "a failed dial must not end the stream" — a failed
  // dial never calls close(), so forwarding done here cannot end a stream that
  // should stay open.
  test('close completes subscribers so they can release', () async {
    final relay = ValueRelay<int>(1);

    var done = false;
    final sub = relay.stream.listen((_) {}, onDone: () => done = true);
    await Future<void>.delayed(Duration.zero);

    await relay.close();
    await Future<void>.delayed(Duration.zero);

    expect(done, isTrue);
    await sub.cancel();
  });

  test('add after close is a no-op rather than a StateError', () async {
    final relay = ValueRelay<int>(1);
    await relay.close();

    expect(() => relay.add(2), returnsNormally);
  });

  test('cancelling a subscriber does not disturb the others', () async {
    final relay = ValueRelay<String>('connecting');
    addTearDown(relay.close);

    final a = <String>[];
    final subA = relay.stream.listen(a.add);
    final b = <String>[];
    relay.stream.listen(b.add);
    await Future<void>.delayed(Duration.zero);

    await subA.cancel();
    relay.add('ready');
    await Future<void>.delayed(Duration.zero);

    expect(a, equals(['connecting']), reason: 'cancelled, so no new events');
    expect(b, equals(['connecting', 'ready']));
  });
}
