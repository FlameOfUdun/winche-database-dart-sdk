import 'package:test/test.dart';
import 'package:winche_database/src/core/values.dart';
import 'package:winche_database/src/offline/reference_walk.dart';
import 'package:winche_database/src/protocol/messages.dart';

WireDocument doc(String path, Map<String, Value> fields) => WireDocument(
      path: path, id: path.split('/').last, collection: path.split('/').first, fields: fields,
      createTime: '2026-01-01T00:00:00+00:00', updateTime: '2026-01-01T00:00:00+00:00', version: 1,
    );

void main() {
  test('the walk stops at the limit the server announced', () async {
    final targets = [for (var i = 0; i < 5; i++) doc('t/t$i', {'n': IntegerValue(i)})];
    final root = doc('r/root', {'all': ArrayValue([for (final t in targets) ReferenceValue(t.path)])});
    Future<WireDocument?> resolve(String p) async => targets.firstWhere((t) => t.path == p);

    expect((await walkReferences([root], [parseExpandPath('all')], resolve)).length, 5);
    expect((await walkReferences([root], [parseExpandPath('all')], resolve, limit: 3)).length, 3);
  });

  test('welcome carries the expand limit', () {
    final w = ServerFrame.parse({'type': 'welcome', 'connectionId': 'c', 'expandLimit': 250}) as WelcomeFrame;
    expect(w.expandLimit, 250);
    expect((ServerFrame.parse({'type': 'welcome', 'connectionId': 'c'}) as WelcomeFrame).expandLimit, isNull);
  });
}
