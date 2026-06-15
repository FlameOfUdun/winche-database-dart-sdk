import 'package:test/test.dart';
import 'package:winche_database/src/offline/records.dart';
import 'package:winche_database/src/offline/write_queue.dart';
import 'package:winche_database/src/core/values.dart';
import 'package:winche_database/src/protocol/writes.dart';

import 'fake_local_store.dart';

void main() {
  late FakeLocalStore store;
  late WriteQueue queue;
  setUp(() {
    store = FakeLocalStore();
    queue = WriteQueue(store);
  });

  SetWrite setW(String path) => SetWrite(path, {'n': const IntegerValue(1)});

  test('enqueue assigns increasing seq and persists', () async {
    final a = await queue.enqueue(setW('users/a'),
        localCommitTime: DateTime.utc(2026));
    final b = await queue.enqueue(setW('users/b'),
        localCommitTime: DateTime.utc(2026));
    expect(b.seq, greaterThan(a.seq));
    final all = await queue.all();
    expect(all.map((p) => p.path), ['users/a', 'users/b']);
  });

  test('all() rehydrates PendingWrite incl. base + batchId', () async {
    await queue.enqueue(setW('users/a'),
        base: const PendingBase(updateTime: 'T', version: 2),
        batchId: 'b1',
        localCommitTime: DateTime.utc(2026));
    final p = (await queue.all()).single;
    expect(p.write, isA<SetWrite>());
    expect(p.base!.version, 2);
    expect(p.batchId, 'b1');
  });

  test('forPath filters by path in seq order', () async {
    await queue.enqueue(setW('users/a'), localCommitTime: DateTime.utc(2026));
    await queue.enqueue(setW('users/b'), localCommitTime: DateTime.utc(2026));
    await queue.enqueue(SetWrite('users/a', {'n': const IntegerValue(2)}),
        localCommitTime: DateTime.utc(2026));
    final forA = await queue.forPath('users/a');
    expect(forA.length, 2);
    expect(forA.first.seq, lessThan(forA.last.seq));
  });

  test('byPathInCollection groups direct children only', () async {
    await queue.enqueue(setW('users/a'), localCommitTime: DateTime.utc(2026));
    await queue.enqueue(setW('users/b'), localCommitTime: DateTime.utc(2026));
    await queue.enqueue(setW('users/a/posts/p1'),
        localCommitTime: DateTime.utc(2026));
    final byPath = await queue.byPathInCollection('users');
    expect(byPath.keys.toSet(), {'users/a', 'users/b'});
  });

  test('remove deletes by seq; hasPending reflects state', () async {
    final a = await queue.enqueue(setW('users/a'),
        localCommitTime: DateTime.utc(2026));
    expect(await queue.hasPending(), isTrue);
    await queue.remove(a.seq);
    expect(await queue.hasPending(), isFalse);
  });

  test('survives a store reopen (durable)', () async {
    await queue.enqueue(setW('users/a'),
        base: const PendingBase(existsFalse: true),
        localCommitTime: DateTime.utc(2026));
    final reopened = WriteQueue(store.reopen());
    final p = (await reopened.all()).single;
    expect(p.path, 'users/a');
    expect(p.base!.existsFalse, isTrue);
  });

  test('rebasePath updates base.updateTime for all entries of a path',
      () async {
    await queue.enqueue(setW('users/a'),
        base: const PendingBase(updateTime: 'OLD'),
        localCommitTime: DateTime.utc(2026));
    await queue.enqueue(SetWrite('users/a', {'n': const IntegerValue(2)}),
        base: const PendingBase(updateTime: 'OLD'),
        localCommitTime: DateTime.utc(2026));
    await queue.enqueue(setW('users/b'),
        base: const PendingBase(updateTime: 'OLD'),
        localCommitTime: DateTime.utc(2026));
    await queue.rebasePath('users/a', const PendingBase(updateTime: 'NEW'));
    final forA = await queue.forPath('users/a');
    expect(forA.every((p) => p.base!.updateTime == 'NEW'), isTrue);
    final forB = await queue.forPath('users/b');
    expect(forB.single.base!.updateTime, 'OLD');
  });
}
