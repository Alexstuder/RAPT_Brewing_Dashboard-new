import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../models/brew_session.dart';
import '../services/rapt_repository.dart';
import 'brew_session_details_page.dart';

class DeviceDetailsPage extends ConsumerStatefulWidget {
  const DeviceDetailsPage({super.key, required this.device});
  final Device device;

  @override
  ConsumerState<DeviceDetailsPage> createState() => _DeviceDetailsPageState();
}

class _DeviceDetailsPageState extends ConsumerState<DeviceDetailsPage> {
  bool _loading = true;
  String? _error;
  List<DeviceActivityPhase> _phases = [];
  List<BrewSession> _sessions = [];

  /// Findet die brew_session zu einer Activity-Phase: gleiche profile_id +
  /// start_date nah dran (±1 Tag). Gibt null zurück wenn keine passende
  /// Session existiert (z.B. weil noch nicht synced).
  BrewSession? _matchSession(DeviceActivityPhase p) {
    if (p.profileId == null) return null;
    for (final s in _sessions) {
      if (s.profileId == p.profileId &&
          s.startDate.difference(p.firstSeen).abs() < const Duration(days: 1)) {
        return s;
      }
    }
    return null;
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final repo = ref.read(raptRepositoryProvider);
      if (widget.device.kind != 'controller') {
        // Hydrometer-Activity-View existiert noch nicht — V2.
        setState(() => _loading = false);
        return;
      }
      final phases = await repo.fetchControllerActivity(widget.device.raptId);
      final sessions = await repo.fetchBrewSessions();
      if (!mounted) return;
      setState(() {
        _phases = phases;
        _sessions = sessions;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  Future<void> _createManual({DateTime? prefStart, DateTime? prefEnd}) async {
    final created = await showDialog<BrewSession>(
      context: context,
      builder: (_) => _ManualSessionDialog(
        initialStart: prefStart,
        initialEnd: prefEnd,
      ),
    );
    if (created != null && mounted) {
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => BrewSessionDetailsPage(session: created),
        ),
      );
      if (mounted) _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    final df = DateFormat('dd.MM.yyyy HH:mm');
    return Scaffold(
      backgroundColor: const Color(0xFF020617),
      appBar: AppBar(
        title: Text(widget.device.name),
        backgroundColor: Colors.transparent,
        elevation: 0,
        actions: [
          IconButton(icon: const Icon(Icons.refresh), onPressed: _load),
        ],
      ),
      floatingActionButton: widget.device.kind == 'controller'
          ? FloatingActionButton.extended(
              backgroundColor: const Color(0xFF2563EB),
              foregroundColor: Colors.white,
              icon: const Icon(Icons.add),
              label: const Text('Manuelles Bier'),
              onPressed: () => _createManual(),
            )
          : null,
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text('Fehler: $_error',
                        style: const TextStyle(color: Colors.redAccent)),
                  ),
                )
              : ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    Card(
                      color: const Color(0xFF0F172A),
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(widget.device.name,
                                style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 18,
                                    fontWeight: FontWeight.bold)),
                            const SizedBox(height: 4),
                            Text('${widget.device.kind} · last seen ${widget.device.lastSeen != null ? df.format(widget.device.lastSeen!.toLocal()) : "–"}',
                                style: const TextStyle(color: Colors.white60)),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    if (widget.device.kind != 'controller')
                      const Padding(
                        padding: EdgeInsets.all(24),
                        child: Text(
                          'Aktivitäts-Timeline für Hydrometer kommt in V2.',
                          style: TextStyle(color: Colors.white54),
                          textAlign: TextAlign.center,
                        ),
                      )
                    else ...[
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 8),
                        child: Text('Aktivität',
                            style: TextStyle(
                                color: Color(0xFF2563EB),
                                fontSize: 16,
                                fontWeight: FontWeight.bold)),
                      ),
                      if (_phases.isEmpty)
                        const Padding(
                          padding: EdgeInsets.symmetric(vertical: 24),
                          child: Text(
                            'Noch keine Aktivität für dieses Gerät.',
                            textAlign: TextAlign.center,
                            style: TextStyle(color: Colors.white54),
                          ),
                        )
                      else
                        ..._phases.map((p) => _phaseTile(p, df)),
                      const SizedBox(height: 80), // unter dem FAB
                    ],
                  ],
                ),
    );
  }

  Widget _phaseTile(DeviceActivityPhase p, DateFormat df) {
    final start = df.format(p.firstSeen.toLocal());
    final end = df.format(p.lastSeen.toLocal());
    final dur = p.lastSeen.difference(p.firstSeen);
    final days = dur.inDays;
    final hours = dur.inHours % 24;
    final durStr = days > 0 ? '${days}d ${hours}h' : '${dur.inHours}h';

    final hasProfile = p.profileId != null;
    final session = _matchSession(p);
    final hasName = (p.profileName != null && p.profileName!.isNotEmpty);

    Color color;
    IconData icon;
    String title;
    Widget? action;

    if (!hasProfile) {
      color = Colors.amber;
      icon = Icons.help_outline;
      title = 'Unzugeordnet';
      action = ElevatedButton.icon(
        style: ElevatedButton.styleFrom(
          backgroundColor: Colors.amber.withValues(alpha: 0.2),
          foregroundColor: Colors.amber,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        ),
        icon: const Icon(Icons.add, size: 16),
        label: const Text('Als Bier markieren', style: TextStyle(fontSize: 12)),
        onPressed: () => _createManual(prefStart: p.firstSeen, prefEnd: p.lastSeen),
      );
    } else if (session != null) {
      color = const Color(0xFF2563EB);
      icon = Icons.local_drink_outlined;
      title = session.name;
    } else {
      color = Colors.orange;
      icon = Icons.warning_amber;
      title = hasName ? p.profileName! : '(Profile ohne Session)';
    }

    return Card(
      color: const Color(0xFF0F172A),
      margin: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        onTap: session != null
            ? () async {
                await Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => BrewSessionDetailsPage(session: session),
                  ),
                );
                if (mounted) _load();
              }
            : null,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              Icon(icon, color: color),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title,
                        style: const TextStyle(
                            color: Colors.white, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 2),
                    Text('$start → $end · $durStr · ${p.pointCount} Punkte',
                        style: const TextStyle(color: Colors.white60, fontSize: 12)),
                  ],
                ),
              ),
              ?action,
              if (session != null)
                const Icon(Icons.arrow_forward_ios,
                    size: 14, color: Colors.white38),
            ],
          ),
        ),
      ),
    );
  }
}

class _ManualSessionDialog extends StatefulWidget {
  const _ManualSessionDialog({this.initialStart, this.initialEnd});
  final DateTime? initialStart;
  final DateTime? initialEnd;

  @override
  State<_ManualSessionDialog> createState() => _ManualSessionDialogState();
}

class _ManualSessionDialogState extends State<_ManualSessionDialog> {
  late TextEditingController _name;
  DateTime? _start;
  DateTime? _end;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController();
    _start = widget.initialStart;
    _end = widget.initialEnd;
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<DateTime?> _pickDateTime(DateTime? initial) async {
    final base = initial?.toLocal() ?? DateTime.now();
    final d = await showDatePicker(
      context: context,
      initialDate: base,
      firstDate: DateTime(2010),
      lastDate: DateTime.now(),
    );
    if (d == null || !mounted) return null;
    final t = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(base),
    );
    if (t == null) return null;
    return DateTime(d.year, d.month, d.day, t.hour, t.minute);
  }

  Future<void> _save() async {
    if (_name.text.trim().isEmpty) {
      setState(() => _error = 'Name erforderlich');
      return;
    }
    if (_start == null || _end == null) {
      setState(() => _error = 'Start + Ende erforderlich');
      return;
    }
    if (!_end!.isAfter(_start!)) {
      setState(() => _error = 'Ende muss nach Start sein');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final repo = ProviderScope.containerOf(context).read(raptRepositoryProvider);
      final created = await repo.createManualSession(
        name: _name.text.trim(),
        start: _start!,
        end: _end!,
      );
      if (mounted) Navigator.pop(context, created);
    } catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = '$e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final df = DateFormat('dd.MM.yyyy HH:mm');
    return AlertDialog(
      backgroundColor: const Color(0xFF0F172A),
      title: const Text('Manuelles Bier erstellen',
          style: TextStyle(color: Colors.white)),
      content: DefaultTextStyle.merge(
        style: const TextStyle(color: Colors.white),
        child: SizedBox(
          width: 400,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: _name,
                style: const TextStyle(color: Colors.white),
                decoration: const InputDecoration(
                  labelText: 'Name (z.B. "London Pride")',
                  labelStyle: TextStyle(color: Colors.white60),
                ),
              ),
              const SizedBox(height: 16),
              OutlinedButton.icon(
                icon: const Icon(Icons.calendar_today, size: 16),
                label: Text(_start != null
                    ? 'Start: ${df.format(_start!.toLocal())}'
                    : 'Start wählen…'),
                onPressed: () async {
                  final d = await _pickDateTime(_start);
                  if (d != null && mounted) setState(() => _start = d);
                },
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                icon: const Icon(Icons.calendar_today, size: 16),
                label: Text(_end != null
                    ? 'Ende: ${df.format(_end!.toLocal())}'
                    : 'Ende wählen…'),
                onPressed: () async {
                  final d = await _pickDateTime(_end ?? _start);
                  if (d != null && mounted) setState(() => _end = d);
                },
              ),
              if (_error != null) ...[
                const SizedBox(height: 8),
                Text(_error!,
                    style: const TextStyle(color: Colors.redAccent, fontSize: 12)),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.pop(context),
          child: const Text('Abbrechen'),
        ),
        FilledButton.icon(
          onPressed: _saving ? null : _save,
          icon: _saving
              ? const SizedBox(
                  width: 16, height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.save),
          label: const Text('Speichern'),
        ),
      ],
    );
  }
}
