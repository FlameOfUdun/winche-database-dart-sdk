import 'dart:async';

import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter/material.dart' as material show ConnectionState;
import 'package:winche_database/winche_database.dart';

// Hardcoded connection / identity — the sample server hard-codes uid = "user-123"
// and grants that uid full access to userData/user-123/{document=**}.
const kUri = 'ws://localhost:5183/documents/ws';
const kUid = 'user-123';
const kCollection = 'userData/$kUid/records';

void main() => runApp(const WincheDemoApp());

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
  late final _db = WincheDatabase(
    ConnectionConfig(uri: Uri.parse(kUri), autoReconnect: widget.autoConnect),
  );

  StreamSubscription<SyncEvent>? _syncSub;
  StreamSubscription<ConnectionState>? _connSub;

  List<PendingWrite> _pending = [];
  ConnectionState _connState = ConnectionState.connecting;
  bool _connecting = true;
  int _tab = 0;

  RecordFilter _filter = RecordFilter.all;

  CollectionReference<Record> get _recordsRef {
    return _db.collection(kCollection).withConverter(Record.converter);
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
      _connect();
    } else {
      _connecting = false;
    }
  }

  @override
  void dispose() {
    _syncSub?.cancel();
    _connSub?.cancel();
    _db.close();
    super.dispose();
  }

  Future<void> _connect() async {
    _syncSub = _db.syncEvents.listen((event) {
      _refreshPending();
      if (event is WriteFailed) {
        _snack('Write failed: ${event.error.status} — ${event.error.message}');
      } else if (event is WriteConflict) {
        _snack(
          'Write conflict: ${event.error.message} — discarding local write',
        );
        event.discard();
      }
    });

    _connState = _db.connectionState;
    _connSub = _db.connectionStates.listen((s) {
      if (mounted) setState(() => _connState = s);
    });
    if (mounted) setState(() => _connecting = false);
    await _refreshPending();
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
          IconButton(
            tooltip: 'Server count',
            icon: const Icon(Icons.tag),
            onPressed: _showCount,
          ),
          Center(child: _connStatusChip()),
          const SizedBox(width: 12),
        ],
      ),
      body: _connecting
          ? const Center(child: CircularProgressIndicator())
          : IndexedStack(index: _tab, children: [_recordsTab(), _pendingTab()]),
      floatingActionButton: _tab == 0
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

  Widget _recordsTab() {
    return Column(
      children: [
        _filterRow(),
        Expanded(
          child: StreamBuilder(
            // Key forces a new StreamBuilder (and fresh stream) when the filter changes.
            key: ValueKey(_filter),
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
