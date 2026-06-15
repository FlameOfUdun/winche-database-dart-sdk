import 'package:test/test.dart';
import 'package:winche_database/src/protocol/exceptions.dart';
import 'package:winche_database/src/protocol/messages.dart';
import 'package:winche_database/src/core/values.dart';
import 'package:winche_database/src/protocol/writes.dart';
import 'package:winche_database/src/protocol/query_spec.dart';

void main() {
  test('WireDocument.fromAny returns null for null and parses a map', () {
    expect(WireDocument.fromAny(null), isNull);
    final raw = {
      'path': 'c/a',
      'id': 'a',
      'collection': 'c',
      'fields': <String, Object?>{},
      'createTime': 't',
      'updateTime': 't',
      'version': 0,
    };
    final doc = WireDocument.fromAny(raw);
    expect(doc, isNotNull);
    expect(doc!.path, 'c/a');
  });

  // ---------------------------------------------------------------------------
  // Client frame builders — PROTOCOL §8
  // ---------------------------------------------------------------------------
  group('Client frame builders', () {
    test('pingFrame', () {
      final f = pingFrame('6');
      expect(f['type'], equals('ping'));
      expect(f['id'], equals('6'));
    });

    test('docGetFrame', () {
      final f = docGetFrame('1', 'users/u1');
      expect(f['type'], equals('doc.get'));
      expect(f['path'], equals('users/u1'));
    });

    test('docGetAllFrame', () {
      final f = docGetAllFrame('2', ['users/u1', 'users/u2']);
      expect(f['type'], equals('doc.getAll'));
      expect(f['paths'], equals(['users/u1', 'users/u2']));
    });

    test('queryFrame', () {
      final f = queryFrame('3', QuerySpec('users'));
      expect(f['type'], equals('query'));
      expect(
          (f['query'] as Map<String, Object?>)['collection'], equals('users'));
    });

    test('countFrame builds a count message', () {
      final spec = QuerySpec('users',
          where: FilterSpec.field('score', FieldOp.gte, IntegerValue(50)));
      final frame = countFrame('7', spec);
      expect(frame['type'], 'count');
      expect(frame['id'], '7');
      expect(frame['query'], spec.toJson());
    });

    test('writeFrame — PROTOCOL §8.4 write example', () {
      final f = writeFrame('5', [
        SetWrite('users/u1', {'name': StringValue('Alice')}),
        UpdateWrite('users/u2', {'active': BooleanValue(false)}),
        DeleteWrite('users/u3'),
      ]);
      expect(f['type'], equals('write'));
      final writes = f['writes'] as List<Object?>;
      expect(writes.length, equals(3));
      expect((writes[0] as Map<String, Object?>).containsKey('set'), isTrue);
      expect((writes[1] as Map<String, Object?>).containsKey('update'), isTrue);
      expect((writes[2] as Map<String, Object?>).containsKey('delete'), isTrue);
    });

    test('txBeginFrame', () {
      expect(txBeginFrame('t1')['type'], equals('tx.begin'));
    });

    test('txGetFrame', () {
      final f = txGetFrame('t2', 'abc123', 'users/u1');
      expect(f['type'], equals('tx.get'));
      expect(f['transactionId'], equals('abc123'));
      expect(f['path'], equals('users/u1'));
    });

    test('txQueryFrame', () {
      final f = txQueryFrame('t3', 'abc123', QuerySpec('users'));
      expect(f['type'], equals('tx.query'));
      expect(f['transactionId'], equals('abc123'));
    });

    test('txCommitFrame', () {
      final f = txCommitFrame('t4', 'abc123', [
        SetWrite('users/u1', {'score': IntegerValue(99)}),
      ]);
      expect(f['type'], equals('tx.commit'));
      expect((f['writes'] as List<Object?>).length, equals(1));
    });

    test('txRollbackFrame', () {
      final f = txRollbackFrame('t5', 'abc123');
      expect(f['type'], equals('tx.rollback'));
      expect(f['transactionId'], equals('abc123'));
    });

    test('listenFrame — no resumeToken', () {
      final f = listenFrame('s1', QuerySpec('users'));
      expect(f['type'], equals('listen'));
      expect(f.containsKey('resumeToken'), isFalse);
    });

    test('listenFrame — with resumeToken', () {
      final f = listenFrame('s1', QuerySpec('users'), resumeToken: 42);
      expect(f['resumeToken'], equals(42));
    });

    test('unlistenFrame', () {
      final f = unlistenFrame('s2', 'sub-xyz');
      expect(f['type'], equals('unlisten'));
      expect(f['subscriptionId'], equals('sub-xyz'));
    });
  });

  // ---------------------------------------------------------------------------
  // ServerFrame.parse — golden frames from PROTOCOL §8
  // ---------------------------------------------------------------------------
  group('ServerFrame.parse', () {
    test('welcome frame', () {
      final frame = ServerFrame.parse({
        'type': 'welcome',
        'connectionId': 'a1b2c3',
        'protocol': 3,
      });
      expect(frame, isA<WelcomeFrame>());
      final welcome = frame as WelcomeFrame;
      expect(welcome.connectionId, equals('a1b2c3'));
      expect(welcome.protocol, equals(3));
    });

    test('WelcomeFrame parses with no protocol field (backend shape)', () {
      final frame =
          ServerFrame.parse({'type': 'welcome', 'connectionId': 'abc'});
      expect(frame, isA<WelcomeFrame>());
      expect((frame as WelcomeFrame).connectionId, 'abc');
      expect(frame.protocol, isNull);
    });

    test('response frame', () {
      final frame = ServerFrame.parse({
        'type': 'response',
        'id': 'req-42',
        'result': {'document': null},
      });
      expect(frame, isA<ResponseFrame>());
      final resp = frame as ResponseFrame;
      expect(resp.id, equals('req-42'));
    });

    test('error frame with id', () {
      final frame = ServerFrame.parse({
        'type': 'error',
        'id': 'req-42',
        'status': 'NOT_FOUND',
        'message': "Document 'users/u99' does not exist.",
        'details': null,
      });
      expect(frame, isA<ErrorFrame>());
      final err = frame as ErrorFrame;
      expect(err.id, equals('req-42'));
      expect(err.status, equals('NOT_FOUND'));
    });

    test('error frame without id (handshake error)', () {
      final frame = ServerFrame.parse({
        'type': 'error',
        'status': 'UNAUTHENTICATED',
        'message': 'Token rejected.',
      });
      expect(frame, isA<ErrorFrame>());
      expect((frame as ErrorFrame).id, isNull);
    });

    test('listen.snapshot frame — PROTOCOL §8.6', () {
      final frame = ServerFrame.parse({
        'type': 'listen.snapshot',
        'subscriptionId': 'sub-xyz',
        'documents': [
          {
            'path': 'users/u1',
            'id': 'u1',
            'collection': 'users',
            'fields': {
              'name': <String, Object?>{'stringValue': 'Alice'}
            },
            'createTime': '2026-06-07T10:00:00+00:00',
            'updateTime': '2026-06-07T10:05:00+00:00',
            'version': 3,
          },
        ],
        'readTime': '2026-06-07T12:00:00+00:00',
        'resumeToken': 57,
      });
      expect(frame, isA<ListenSnapshotFrame>());
      final snap = frame as ListenSnapshotFrame;
      expect(snap.subscriptionId, equals('sub-xyz'));
      expect(snap.documents.length, equals(1));
      expect(snap.resumeToken, equals(57));
    });

    test('listen.delta frame — PROTOCOL §8.6', () {
      final frame = ServerFrame.parse({
        'type': 'listen.delta',
        'subscriptionId': 'sub-xyz',
        'changes': [
          {
            'kind': 'added',
            'document': {
              'path': 'users/u1',
              'id': 'u1',
              'collection': 'users',
              'fields': <String, Object?>{},
              'createTime': '2026-06-07T10:00:00+00:00',
              'updateTime': '2026-06-07T10:00:00+00:00',
              'version': 1,
            },
            'oldIndex': -1,
            'newIndex': 1,
          },
        ],
        'count': 3,
        'readTime': '2026-06-07T12:00:01+00:00',
        'resumeToken': 58,
      });
      expect(frame, isA<ListenDeltaFrame>());
      final delta = frame as ListenDeltaFrame;
      expect(delta.count, equals(3));
      expect(delta.changes[0].kind, equals(ChangeKind.added));
      expect(delta.changes[0].oldIndex, equals(-1));
      expect(delta.changes[0].newIndex, equals(1));
    });

    test('unknown frame type returns UnknownFrame', () {
      final frame = ServerFrame.parse({'type': 'future.type', 'data': 42});
      expect(frame, isA<UnknownFrame>());
      expect((frame as UnknownFrame).type, equals('future.type'));
    });

    test('missing type throws FormatException', () {
      expect(() => ServerFrame.parse({'data': 42}), throwsFormatException);
    });

    test('I4 — response frame with numeric id throws FormatException', () {
      // numeric id instead of String: parse must throw FormatException, not TypeError
      expect(
        () => ServerFrame.parse({
          'type': 'response',
          'id': 42, // numeric, not String
          'result': <String, Object?>{},
        }),
        throwsFormatException,
      );
    });

    test('I4 — error frame with missing message throws FormatException', () {
      expect(
        () => ServerFrame.parse({
          'type': 'error',
          'id': 'req-1',
          'status': 'NOT_FOUND',
          // 'message' is missing
        }),
        throwsFormatException,
      );
    });

    test('Minor 9 — WireChange.kind is ChangeKind enum', () {
      final frame = ServerFrame.parse({
        'type': 'listen.delta',
        'subscriptionId': 'sub-xyz',
        'changes': [
          {
            'kind': 'added',
            'document': {
              'path': 'users/u1',
              'id': 'u1',
              'collection': 'users',
              'fields': <String, Object?>{},
              'createTime': '2026-06-07T10:00:00+00:00',
              'updateTime': '2026-06-07T10:00:00+00:00',
              'version': 1,
            },
            'oldIndex': -1,
            'newIndex': 1,
          },
        ],
        'count': 3,
        'readTime': '2026-06-07T12:00:01+00:00',
        'resumeToken': 58,
      }) as ListenDeltaFrame;
      expect(frame.changes[0].kind, equals(ChangeKind.added));
    });

    test('Minor 9 — unknown kind string throws FormatException', () {
      expect(
        () => WireChange.fromJson({
          'kind': 'replaced', // unknown
          'document': {
            'path': 'a/b',
            'id': 'b',
            'collection': 'a',
            'fields': <String, Object?>{},
            'createTime': '2026-06-07T10:00:00+00:00',
            'updateTime': '2026-06-07T10:00:00+00:00',
            'version': 1,
          },
          'oldIndex': 0,
          'newIndex': 0,
        }),
        throwsFormatException,
      );
    });

    test('Minor 6 — listen.snapshot resumeToken is typed as int', () {
      final frame = ServerFrame.parse({
        'type': 'listen.snapshot',
        'subscriptionId': 'sub-1',
        'documents': <Object?>[],
        'readTime': '2026-06-07T12:00:00+00:00',
        'resumeToken': 99,
      }) as ListenSnapshotFrame;
      expect(frame.resumeToken, isA<int>());
      expect(frame.resumeToken, equals(99));
    });

    test('I4 — welcome frame with string protocol throws FormatException', () {
      // protocol is a string instead of num — should throw FormatException
      expect(
        () => ServerFrame.parse({
          'type': 'welcome',
          'connectionId': 'c1',
          'protocol': 'three', // wrong type
        }),
        throwsFormatException,
      );
    });
  });

  // ---------------------------------------------------------------------------
  // WireDocument — PROTOCOL §2.1
  // ---------------------------------------------------------------------------
  group('WireDocument', () {
    test('parse document — PROTOCOL §2.1 example', () {
      final doc = WireDocument.fromJson({
        'path': 'users/u1',
        'id': 'u1',
        'collection': 'users',
        'fields': {
          'name': <String, Object?>{'stringValue': 'Alice'},
          'score': <String, Object?>{'integerValue': '42'},
        },
        'createTime': '2026-06-07T10:00:00+00:00',
        'updateTime': '2026-06-07T10:05:00+00:00',
        'version': 3,
      });
      expect(doc.path, equals('users/u1'));
      expect(doc.id, equals('u1'));
      expect(doc.fields['name'], equals(StringValue('Alice')));
      expect(doc.fields['score'], equals(IntegerValue(42)));
      expect(doc.createTime, equals('2026-06-07T10:00:00+00:00'));
      expect(doc.updatedAt, equals(DateTime.utc(2026, 6, 7, 10, 5)));
    });

    test('metadata time parsing of 1970-01-01T00:00:00+00:00', () {
      final doc = WireDocument.fromJson({
        'path': 'a/b',
        'id': 'b',
        'collection': 'a',
        'fields': <String, Object?>{},
        'createTime': '1970-01-01T00:00:00+00:00',
        'updateTime': '1970-01-01T00:00:00+00:00',
        'version': 1,
      });
      expect(doc.createdAt, equals(DateTime.utc(1970)));
      expect(doc.updatedAt, equals(DateTime.utc(1970)));
    });

    test('raw createTime/updateTime strings preserved exactly', () {
      const raw = '2026-06-07T10:05:00.001+00:00';
      final doc = WireDocument.fromJson({
        'path': 'a/b',
        'id': 'b',
        'collection': 'a',
        'fields': <String, Object?>{},
        'createTime': raw,
        'updateTime': raw,
        'version': 1,
      });
      expect(doc.createTime, equals(raw));
      expect(doc.updateTime, equals(raw));
    });
  });

  // ---------------------------------------------------------------------------
  // WincheException factory — PROTOCOL §6.1 status mapping
  // ---------------------------------------------------------------------------
  group('WincheException.fromError', () {
    test('ABORTED → AbortedException', () {
      expect(
        WincheException.fromError('ABORTED', 'conflict'),
        isA<AbortedException>(),
      );
    });

    test('PERMISSION_DENIED → PermissionDeniedException', () {
      expect(
        WincheException.fromError('PERMISSION_DENIED', 'denied'),
        isA<PermissionDeniedException>(),
      );
    });

    test('UNAUTHENTICATED → UnauthenticatedException', () {
      expect(
        WincheException.fromError('UNAUTHENTICATED', 'bad token'),
        isA<UnauthenticatedException>(),
      );
    });

    test('INVALID_QUERY → InvalidQueryException', () {
      final ex = WincheException.fromError(
        'INVALID_QUERY',
        'Unknown operator',
        {'jsonPath': r'$.where.op'},
      );
      expect(ex, isA<InvalidQueryException>());
      expect((ex as InvalidQueryException).jsonPath, equals(r'$.where.op'));
    });

    test('INVALID_QUERY with code → InvalidQueryException.code', () {
      final ex = WincheException.fromError(
        'INVALID_QUERY',
        'orderBy field missing',
        {'code': 'ORDERBY_FIELD_NOT_FILTERED'},
      );
      expect((ex as InvalidQueryException).code,
          equals('ORDERBY_FIELD_NOT_FILTERED'));
    });

    test('UNAVAILABLE → UnavailableException', () {
      expect(
        WincheException.fromError('UNAVAILABLE', 'down'),
        isA<UnavailableException>(),
      );
    });

    // Remaining protocol statuses map to their typed subclasses
    // (see exceptions_test.dart for the full matrix).
    test('NOT_FOUND → NotFoundException', () {
      final ex = WincheException.fromError('NOT_FOUND', 'missing');
      expect(ex, isA<NotFoundException>());
      expect(ex.status, equals('NOT_FOUND'));
    });

    test('ALREADY_EXISTS → AlreadyExistsException', () {
      expect(WincheException.fromError('ALREADY_EXISTS', 'exists'),
          isA<AlreadyExistsException>());
    });

    test('FAILED_PRECONDITION → FailedPreconditionException', () {
      expect(WincheException.fromError('FAILED_PRECONDITION', 'mismatch'),
          isA<FailedPreconditionException>());
    });

    test('DEADLINE_EXCEEDED → DeadlineExceededException', () {
      expect(WincheException.fromError('DEADLINE_EXCEEDED', 'timeout'),
          isA<DeadlineExceededException>());
    });

    test('INTERNAL → InternalException', () {
      expect(WincheException.fromError('INTERNAL', 'bug'),
          isA<InternalException>());
    });

    test('INVALID_ARGUMENT → InvalidArgumentException', () {
      expect(WincheException.fromError('INVALID_ARGUMENT', 'bad'),
          isA<InvalidArgumentException>());
    });
  });

  // ---------------------------------------------------------------------------
  // ErrorFrame.toException
  // ---------------------------------------------------------------------------
  test('ErrorFrame.toException maps to correct subclass', () {
    final frame = ErrorFrame(
      id: 't4',
      status: 'ABORTED',
      message: 'Transaction conflict.',
    );
    expect(frame.toException(), isA<AbortedException>());
  });
}
