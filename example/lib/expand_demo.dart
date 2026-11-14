import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:winche_database/winche_database.dart';

/// The Expand tab: a visit whose `patient` field references a patient, whose
/// `doctor` field references a doctor, and whose `team` lists staff — one of
/// them someone else's, which the rules don't let this user read. The visit
/// also links files (`scan`, `attachments`) and users (`author`, and the
/// doctor's `account`, two references away).
///
/// The visit is listened to with `expand([...])`: expanded documents arrive as
/// green cards, files blue, users purple, and links without data (not
/// expanded, missing, or hidden) grey chips with their target. Changing a
/// referenced document, even two references away, makes the listener emit
/// again, though the visit itself never changed.
///
/// The sample server resolves files and users from a fixed list (it has no
/// Winche.Storage or Winche Auth): `scans/chest-xray.png` and `scans/ecg.pdf`
/// exist, `private/notes.txt` is hidden from everyone, and alice and bob have
/// profiles.
class ExpandDemo extends StatefulWidget {
  const ExpandDemo({super.key, required this.db, required this.uid, required this.otherUid});

  final WincheDatabase db;
  final String uid;

  /// Someone else, whose staff record this user can't read.
  final String otherUid;

  @override
  State<ExpandDemo> createState() => _ExpandDemoState();
}

class _ExpandDemoState extends State<ExpandDemo> {
  static const _paths = ['patient.doctor.account', 'team', 'scan', 'attachments', 'author'];
  static final _rng = Random();

  bool _expand = true;
  int _emissions = 0;
  String? _error;

  String get _base => 'userData/${widget.uid}';
  DocumentReference<Map<String, Object?>> get _visit => widget.db.doc('$_base/visits/demo');
  DocumentReference<Map<String, Object?>> get _patient => widget.db.doc('$_base/patients/demo');
  DocumentReference<Map<String, Object?>> get _doctor => widget.db.doc('$_base/doctors/demo');
  DocumentReference<Map<String, Object?>> get _nurse => widget.db.doc('$_base/staff/nurse');
  DocumentReference<Map<String, Object?>> get _theirs => widget.db.doc('userData/${widget.otherUid}/staff/nurse');

  Stream<DocumentSnapshot<Map<String, Object?>>>? _stream;

  @override
  void initState() {
    super.initState();
    _listen();
  }

  @override
  void didUpdateWidget(ExpandDemo old) {
    super.didUpdateWidget(old);
    if (old.uid != widget.uid) _listen();
  }

  void _listen() {
    _emissions = 0;
    _stream = (_expand ? _visit.expand(_paths) : _visit).snapshots().map((s) {
      _emissions++;
      return s;
    });
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() => _error = null);
    try {
      await action();
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  Future<void> _seed() => _run(() async {
        await _doctor.set(_doctorData);
        await _patient.set({'name': 'Ann Lee', 'born': 1980, 'doctor': _doctor});
        await _nurse.set({'name': 'Nurse Joy'});
        await _visit.set({
          'reason': 'Check-up',
          'patient': _patient,
          'team': [_nurse, _theirs],
          'scan': Link.file('scans/chest-xray.png'),
          'attachments': [Link.file('scans/ecg.pdf'), Link.file('private/notes.txt'), Link.file('scans/missing.png')],
          'author': Link.user(widget.uid),
        });
      });

  Future<void> _renameDoctor() =>
      _run(() => _doctor.update({'name': 'Dr ${['Grey', 'House', 'Who', 'Quinn', 'Strange'][_rng.nextInt(5)]}'}));
  Future<void> _renamePatient() =>
      _run(() => _patient.update({'name': '${['Ann', 'Annie', 'Anna'][_rng.nextInt(3)]} Lee'}));
  Future<void> _deleteDoctor() => _run(() => _doctor.delete());
  Future<void> _restoreDoctor() => _run(() => _doctor.set(_doctorData));

  /// The doctor has an account: someone else's profile, which signed-in users may see.
  Map<String, Object?> get _doctorData => {'name': 'Dr Grey', 'specialty': 'Cardiology', 'account': Link.user(widget.otherUid)};

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text('Expanding references', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 4),
        Text(
          "visits/demo → patient → doctor → account, a team with your nurse and ${widget.otherUid}'s "
          "(which the rules hide from you), files (one missing, one hidden) and its author. "
          "Listened to with expand(${_paths.join(', ')}).",
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 12),
        Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
          FilledButton.icon(onPressed: _seed, icon: const Icon(Icons.auto_fix_high), label: const Text('Create demo data')),
          OutlinedButton(onPressed: _renameDoctor, child: const Text('Rename doctor')),
          OutlinedButton(onPressed: _renamePatient, child: const Text('Rename patient')),
          OutlinedButton(onPressed: _deleteDoctor, child: const Text('Delete doctor')),
          OutlinedButton(onPressed: _restoreDoctor, child: const Text('Restore doctor')),
          FilterChip(
            label: const Text('expand'),
            selected: _expand,
            onSelected: (v) => setState(() {
              _expand = v;
              _listen();
            }),
          ),
        ]),
        if (_error != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(_error!, style: const TextStyle(color: Colors.red))),
        const SizedBox(height: 16),
        StreamBuilder<DocumentSnapshot<Map<String, Object?>>>(
          key: ValueKey('${widget.uid}/$_expand'),
          stream: _stream,
          builder: (context, snap) {
            if (snap.hasError) return Text('${snap.error}', style: const TextStyle(color: Colors.red));
            final s = snap.data;
            if (s == null) return const Center(child: CircularProgressIndicator());
            if (!s.exists) return const Text('No visit yet: tap "Create demo data".');
            return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Snapshots received: $_emissions'
                  '${s.metadata.fromCache ? ' · from cache' : ''}${s.metadata.hasPendingWrites ? ' · unsynced writes' : ''}',
                  style: Theme.of(context).textTheme.labelMedium),
              const SizedBox(height: 8),
              _DocCard(title: s.path, data: s.data()!, depth: 0),
            ]);
          },
        ),
      ],
    );
  }
}

/// How each kind of link looks: documents green, files blue, users purple.
({MaterialColor color, IconData icon, String label}) _look(LinkKind kind) => switch (kind) {
      LinkKind.document => (color: Colors.green, icon: Icons.link, label: 'document'),
      LinkKind.file => (color: Colors.blue, icon: Icons.attach_file, label: 'file'),
      LinkKind.user => (color: Colors.purple, icon: Icons.person, label: 'user'),
    };

/// A document's fields (or a file's record, a user's profile): links with data (expanded) are nested cards coloured
/// by kind, links without (not expanded, missing, or hidden by the rules) grey chips with their target.
class _DocCard extends StatelessWidget {
  const _DocCard({required this.title, required this.data, required this.depth, this.kind = LinkKind.document});

  final String title;
  final Map<String, Object?> data;
  final int depth;
  final LinkKind kind;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final look = _look(kind);
    return Card(
      color: depth == 0 ? null : look.color.withValues(alpha: 0.08),
      shape: RoundedRectangleBorder(
        side: BorderSide(color: depth == 0 ? colors.outlineVariant : look.color.shade400),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(depth == 0 ? Icons.description : look.icon, size: 16, color: depth == 0 ? null : look.color.shade700),
            const SizedBox(width: 6),
            Expanded(child: Text(title, style: Theme.of(context).textTheme.labelLarge)),
            if (depth > 0) Text('${look.label} · expanded', style: TextStyle(color: look.color.shade700, fontSize: 12)),
          ]),
          const Divider(),
          for (final e in data.entries)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                SizedBox(width: 90, child: Text(e.key, style: const TextStyle(fontWeight: FontWeight.w600))),
                Expanded(child: _value(e.value)),
              ]),
            ),
        ]),
      ),
    );
  }

  Widget _value(Object? value) => switch (value) {
        Link link => switch (link.data()) {
            final linked? => _DocCard(title: link.target, data: linked, depth: depth + 1, kind: link.kind),
            null => Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Chip(
                  avatar: Icon(link.kind == LinkKind.document ? Icons.link_off : _look(link.kind).icon, size: 16),
                  label: Text('${link.kind == LinkKind.document ? '' : '${_look(link.kind).label}: '}${link.target}'),
                  visualDensity: VisualDensity.compact,
                  backgroundColor: Colors.grey.withValues(alpha: 0.12),
                ),
              ),
          },
        List items => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [for (final v in items) _value(v)]),
        _ => Text('$value'),
      };
}
