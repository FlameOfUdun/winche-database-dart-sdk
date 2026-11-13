import 'dart:async';
import 'package:test/test.dart';
import 'package:winche_database/winche_database.dart';

import 'facade_harness.dart';

Map<String, Object?> ref(String path) => {'referenceValue': path};

void main() {
  late FacadeHarness h;
  setUp(() => h = FacadeHarness());
  tearDown(() => h.close());

  final visit = wireDoc('visits/v1', {
    'patient': ref('patients/p1'),
    'team': {'arrayValue': {'values': [ref('staff/a'), ref('staff/hidden')]}},
    'note': {'stringValue': 'hi'},
  });
  final included = {
    'patients/p1': wireDoc('patients/p1', {'name': {'stringValue': 'Ann'}, 'doctor': ref('doctors/d1')}),
    'doctors/d1': wireDoc('doctors/d1', {'name': {'stringValue': 'Dr Who'}}),
    'staff/a': wireDoc('staff/a', {'name': {'stringValue': 'A'}}),
  };

  test('get with expand asks the server and puts the referenced documents in place', () async {
    h.handler = (f) {
      if (f['type'] == 'doc.get') h.respond(f, {'document': visit, 'included': included});
    };
    final snap = await h.db.doc('visits/v1').expand(['patient.doctor', 'team']).get();

    final frame = h.requests.firstWhere((f) => f['type'] == 'doc.get');
    expect(frame['expand'], ['patient.doctor', 'team']);
    final data = snap.data()!;
    final patient = data['patient'] as DocumentSnapshot<Map<String, Object?>>;
    expect(patient.path, 'patients/p1');
    final doctor = patient.data()!['doctor'] as DocumentSnapshot<Map<String, Object?>>;
    expect(doctor.data()!['name'], 'Dr Who');
    final team = data['team'] as List<Object?>;
    expect((team[0] as DocumentSnapshot).data()!['name'], 'A');
    expect(team[1], 'staff/hidden', reason: 'not readable (not included): stays a path');
    expect(data['note'], 'hi');
    expect(snap.included.keys, containsAll(['patients/p1', 'doctors/d1', 'staff/a']));
  });

  test('without expand, references are paths and nothing extra is asked for', () async {
    h.handler = (f) {
      if (f['type'] == 'doc.get') h.respond(f, {'document': visit});
    };
    final snap = await h.db.doc('visits/v1').get();
    expect(h.requests.firstWhere((f) => f['type'] == 'doc.get').containsKey('expand'), isFalse);
    expect(snap.data()!['patient'], 'patients/p1');
    expect(snap.included, isEmpty);
  });

  test('a query with expand expands each result', () async {
    h.handler = (f) {
      if (f['type'] == 'query') h.respond(f, {'documents': [visit], 'hasMore': false, 'included': included});
    };
    final snap = await h.db.collection('visits').where('note', isEqualTo: 'hi').expand(['patient']).get();
    expect(h.requests.firstWhere((f) => f['type'] == 'query')['expand'], ['patient']);
    final patient = snap.docs.single.data()!['patient'] as DocumentSnapshot<Map<String, Object?>>;
    expect(patient.data()!['name'], 'Ann');
    expect(patient.data()!['doctor'], 'doctors/d1', reason: 'only "patient" was expanded');
  });

  test('a live document follows changes to its referenced documents', () async {
    h.handler = (f) {
      if (f['type'] == 'doc.listen') h.respond(f, {'subscriptionId': 's'});
    };
    final snaps = <DocumentSnapshot<Map<String, Object?>>>[];
    final sub = h.db.doc('visits/v1').expand(['patient.doctor']).snapshots().listen(snaps.add);
    await pump();
    expect(h.requests.firstWhere((f) => f['type'] == 'doc.listen')['expand'], ['patient.doctor']);

    h.push({
      'type': 'listen.snapshot', 'subscriptionId': 's', 'documents': [visit],
      'readTime': '2026-06-08T10:00:00+00:00', 'resumeToken': 1, 'included': included,
    });
    await pump();
    String doctorName() => ((snaps.last.data()!['patient'] as DocumentSnapshot).data()!['doctor'] as DocumentSnapshot).data()!['name'] as String;
    expect(doctorName(), 'Dr Who');

    // Only the doctor changed: a delta with no changes, just the new included document.
    h.push({
      'type': 'listen.delta', 'subscriptionId': 's', 'changes': [], 'count': 1,
      'readTime': '2026-06-08T10:01:00+00:00', 'resumeToken': 2,
      'included': {'doctors/d1': wireDoc('doctors/d1', {'name': {'stringValue': 'Dr Two'}}, updateTime: '2026-06-08T10:01:00+00:00', version: 2)},
    });
    await pump();
    expect(doctorName(), 'Dr Two');

    // The doctor is gone: back to a path.
    h.push({
      'type': 'listen.delta', 'subscriptionId': 's', 'changes': [], 'count': 1,
      'readTime': '2026-06-08T10:02:00+00:00', 'resumeToken': 3, 'excluded': ['doctors/d1'],
    });
    await pump();
    expect((snaps.last.data()!['patient'] as DocumentSnapshot).data()!['doctor'], 'doctors/d1');
    await sub.cancel();
  });

  test('a live query with expand sends expand and expands each emission', () async {
    h.handler = (f) {
      if (f['type'] == 'listen') h.respond(f, {'subscriptionId': 'q'});
    };
    final snaps = <QuerySnapshot<Map<String, Object?>>>[];
    final sub = h.db.collection('visits').expand(['patient']).snapshots().listen(snaps.add);
    await pump();
    expect(h.requests.firstWhere((f) => f['type'] == 'listen')['expand'], ['patient']);
    h.push({
      'type': 'listen.snapshot', 'subscriptionId': 'q', 'documents': [visit],
      'readTime': '2026-06-08T10:00:00+00:00', 'resumeToken': 1, 'included': included,
    });
    await pump();
    expect((snaps.last.docs.single.data()!['patient'] as DocumentSnapshot).data()!['name'], 'Ann');

    h.push({
      'type': 'listen.delta', 'subscriptionId': 'q', 'changes': [], 'count': 1,
      'readTime': '2026-06-08T10:01:00+00:00', 'resumeToken': 2,
      'included': {'patients/p1': wireDoc('patients/p1', {'name': {'stringValue': 'Annie'}}, updateTime: '2026-06-08T10:01:00+00:00', version: 2)},
    });
    await pump();
    expect((snaps.last.docs.single.data()!['patient'] as DocumentSnapshot).data()!['name'], 'Annie');
    expect(snaps.last.docChanges, isEmpty, reason: 'the results themselves did not change');
    await sub.cancel();
  });

  test('an expanded get shows the user\'s own writes the server has not confirmed yet', () async {
    h.handler = (f) {
      // Writes are never acknowledged here: they stay pending.
      if (f['type'] == 'doc.get') h.respond(f, {'document': null, 'included': <String, Object?>{}});
    };
    unawaited(h.db.doc('visits/new').set({'note': 'just written', 'patient': h.db.doc('patients/p1')}));
    await pump();
    final snap = await h.db.doc('visits/new').expand(['patient']).get();
    expect(snap.exists, isTrue);
    expect(snap.data()!['note'], 'just written');
    expect(snap.metadata.hasPendingWrites, isTrue);
    expect(snap.data()!['patient'], 'patients/p1', reason: 'not included by the server yet: a path');
  });

  group('on this device', () {
    final doctorV1 = wireDoc('doctors/d1', {'name': {'stringValue': 'Dr Who'}});
    final patientDoc = wireDoc('patients/p1', {'name': {'stringValue': 'Ann'}, 'doctor': ref('doctors/d1')});
    String? doctorOf(DocumentSnapshot<Map<String, Object?>> s) {
      final p = s.data()!['patient'];
      if (p is! DocumentSnapshot) return null;
      final d = p.data()!['doctor'];
      return d is DocumentSnapshot ? d.data()!['name'] as String? : 'PATH';
    }

    test('referenced documents from an expanded get are cached, and an offline expanded get follows them there', () async {
      var online = true;
      h.handler = (f) {
        if (f['type'] == 'doc.get') {
          if (!online) return h.respondError(f, 'UNAVAILABLE', 'down');
          if (f['path'] == 'visits/v1') {
            h.respond(f, {'document': visit, 'included': {'patients/p1': patientDoc, 'doctors/d1': doctorV1}});
          } else {
            h.respond(f, {'document': null});
          }
        }
      };
      final ref = h.db.doc('visits/v1').expand(['patient.doctor']);
      expect(doctorOf(await ref.get()), 'Dr Who');

      // From the cache only (and offline): the same references, followed through the cache.
      final cached = await ref.get(const GetOptions(source: Source.cache));
      expect(cached.metadata.fromCache, isTrue);
      expect(doctorOf(cached), 'Dr Who');

      online = false;
      final offline = await ref.get();
      expect(offline.metadata.fromCache, isTrue);
      expect(doctorOf(offline), 'Dr Who');
    });

    test('an expanded query read online is followed through the cache offline', () async {
      var online = true;
      h.handler = (f) {
        if (f['type'] == 'query') {
          if (!online) return h.respondError(f, 'UNAVAILABLE', 'down');
          h.respond(f, {'documents': [visit], 'hasMore': false, 'included': {'patients/p1': patientDoc, 'doctors/d1': doctorV1}});
        }
      };
      final query = h.db.collection('visits').expand(['patient.doctor']);
      expect(doctorOf((await query.get()).docs.single), 'Dr Who');
      online = false;
      final offline = await query.get();
      expect(offline.metadata.fromCache, isTrue);
      expect(doctorOf(offline.docs.single), 'Dr Who');
    });

    test("the user's unsynced change to a referenced document shows in expanded reads", () async {
      h.handler = (f) {
        // Writes stay unacknowledged; reads answer what the server has.
        if (f['type'] == 'doc.get') h.respond(f, {'document': visit, 'included': {'patients/p1': patientDoc, 'doctors/d1': doctorV1}});
      };
      unawaited(h.db.doc('doctors/d1').update({'name': 'Dr Offline'}));
      await pump();
      final snap = await h.db.doc('visits/v1').expand(['patient.doctor']).get();
      expect(doctorOf(snap), 'Dr Offline');
    });

    test("a live expanded listener shows the user's unsynced change to a referenced document at once", () async {
      h.handler = (f) {
        if (f['type'] == 'doc.listen') h.respond(f, {'subscriptionId': 's'});
      };
      final snaps = <DocumentSnapshot<Map<String, Object?>>>[];
      final sub = h.db.doc('visits/v1').expand(['patient.doctor']).snapshots().listen(snaps.add);
      await pump();
      h.push({
        'type': 'listen.snapshot', 'subscriptionId': 's', 'documents': [visit],
        'readTime': '2026-06-08T10:00:00+00:00', 'resumeToken': 1,
        'included': {'patients/p1': patientDoc, 'doctors/d1': doctorV1},
      });
      await pump();
      expect(doctorOf(snaps.last), 'Dr Who');

      unawaited(h.db.doc('doctors/d1').update({'name': 'Dr Local'}));
      await pump();
      expect(doctorOf(snaps.last), 'Dr Local', reason: 'no server round trip needed');
      await sub.cancel();
    });
  });
}
