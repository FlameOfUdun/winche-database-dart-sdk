import 'package:test/test.dart';
import 'package:winche_database/winche_database.dart';

void main() {
  test('Aggregate.count omits field', () {
    expect(Aggregate.count(alias: 'n').toJson(), {'kind': 'count', 'alias': 'n'});
  });

  test('Aggregate.sum includes field', () {
    expect(Aggregate.sum('total', alias: 'revenue').toJson(),
        {'kind': 'sum', 'alias': 'revenue', 'field': 'total'});
  });

  test('Aggregate.average includes field', () {
    expect(Aggregate.average('age', alias: 'avg').toJson(),
        {'kind': 'average', 'alias': 'avg', 'field': 'age'});
  });
}
