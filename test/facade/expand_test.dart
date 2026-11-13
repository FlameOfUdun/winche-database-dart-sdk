import 'dart:async';
import 'package:test/test.dart';
import 'package:winche_database/winche_database.dart';

import 'facade_harness.dart';

Map<String, Object?> ref(String path) => {'referenceValue': path};

class Patient {
  Patient.fromMap(Map<String, Object?> m) : name = m['name'] as String, doctor = m['doctor'] as Link?;
  final String name;
  final Link? doctor;
  static final converter = Converter<Patient>(Patient.fromMap, (p) => {'name': p.name, 'doctor': p.doctor});
}

class Visit {
  Visit.fromMap(Map<String, Object?> m)
      : note = m['note'] as String,
        patient = (m['patient'] as Link).withConverter(Patient.converter),
        scan = Link.from(m['scan'], LinkKind.file);
  final String note;
  final Link<Patient> patient;
  final Link? scan;
  Map<String, Object?> toMap() => {'note': note, 'patient': patient, if (scan != null) 'scan': scan};
  static final converter = Converter<Visit>(Visit.fromMap, (v) => v.toMap());
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
    final patient = (s.data()!['patient'] as Link).data();
    if (patient == null) return 'NO PATIENT';
    return (patient['doctor'] as Link).data()?['name'] as String? ?? 'PATH';
  }

  test('get with expand: references are links, with data when expanded', () async {
    h.handler = (f) {
      if (f['type'] == 'doc.get') h.respond(f, {'document': visit, 'included': included});
    };
    final snap = await h.db.doc('visits/v1').expand(['patient.doctor', 'team']).get();

    expect(h.requests.firstWhere((f) => f['type'] == 'doc.get')['expand'], ['patient.doctor', 'team']);
    final data = snap.data()!;
    final patient = data['patient'] as Link;
    expect((patient.kind, patient.target), (LinkKind.document, 'patients/p1'));
    expect(patient.data()!['name'], 'Ann');
    expect((patient.data()!['doctor'] as Link).data()!['name'], 'Dr Who');
    final team = (data['team'] as List).cast<Link>();
    expect(team.map((l) => l.target), ['staff/a', 'staff/hidden']);
    expect(team[0].data()!['name'], 'A');
    expect(team[1].data(), isNull, reason: 'not readable (not included): no data, still a target');
    expect(data['note'], 'hi');
    expect(snap.get<String>('note'), 'hi');
  });

  test('links and snapshots take converters; a model writes its links back as targets', () async {
    h.handler = (f) {
      if (f['type'] == 'doc.get') h.respond(f, {'document': visit, 'included': included});
      if (f['type'] == 'write') h.respond(f, {'writeResults': [{'updateTime': '2026-06-08T10:00:00Z'}]});
    };
    final snap = await h.db.doc('visits/v1').expand(['patient.doctor']).get();
    final patient = (snap.data()!['patient'] as Link).withConverter(Patient.converter);
    expect(patient.data()!.name, 'Ann');
    expect(patient.data()!.doctor!.data()!['name'], 'Dr Who');

    final typed = snap.withConverter(Visit.converter);
    expect(typed.reference, isA<DocumentReference<Visit>>());
    final model = typed.data()!;
    expect((model.note, model.patient.data()!.name), ('hi', 'Ann'));

    unawaited(h.db.doc('visits/copy').withConverter(Visit.converter).set(model));
    await pump(20);   // the write goes out from the queue
    final write = h.requests.lastWhere((f) => f['type'] == 'write');
    final fields = ((write['writes'] as List).single as Map)['set']['fields'] as Map;
    expect(fields['patient'], {'referenceValue': 'patients/p1'}, reason: 'the target, not the data');
  });

  test('without expand, references are links without data', () async {
    h.handler = (f) {
      if (f['type'] == 'doc.get') h.respond(f, {'document': visit});
    };
    final snap = await h.db.doc('visits/v1').get();
    expect(h.requests.firstWhere((f) => f['type'] == 'doc.get').containsKey('expand'), isFalse);
    final patient = snap.data()!['patient'] as Link;
    expect((patient.target, patient.data()), ('patients/p1', null));
  });

  test('a query with expand expands each result, only along what was asked', () async {
    h.handler = (f) {
      if (f['type'] == 'query') h.respond(f, {'documents': [visit], 'hasMore': false, 'included': {'patients/p1': patientDoc}});
    };
    final snap = await h.db.collection('visits').where('note', isEqualTo: 'hi').expand(['patient']).get();
    expect(h.requests.firstWhere((f) => f['type'] == 'query')['expand'], ['patient']);
    final patient = (snap.docs.single.data()!['patient'] as Link).data()!;
    expect(patient['name'], 'Ann');
    expect((patient['doctor'] as Link).data(), isNull, reason: 'only "patient" was expanded');
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
    String? patientName() => (snaps.last.docs.single.data()!['patient'] as Link).data()?['name'] as String?;
    expect(patientName(), 'Ann');

    h.push({
      'type': 'listen.delta', 'subscriptionId': 'q', 'changes': [], 'count': 1,
      'readTime': '2026-06-08T10:01:00+00:00', 'resumeToken': 2,
      'included': {'patients/p1': wireDoc('patients/p1', {'name': {'stringValue': 'Annie'}}, updateTime: '2026-06-08T10:01:00+00:00', version: 2)},
    });
    await pump();
    expect(patientName(), 'Annie');
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
    expect((snap.data()!['patient'] as Link).data(), isNull);
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

    test('file: and user: fields are links when expanded, plain strings otherwise', () async {
      h.handler = (f) {
        if (f['type'] == 'doc.get') {
          h.respond(f, {
            'document': withLinks, 'included': {'patients/p2': patient2},
            'resolved': {'file:scans/a.png': scanRecord, 'user:u1': {'uid': 'u1', 'displayName': 'Dr Lee'}},
          });
        }
      };
      final snap = await h.db.doc('visits/v2').expand(['file:scan', 'file:other', 'user:patient.author']).get();
      final data = snap.data()!;
      final scan = data['scan'] as Link;
      expect((scan.kind, scan.target, scan.data()!['sizeBytes']), (LinkKind.file, 'scans/a.png', 42));
      expect((data['other'] as Link).data(), isNull, reason: 'expanded but hidden or missing');
      final author = (data['patient'] as Link).data()!['author'] as Link;
      expect((author.kind, author.data()!['displayName']), (LinkKind.user, 'Dr Lee'));

      final plain = await h.db.doc('visits/v2').expand(['patient']).get();
      expect(plain.data()!['scan'], 'scans/a.png', reason: 'not expanded as file: a plain string');
      expect(Link.from(plain.data()!['scan'], LinkKind.file)!.target, 'scans/a.png');
      expect(Link.from(scan, LinkKind.file)!.data()!['sizeBytes'], 42);
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
      int? size() => (snaps.last.data()!['scan'] as Link).data()?['sizeBytes'] as int?;
      expect(size(), 42);
      h.push({
        'type': 'listen.delta', 'subscriptionId': 's', 'changes': [], 'count': 1,
        'readTime': '2026-06-08T10:01:00+00:00', 'resumeToken': 2,
        'resolved': {'file:scans/a.png': {...scanRecord, 'sizeBytes': 99}},
      });
      await pump();
      expect(size(), 99);
      h.push({
        'type': 'listen.delta', 'subscriptionId': 's', 'changes': [], 'count': 1,
        'readTime': '2026-06-08T10:02:00+00:00', 'resumeToken': 3, 'unresolved': ['file:scans/a.png'],
      });
      await pump();
      expect(size(), isNull);
      await sub.cancel();
    });
  });
}
