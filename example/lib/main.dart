import 'dart:async';

import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter/material.dart' as material show ConnectionState;
import 'package:path_provider/path_provider.dart';
import 'package:winche_core/winche_core.dart';
import 'package:winche_database/winche_database.dart';

const kUri = 'ws://localhost:5183/documents/ws';

/// The two identities this demo can sign in as.
///
/// The sample server treats the access token as the uid and its rules grant
/// `userData/{userId}/**` only to a matching `auth.uid`, so these two really do
/// see different data — which is what makes the user-switch button worth
/// pressing.
const kUsers = ['alice', 'bob'];

/// Each identity owns its own records collection.
String collectionFor(String uid) => 'userData/$uid/records';

/// A stand-in for a real auth package.
///
/// `winche_database` has no sign-in surface of its own — core defines none,
/// deliberately, because how a backend authenticates is that backend's
/// business. Some [WincheAuthService] must be registered with the app and
/// announce an identity before the database is usable.
///
/// This one has no backend to authenticate against: the token it hands out is
/// simply the uid, which the sample server accepts at face value. A real
/// implementation would exchange credentials for a signed token and announce
/// the result the same way.
final class DemoAuthService extends WincheAuthService {
  DemoAuthService(super.app);

  WincheIdentity? _identity;

  @override
  WincheIdentity? get activeIdentity => _identity;

  @override
  Future<String?> getAuthToken({bool forceRefresh = false}) async =>
      _identity?.id;

  /// Signs in as [uid]. Core tears down whatever session was running and
  /// builds a fresh one — new store, new socket, new token.
  void signIn(String uid) {
    _identity = WincheIdentity(uid);
    notifyIdentityChanged(_identity);
  }

  /// An authoritative sign-out. Core disposes the session; the facade lives on
  /// and every call throws [WincheUnboundException] until the next sign-in.
  void signOut() {
    _identity = null;
    notifyIdentityChanged(null);
  }
}

/// True on the web, where there is no filesystem and sembast uses IndexedDB.
const bool kIsWeb = identical(0, 0.0);

void main() {
  Winche.initializeApp(
    options: WincheOptions(
      databaseEndpoint: Uri.parse(kUri),
      // The *parent* directory every service keeps its state under. Core hands
      // out this root and nothing else; `winche_database` composes
      // `<root>/winche/<storageKey>/` beneath it, so alice and bob get
      // physically separate stores and neither can read the other's cache.
      //
      // Resolved lazily on first store access, so it is never called on the
      // web — there is no filesystem there, and sembast uses an IndexedDB
      // database named after the same storageKey instead.
      directoryResolver: kIsWeb
          ? null
          : () async => (await getApplicationSupportDirectory()).path,
    ),
  );
  runApp(const WincheDemoApp());
}

class WincheDemoApp extends StatelessWidget {
  const WincheDemoApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Winche Records',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true),
      home: const HomePage(),
    );
  }
}

final class Record {
  final String id;
  final String title;
  final String note;
  final bool done;

  const Record({
    required this.id,
    required this.title,
    this.note = '',
    this.done = false,
  });

  static const converter = RecordConverter();

  Record toggleDone() {
    return Record(id: id, title: title, note: note, done: !done);
  }
}

final class RecordConverter extends Converter<Record> {
  const RecordConverter() : super(_fromMap, _toMap);

  static Record _fromMap(Map<String, Object?> data) {
    return Record(
      id: data['id'] as String,
      title: data['title'] as String? ?? '',
      note: data['note'] as String? ?? '',
      done: data['done'] as bool? ?? false,
    );
  }

  static Map<String, Object?> _toMap(Record record) {
    return {
      'id': record.id,
      'title': record.title,
      'note': record.note,
      'done': record.done,
    };
  }
}

/// Which subset of records to display.
enum RecordFilter { all, active, done }

class HomePage extends StatefulWidget {
  const HomePage({super.key, this.autoConnect = true});

  /// Disabled in widget tests so no real socket is opened.
  final bool autoConnect;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  // Stands in for a real auth package — see DemoAuthService. Only ever touched
  // (and so only ever registered with the app) when this page signs in.
  late final _auth = DemoAuthService(Winche.app);

  // Persistent, so each identity gets its own on-disk store and a signed-out
  // user's cache and un-synced writes survive until they sign back in. Set
  // before the database is ever used — `config` throws once a session has
  // started.
  late final _db = WincheDatabase.instance
    ..config = WincheDatabaseConfig();

  StreamSubscription<SyncEvent>? _syncSub;
  StreamSubscription<ConnectionState>? _connSub;

  List<PendingWrite> _pending = [];
  ConnectionState _connState = ConnectionState.connecting;
  bool _connecting = true;
  int _tab = 0;

  /// Who is signed in. Null before the first sign-in and after a sign-out,
  /// when the database throws [WincheUnboundException] on use.
  String? _uid;

  RecordFilter _filter = RecordFilter.all;

  CollectionReference<Record> get _recordsRef {
    return _db
        .collection(collectionFor(_uid!))
        .withConverter(Record.converter);
  }

  /// Returns the query for the current filter.
  QueryReference<Record> get _filteredQuery {
    switch (_filter) {
      case RecordFilter.all:
        return _recordsRef.orderBy('title');
      case RecordFilter.active:
        return _recordsRef.where('done', isEqualTo: false).orderBy('title');
      case RecordFilter.done:
        return _recordsRef.where('done', isEqualTo: true).orderBy('title');
    }
  }

  @override
  void initState() {
    super.initState();
    if (widget.autoConnect) {
      _signIn(kUsers.first);
    }
    // Disabled in widget tests (autoConnect: false): nobody ever signs in, so
    // `_connecting` stays true forever and the spinner shows instead of the
    // record list — which is what keeps `.snapshots()` from ever being called
    // against an unbound database (see WincheUnboundException in the README).
  }

  @override
  void dispose() {
    _syncSub?.cancel();
    _connSub?.cancel();
    // State.dispose is sync; signing out settles the session teardown (socket,
    // store, sync controller) in the background. Only touch `_auth` if we
    // actually signed in with it, so a never-connected widget test doesn't
    // register an auth service just to sign out of nothing.
    if (widget.autoConnect) _auth.signOut();
    super.dispose();
  }

  /// Signs in as [uid], replacing whoever was signed in before.
  ///
  /// The interesting part is what this method does *not* do. Core disposes the
  /// outgoing session and builds a new one — new local store, new socket
  /// carrying the new token — so the only thing this has to do is remember who
  /// is signed in and let the record list resubscribe.
  ///
  /// `syncEvents` and `connectionStates` are subscribed once, on first sign-in,
  /// and never again: they are relays that outlive a session, so a user switch
  /// does not end them. A `snapshots()` stream is not — it completes on the
  /// switch, which is why `_recordsTab` keys its `StreamBuilder` on `_uid`.
  Future<void> _signIn(String uid) async {
    final firstSignIn = _uid == null;
    // Force `_db` into existence (registering it with the app) before
    // announcing sign-in, so the very first session dispatch already
    // includes it — see the ordering note in the README on lazy factories.
    final db = _db;

    if (mounted) setState(() => _connecting = true);
    _auth.signIn(uid);
    await Winche.app.settled;
    if (!mounted) return;
    setState(() {
      _uid = uid;
      _connecting = false;
    });

    if (!firstSignIn) {
      await _refreshPending();
      return; // the relays below are already subscribed and still live
    }

    _syncSub = db.syncEvents.listen((event) {
      _refreshPending();
      if (event is WriteFailed) {
        _snack('Write failed: ${event.error.status} — ${event.error.message}');
      } else if (event is WriteConflict) {
        _snack(
          'Write conflict: ${event.error.message} — discarding local write',
        );
        event.discard();
      } else if (event is SyncPaused) {
        // Nothing was dropped — the token is dead. A real app would refresh
        // the token in its auth service and announce the rotation there; core
        // re-dials automatically and the drain resumes on its own. This demo's
        // token is just the uid, so there is nothing to refresh.
        _snack('Sync paused (unauthenticated): ${event.error.message}');
      }
    });

    // No manual seed: `connectionStates` delivers the current state on
    // subscribe, then every change.
    _connSub = db.connectionStates.listen((s) {
      if (mounted) setState(() => _connState = s);
    });
    await _refreshPending();
  }

  /// Signs out entirely, leaving the database unbound.
  ///
  /// The facade survives — every call just throws [WincheUnboundException]
  /// until somebody signs in again. Note the relays stay subscribed: the
  /// connection chip goes to `disconnected` rather than freezing on its last
  /// value, because [StatusRelay] emits a final value on detach.
  Future<void> _signOut() async {
    // Clear `_uid` BEFORE announcing, mirroring how `_signIn` raises
    // `_connecting` before it announces.
    //
    // Core unbinds the session synchronously inside `signOut()`, and the
    // `connectionStates` listener fires in that same turn with `disconnected`.
    // Announcing first would leave a window where the session is already gone
    // but `_uid` is still set — and that rebuild takes the records branch,
    // calling `snapshots()` on an unbound database and throwing
    // `WincheUnboundException` into the widget tree. Signing out would show a
    // red error screen instead of the signed-out view.
    setState(() {
      _uid = null;
      _pending = [];
    });
    _auth.signOut();
    await Winche.app.settled;
  }

  Future<void> _refreshPending() async {
    final p = await _db.queue.all();
    if (mounted) setState(() => _pending = p);
  }

  Future<void> _runOp(String label, Future<void> Function() fn) async {
    try {
      await fn();
    } on WincheException catch (e) {
      _snack('$label failed: ${e.status}');
    } catch (e) {
      _snack('$label failed: $e');
    }
    await _refreshPending();
  }

  Future<void> _addRecord(Record r) {
    return _runOp('Add', () async {
      await _recordsRef.doc(r.id).set(r);
    });
  }

  Future<void> _deleteRecord(String id) {
    return _runOp('Delete', () async {
      await _recordsRef.doc(id).delete();
    });
  }

  /// Toggle done using field transforms so we get a server timestamp and edit
  /// count alongside the boolean flip, without overwriting the whole document.
  Future<void> _toggleDone(Record r) {
    return _runOp('Toggle', () async {
      await _recordsRef.doc(r.id).update({
        'done': !r.done,
        'updatedAt': FieldValue.serverTimestamp(),
        'edits': FieldValue.increment(1),
      });
    });
  }

  Future<void> _updateRecord(Record r) {
    return _runOp('Update', () async {
      await _recordsRef.doc(r.id).set(r, merge: true);
    });
  }

  /// Asks the server for the count of documents matching the current filter
  /// and shows the result in a SnackBar.
  Future<void> _showCount() async {
    try {
      final n = await _filteredQuery.count();
      final filterLabel = switch (_filter) {
        RecordFilter.all => 'total',
        RecordFilter.active => 'active',
        RecordFilter.done => 'done',
      };
      _snack('Server count ($filterLabel): $n');
    } on WincheException catch (e) {
      _snack('Count failed: ${e.status} — ${e.message}');
    } catch (e) {
      _snack('Count failed: $e');
    }
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(content: Text(msg), duration: const Duration(seconds: 3)),
      );
  }

  // --- editor bottom sheet ---------------------------------------------------

  Future<void> _openEditor({Record? existing}) async {
    final titleC = TextEditingController(text: existing?.title ?? '');
    final noteC = TextEditingController(text: existing?.note ?? '');
    var done = existing?.done ?? false;

    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) {
        return Padding(
          padding: EdgeInsets.only(
            left: 20,
            right: 20,
            top: 8,
            bottom: MediaQuery.of(ctx).viewInsets.bottom + 20,
          ),
          child: StatefulBuilder(
            builder: (ctx, setSheet) {
              return Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    existing == null ? 'New record' : 'Edit record',
                    style: Theme.of(ctx).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: titleC,
                    autofocus: true,
                    textCapitalization: TextCapitalization.sentences,
                    decoration: const InputDecoration(
                      labelText: 'Title',
                      border: OutlineInputBorder(),
                    ),
                    onChanged: (value) {
                      setSheet(() {});
                    },
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: noteC,
                    minLines: 2,
                    maxLines: 4,
                    decoration: const InputDecoration(
                      labelText: 'Note',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 4),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Done'),
                    value: done,
                    onChanged: (v) => setSheet(() => done = v),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton(
                        onPressed: () => Navigator.pop(ctx, false),
                        child: const Text('Cancel'),
                      ),
                      const SizedBox(width: 8),
                      FilledButton(
                        onPressed: titleC.text.trim().isEmpty
                            ? null
                            : () => Navigator.pop(ctx, true),
                        child: const Text('Save'),
                      ),
                    ],
                  ),
                ],
              );
            },
          ),
        );
      },
    );

    if (saved == true && titleC.text.trim().isNotEmpty) {
      if (existing == null) {
        final newRecord = Record(
          id: DateTime.now().millisecondsSinceEpoch.toString(),
          title: titleC.text.trim(),
          note: noteC.text.trim(),
          done: done,
        );
        await _addRecord(newRecord);
      } else {
        final updated = Record(
          id: existing.id,
          title: titleC.text.trim(),
          note: noteC.text.trim(),
          done: done,
        );
        await _updateRecord(updated);
      }
    }
    titleC.dispose();
    noteC.dispose();
  }

  // --- UI --------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Winche Records'),
        actions: [
          if (_uid != null) ...[
            _userSwitcher(),
            const SizedBox(width: 8),
            IconButton(
              tooltip: 'Server count',
              icon: const Icon(Icons.tag),
              onPressed: _showCount,
            ),
          ],
          Center(child: _connStatusChip()),
          const SizedBox(width: 12),
        ],
      ),
      body: _connecting
          ? const Center(child: CircularProgressIndicator())
          : _uid == null
          ? _signedOut()
          : IndexedStack(index: _tab, children: [_recordsTab(), _pendingTab()]),
      floatingActionButton: _tab == 0 && _uid != null
          ? FloatingActionButton.extended(
              onPressed: () => _openEditor(),
              icon: const Icon(Icons.add),
              label: const Text('Add'),
            )
          : null,
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) {
          setState(() => _tab = i);
          if (i == 1) _refreshPending();
        },
        destinations: [
          const NavigationDestination(
            icon: Icon(Icons.list_alt),
            label: 'Records',
          ),
          NavigationDestination(
            icon: Badge(
              isLabelVisible: _pending.isNotEmpty,
              label: Text('${_pending.length}'),
              child: const Icon(Icons.sync_problem),
            ),
            label: 'Pending',
          ),
        ],
      ),
    );
  }

  /// Switches identity, or signs out.
  ///
  /// The whole point of the demo: each user sees only their own records,
  /// enforced by the server's rules, and core swaps the session underneath
  /// without this widget tearing anything down itself.
  Widget _userSwitcher() {
    // The menu value is a record, not a bare `String?`, and that is not
    // decoration: PopupMenuButton treats a *null* selection as a cancellation
    // and calls `onCanceled` instead of `onSelected`, so a "Sign out" item with
    // `value: null` silently does nothing. `(uid: null)` is a non-null record
    // that still says "no user".
    return PopupMenuButton<({String? uid})>(
      tooltip: 'Signed in as $_uid',
      onSelected: (choice) =>
          choice.uid == null ? _signOut() : _signIn(choice.uid!),
      itemBuilder: (context) => [
        for (final u in kUsers)
          PopupMenuItem<({String? uid})>(
            value: (uid: u),
            enabled: u != _uid,
            child: Row(
              children: [
                Icon(
                  u == _uid ? Icons.check : Icons.person_outline,
                  size: 18,
                ),
                const SizedBox(width: 8),
                Text(u),
              ],
            ),
          ),
        const PopupMenuDivider(),
        const PopupMenuItem<({String? uid})>(
          value: (uid: null),
          child: Row(
            children: [
              Icon(Icons.logout, size: 18),
              SizedBox(width: 8),
              Text('Sign out'),
            ],
          ),
        ),
      ],
      child: Chip(
        avatar: const Icon(Icons.person, size: 18),
        label: Text(_uid ?? ''),
        visualDensity: VisualDensity.compact,
      ),
    );
  }

  /// Shown while nobody is signed in — the state where every database call
  /// throws [WincheUnboundException].
  Widget _signedOut() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.lock_outline,
            size: 48,
            color: Theme.of(context).colorScheme.outline,
          ),
          const SizedBox(height: 12),
          Text('Signed out', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(
            'The database is unbound — every call throws\n'
            'WincheUnboundException until somebody signs in.',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            children: [
              for (final u in kUsers)
                FilledButton.tonal(
                  onPressed: () => _signIn(u),
                  child: Text('Sign in as $u'),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _recordsTab() {
    return Column(
      children: [
        _filterRow(),
        Expanded(
          child: StreamBuilder(
            // Keyed on the user as well as the filter, and the user half is
            // load-bearing: a `snapshots()` stream *completes* when core swaps
            // the session, by design — a widget built for alice must not
            // silently start showing bob's rows. Rebuilding the StreamBuilder
            // is how the app resubscribes against the new session.
            key: ValueKey((_uid, _filter)),
            stream: _filteredQuery.snapshots(),
            builder: (context, snapshot) {
              if (snapshot.connectionState ==
                  material.ConnectionState.waiting) {
                return const Center(child: CircularProgressIndicator());
              }
              if (snapshot.hasError) {
                return _empty(
                  Icons.error_outline,
                  'Error loading records',
                  snapshot.error.toString(),
                );
              }
              final records = snapshot.data!.docs;
              if (records.isEmpty) {
                return _empty(
                  Icons.inbox,
                  'No records yet',
                  'Tap "Add" to create your first record.',
                );
              }
              return ListView.separated(
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 96),
                itemCount: records.length,
                separatorBuilder: (_, _) => const SizedBox(height: 8),
                itemBuilder: (context, i) => _recordTile(records[i]),
              );
            },
          ),
        ),
      ],
    );
  }

  /// Filter chip row — All / Active / Done.
  Widget _filterRow() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          for (final f in RecordFilter.values) ...[
            FilterChip(
              label: Text(switch (f) {
                RecordFilter.all => 'All',
                RecordFilter.active => 'Active',
                RecordFilter.done => 'Done',
              }),
              selected: _filter == f,
              onSelected: (_) => setState(() => _filter = f),
            ),
            if (f != RecordFilter.done) const SizedBox(width: 8),
          ],
        ],
      ),
    );
  }

  Widget _recordTile(DocumentSnapshot<Record> snapshot) {
    final r = snapshot.data()!;
    return Card(
      margin: EdgeInsets.zero,
      child: ListTile(
        onTap: () => _openEditor(existing: r),
        leading: Checkbox(value: r.done, onChanged: (_) => _toggleDone(r)),
        title: Text(
          r.title,
          style: TextStyle(
            decoration: r.done ? TextDecoration.lineThrough : null,
            color: r.done ? Theme.of(context).disabledColor : null,
          ),
        ),
        subtitle: r.note.isEmpty ? null : Text(r.note),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (snapshot.metadata.fromCache)
              const Icon(Icons.offline_bolt, size: 18, color: Colors.orange),
            IconButton(
              icon: const Icon(Icons.delete_outline),
              onPressed: () => _deleteRecord(r.id),
            ),
          ],
        ),
      ),
    );
  }

  Widget _pendingTab() {
    return Column(
      children: [
        ListTile(
          leading: const Icon(Icons.sync),
          title: Text('${_pending.length} queued'),
          subtitle: const Text(
            'Writes queue locally and sync automatically while connected.',
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: _pending.isEmpty
              ? _empty(
                  Icons.check_circle_outline,
                  'All synced',
                  'No pending writes. Disconnect the server to see writes queue.',
                )
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                  itemCount: _pending.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 8),
                  itemBuilder: (context, i) => _pendingTile(_pending[i]),
                ),
        ),
      ],
    );
  }

  Widget _pendingTile(PendingWrite entry) {
    final op = entry.kind.name.toUpperCase();
    final path = entry.path.split('/').last;
    final seq = entry.seq;
    final (icon, color) = switch (op) {
      'set' => (Icons.save, Colors.blue),
      'update' => (Icons.edit, Colors.teal),
      'delete' => (Icons.delete, Colors.red),
      _ => (Icons.help_outline, Colors.grey),
    };
    return Card(
      margin: EdgeInsets.zero,
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: color.withValues(alpha: 0.15),
          child: Icon(icon, color: color, size: 20),
        ),
        title: Text('$op  •  #$seq'),
        subtitle: Text(path),
        trailing: const Icon(Icons.hourglass_bottom, size: 18),
      ),
    );
  }

  /// A live indicator of the actual socket state (distinct from the logical
  /// online/offline toggle), driven by `db.connectionStates`.
  Widget _connStatusChip() {
    final (label, color, spin) = switch (_connState) {
      ConnectionState.ready => ('live', Colors.green, false),
      ConnectionState.connecting => ('connecting', Colors.orange, true),
      ConnectionState.reconnecting => ('reconnecting', Colors.orange, true),
      ConnectionState.disconnected => ('offline', Colors.red, false),
      ConnectionState.closed => ('closed', Colors.grey, false),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (spin)
            SizedBox(
              width: 10,
              height: 10,
              child: CircularProgressIndicator(strokeWidth: 2, color: color),
            )
          else
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
          const SizedBox(width: 6),
          Text(label, style: TextStyle(color: color, fontSize: 12)),
        ],
      ),
    );
  }

  Widget _empty(IconData icon, String title, String subtitle) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 56, color: Theme.of(context).disabledColor),
          const SizedBox(height: 12),
          Text(title, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 40),
            child: Text(
              subtitle,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}
