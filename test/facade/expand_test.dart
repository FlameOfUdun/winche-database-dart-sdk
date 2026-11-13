import 'dart:async';
import 'package:test/test.dart';
import 'package:winche_database/winche_database.dart';

import 'facade_harness.dart';

Map<String, Object?> ref(String path) => {'referenceValue': path};

class Patient {
  Patient(this.name);
  final String name;
  static final converter = Converter<Patient>((m) => Patient(m['name'] as String), (p) => {'name': p.name});
}

void main() {
  late FacadeHarness h;
  setUp(() => h = FacadeHarness());
  tearDown(() => h.close());

  final visit = wireDoc('visits/v1', {
    'patient': ref('patients/p1'),
    'team': {'arrayValue': {'values': [ref('staff/a'), ref('staff/hidden')]}},
    'note': {'stringValue': 'hi'},
  });
  final patientDoc = wireDoc('patients/p1', {'name': {'stringValue': 'Ann'}, 'doctor': ref('doctors/d1')});
  final doctorV1 = wireDoc('doctors/d1', {'name': {'stringValue': 'Dr Who'}});
  final included = {
    'patients/p1': patientDoc,
    'doctors/d1': doctorV1,
    'staff/a': wireDoc('staff/a', {'name': {'stringValue': 'A'}}),
  };

  String? doctorOf(DocumentSnapshot<Map<String, Object?>> s) {
    final doctor = s.link('patient.doctor');
    if (doctor == null) return 'NO PATIENT';
    return doctor.doc?.get<String>('name') ?? 'PATH';
  }

  test('get with expand: data keeps the paths, links bring the documents', () async {
    h.handler = (f) {
      if (f['type'] == 'doc.get') h.respond(f, {'document': visit, 'included': included});
    };
    final snap = await h.db.doc('visits/v1').expand(['patient.doctor', 'team']).get();

    expect(h.requests.firstWhere((f) => f['type'] == 'doc.get')['expand'], ['patient.doctor', 'team']);
    expect(snap.data()!['patient'], 'patients/p1', reason: 'data() keeps the plain value');
    final patient = snap.link('patient')!;
    expect((patient.kind, patient.target, patient.isResolved), ('document', 'patients/p1', true));
    expect(patient.doc!.get<String>('name'), 'Ann');
    expect(patient.doc!.link('doctor')!.doc!.get<String>('name'), 'Dr Who');
    expect(snap.link('patient.doctor')!.doc!.get<String>('name'), 'Dr Who', reason: 'a dotted path crosses documents');

    final team = snap.links('team').toList();
    expect(team.map((l) => l.target), ['staff/a', 'staff/hidden']);
    expect(team[0].doc!.get<String>('name'), 'A');
    expect(team[1].isResolved, isFalse, reason: 'not readable (not included)');
    expect(team[1].docRef.path, 'staff/hidden', reason: 'still reachable');
    expect(snap.link('team'), isNull, reason: 'a list: use links()');
    expect(snap.link('note'), isNull, reason: 'not a link');
    expect(snap.get<String>('note'), 'hi');
  });

  test('a link takes a converter like a reference, or borrows one', () async {
    h.handler = (f) {
      if (f['type'] == 'doc.get') h.respond(f, {'document': visit, 'included': included});
    };
    final snap = await h.db.doc('visits/v1').expand(['patient']).get();
    final typed = snap.link('patient')!.withConverter(Patient.converter);
    expect(typed.doc!.data()!.name, 'Ann');
    expect(typed.docRef, isA<DocumentReference<Patient>>());

    final patients = h.db.collection('patients').withConverter(Patient.converter);
    expect(snap.link('patient')!.like(patients).doc!.data()!.name, 'Ann');
    final staff = snap.links('team').like(patients).toList();
    expect(staff, hasLength(2));
  });

  test('without expand, nothing extra is asked for and links are not resolved', () async {
    h.handler = (f) {
      if (f['type'] == 'doc.get') h.respond(f, {'document': visit});
    };
    final snap = await h.db.doc('visits/v1').get();
    expect(h.requests.firstWhere((f) => f['type'] == 'doc.get').containsKey('expand'), isFalse);
    expect(snap.link('patient')!.isResolved, isFalse);
    expect(snap.link('patient')!.docRef.path, 'patients/p1');
    expect(snap.included, isEmpty);
  });

  test('a query with expand expands each result, only along what was asked', () async {
    h.handler = (f) {
      if (f['type'] == 'query') h.respond(f, {'documents': [visit], 'hasMore': false, 'included': {'patients/p1': patientDoc}});
    };
    final snap = await h.db.collection('visits').where('note', isEqualTo: 'hi').expand(['patient']).get();
    expect(h.requests.firstWhere((f) => f['type'] == 'query')['expand'], ['patient']);
    final doc = snap.docs.single;
    expect(doc.link('patient')!.doc!.get<String>('name'), 'Ann');
    expect(doc.link('patient.doctor')!.isResolved, isFalse);
  });

  test('a live document follows changes to its linked documents', () async {
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
    expect(doctorOf(snaps.last), 'Dr Who');

    h.push({
      'type': 'listen.delta', 'subscriptionId': 's', 'changes': [], 'count': 1,
      'readTime': '2026-06-08T10:01:00+00:00', 'resumeToken': 2,
      'included': {'doctors/d1': wireDoc('doctors/d1', {'name': {'stringValue': 'Dr Two'}}, updateTime: '2026-06-08T10:01:00+00:00', version: 2)},
    });
    await pump();
    expect(doctorOf(snaps.last), 'Dr Two');

    h.push({
      'type': 'listen.delta', 'subscriptionId': 's', 'changes': [], 'count': 1,
      'readTime': '2026-06-08T10:02:00+00:00', 'resumeToken': 3, 'excluded': ['doctors/d1'],
    });
    await pump();
    expect(doctorOf(snaps.last), 'PATH');
    await sub.cancel();
  });

  test('a live query with expand follows linked documents', () async {
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
    expect(snaps.last.docs.single.link('patient')!.doc!.get<String>('name'), 'Ann');

    h.push({
      'type': 'listen.delta', 'subscriptionId': 'q', 'changes': [], 'count': 1,
      'readTime': '2026-06-08T10:01:00+00:00', 'resumeToken': 2,
      'included': {'patients/p1': wireDoc('patients/p1', {'name': {'stringValue': 'Annie'}}, updateTime: '2026-06-08T10:01:00+00:00', version: 2)},
    });
    await pump();
    expect(snaps.last.docs.single.link('patient')!.doc!.get<String>('name'), 'Annie');
    expect(snaps.last.docChanges, isEmpty, reason: 'the results themselves did not change');
    await sub.cancel();
  });

  test("an expanded get shows the user's own writes the server has not confirmed yet", () async {
    h.handler = (f) {
      if (f['type'] == 'doc.get') h.respond(f, {'document': null, 'included': <String, Object?>{}});
    };
    unawaited(h.db.doc('visits/new').set({'note': 'just written', 'patient': h.db.doc('patients/p1')}));
    await pump();
    final snap = await h.db.doc('visits/new').expand(['patient']).get();
    expect(snap.exists, isTrue);
    expect(snap.get<String>('note'), 'just written');
    expect(snap.metadata.hasPendingWrites, isTrue);
    expect(snap.link('patient')!.isResolved, isFalse);
  });

  group('on this device', () {
    test('an offline expanded get follows links through the cache', () async {
      var online = true;
      h.handler = (f) {
        if (f['type'] == 'doc.get') {
          if (!online) return h.respondError(f, 'UNAVAILABLE', 'down');
          h.respond(f, {'document': visit, 'included': {'patients/p1': patientDoc, 'doctors/d1': doctorV1}});
        }
      };
      final r = h.db.doc('visits/v1').expand(['patient.doctor']);
      expect(doctorOf(await r.get()), 'Dr Who');
      final cached = await r.get(const GetOptions(source: Source.cache));
      expect((cached.metadata.fromCache, doctorOf(cached)), (true, 'Dr Who'));
      online = false;
      final offline = await r.get();
      expect((offline.metadata.fromCache, doctorOf(offline)), (true, 'Dr Who'));
    });

    test('an expanded query read online is followed through the cache offline', () async {
      var online = true;
      h.handler = (f) {
        if (f['type'] == 'query') {
          if (!online) return h.respondError(f, 'UNAVAILABLE', 'down');
          h.respond(f, {'documents': [visit], 'hasMore': false, 'included': {'patients/p1': patientDoc, 'doctors/d1': doctorV1}});
        }
      };
      final q = h.db.collection('visits').expand(['patient.doctor']);
      expect(doctorOf((await q.get()).docs.single), 'Dr Who');
      online = false;
      final offline = await q.get();
      expect((offline.metadata.fromCache, doctorOf(offline.docs.single)), (true, 'Dr Who'));
    });

    test("the user's unsynced change to a linked document shows in reads and listeners at once", () async {
      h.handler = (f) {
        if (f['type'] == 'doc.get') h.respond(f, {'document': visit, 'included': {'patients/p1': patientDoc, 'doctors/d1': doctorV1}});
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
      unawaited(h.db.doc('doctors/d1').update({'name': 'Dr Local'}));
      await pump();
      expect(doctorOf(snaps.last), 'Dr Local');
      expect(doctorOf(await h.db.doc('visits/v1').expand(['patient.doctor']).get()), 'Dr Local');
      await sub.cancel();
    });
  });

  group('files and users', () {
    final withLinks = wireDoc('visits/v2', {
      'scan': {'stringValue': 'scans/a.png'},
      'other': {'stringValue': 'scans/hidden.png'},
      'patient': ref('patients/p2'),
    });
    final patient2 = wireDoc('patients/p2', {'name': {'stringValue': 'Ann'}, 'author': {'stringValue': 'u1'}});
    final scanRecord = {'path': 'scans/a.png', 'mimeType': 'image/png', 'sizeBytes': 42};

    test('kinded paths are links of their kind with what the server resolved', () async {
      h.handler = (f) {
        if (f['type'] == 'doc.get') {
          h.respond(f, {
            'document': withLinks, 'included': {'patients/p2': patient2},
            'resolved': {'file:scans/a.png': scanRecord, 'user:u1': {'uid': 'u1', 'displayName': 'Dr Lee'}},
          });
        }
      };
      final snap = await h.db.doc('visits/v2').expand(['file:scan', 'file:other', 'user:patient.author']).get();
      expect(snap.data()!['scan'], 'scans/a.png');
      final scan = snap.link('scan')!;
      expect((scan.kind, scan.target, scan.json!['sizeBytes']), ('file', 'scans/a.png', 42));
      expect(snap.link('other')!.isResolved, isFalse);
      final author = snap.link('patient.author')!;
      expect((author.kind, author.target, author.json!['displayName']), ('user', 'u1', 'Dr Lee'));
      expect(() => scan.docRef, throwsStateError);
    });

    test('live: resolved values follow the server', () async {
      h.handler = (f) {
        if (f['type'] == 'doc.listen') h.respond(f, {'subscriptionId': 's'});
      };
      final snaps = <DocumentSnapshot<Map<String, Object?>>>[];
      final sub = h.db.doc('visits/v2').expand(['file:scan']).snapshots().listen(snaps.add);
      await pump();
      h.push({
        'type': 'listen.snapshot', 'subscriptionId': 's', 'documents': [withLinks],
        'readTime': '2026-06-08T10:00:00+00:00', 'resumeToken': 1, 'included': <String, Object?>{},
        'resolved': {'file:scans/a.png': scanRecord},
      });
      await pump();
      expect(snaps.last.link('scan')!.json!['sizeBytes'], 42);
      h.push({
        'type': 'listen.delta', 'subscriptionId': 's', 'changes': [], 'count': 1,
        'readTime': '2026-06-08T10:01:00+00:00', 'resumeToken': 2,
        'resolved': {'file:scans/a.png': {...scanRecord, 'sizeBytes': 99}},
      });
      await pump();
      expect(snaps.last.link('scan')!.json!['sizeBytes'], 99);
      h.push({
        'type': 'listen.delta', 'subscriptionId': 's', 'changes': [], 'count': 1,
        'readTime': '2026-06-08T10:02:00+00:00', 'resumeToken': 3, 'unresolved': ['file:scans/a.png'],
      });
      await pump();
      expect(snaps.last.link('scan')!.isResolved, isFalse);
      await sub.cancel();
    });
  });
}
