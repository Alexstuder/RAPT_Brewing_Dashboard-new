import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../models/brew_session.dart';
import '../services/rapt_repository.dart';
import '../utils/telemetry_processor.dart';
import '../widgets/rapt_telemetry_view.dart';

class BrewSessionDetailsPage extends ConsumerStatefulWidget {
  const BrewSessionDetailsPage({super.key, required this.session});
  final BrewSession session;

  @override
  ConsumerState<BrewSessionDetailsPage> createState() =>
      _BrewSessionDetailsPageState();
}

class _BrewSessionDetailsPageState
    extends ConsumerState<BrewSessionDetailsPage> {
  bool _loading = true;
  String? _error;
  List<UnifiedTelemetryPoint> _points = [];

  late DateTime _from;
  late DateTime _to;
  DateTime? _pickedStart;
  DateTime? _pickedEnd;

  @override
  void initState() {
    super.initState();
    _from = widget.session.effectiveStart;
    _to = widget.session.effectiveEnd;
    _pickedStart = widget.session.customStartDate;
    _pickedEnd = widget.session.customEndDate;
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final repo = ref.read(raptRepositoryProvider);
      final pts = await repo.fetchUnifiedTelemetry(
        profileId: widget.session.profileId,
        from: _from,
        to: _to,
      );
      if (!mounted) return;
      setState(() {
        _points = pts;
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

  Future<void> _pickStart() async {
    final d = await showDatePicker(
      context: context,
      initialDate: _from,
      firstDate: DateTime(2010),
      lastDate: DateTime.now(),
    );
    if (d == null) return;
    setState(() {
      _pickedStart = d;
      _from = d;
    });
  }

  Future<void> _pickEnd() async {
    final d = await showDatePicker(
      context: context,
      initialDate: _to,
      firstDate: _from,
      lastDate: DateTime.now(),
    );
    if (d == null) return;
    setState(() {
      _pickedEnd = d;
      _to = d;
    });
  }

  Future<void> _apply() async {
    final repo = ref.read(raptRepositoryProvider);
    await repo.updateCustomDates(widget.session.profileId,
        customStart: _pickedStart, customEnd: _pickedEnd);
    await _load();
  }

  Future<void> _reset() async {
    final repo = ref.read(raptRepositoryProvider);
    await repo.updateCustomDates(widget.session.profileId, customStart: null, customEnd: null);
    setState(() {
      _pickedStart = null;
      _pickedEnd = null;
      _from = widget.session.startDate;
      _to = widget.session.endDate;
    });
    await _load();
  }

  bool get _isActive {
    return _to.isAfter(DateTime.now().subtract(const Duration(hours: 24)));
  }

  String _cacheInfo() {
    final df = DateFormat('dd.MM.yyyy, HH:mm');
    final tz = ' MEZ';
    final stand = _points.isNotEmpty ? df.format(_points.last.createdOn.toLocal()) + tz : '–';
    final range = '${df.format(_from.toLocal())}$tz → ${df.format(_to.toLocal())}$tz';
    return '🗂 ${_points.length} Messpunkte · Stand $stand\nZeitraum: $range';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF020617),
      appBar: AppBar(
        title: const Text('RAPT Dashboard'),
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.pop(context),
        ),
        actions: [
          IconButton(icon: const Icon(Icons.refresh), onPressed: _load),
        ],
      ),
      body: _error != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text('Fehler: $_error',
                    style: const TextStyle(color: Colors.redAccent)),
              ),
            )
          : SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _cacheInfo(),
                    style: const TextStyle(color: Colors.amber, fontSize: 13),
                  ),
                  const SizedBox(height: 16),
                  RaptTelemetryView(
                    points: _points,
                    isLoading: _loading,
                    isActive: _isActive,
                    profileName: widget.session.name,
                    footerControls: [
                      const Text('Zeitraum-Anpassung (optional)',
                          style: TextStyle(color: Colors.white54, fontSize: 12)),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 12,
                        runSpacing: 8,
                        alignment: WrapAlignment.center,
                        children: [
                          OutlinedButton.icon(
                            icon: const Icon(Icons.calendar_today, size: 16),
                            label: Text(_pickedStart != null
                                ? DateFormat('dd.MM.yyyy').format(_pickedStart!)
                                : 'Start wählen…'),
                            onPressed: _pickStart,
                          ),
                          OutlinedButton.icon(
                            icon: const Icon(Icons.calendar_today, size: 16),
                            label: Text(_pickedEnd != null
                                ? DateFormat('dd.MM.yyyy').format(_pickedEnd!)
                                : 'Ende wählen…'),
                            onPressed: _pickEnd,
                          ),
                          FilledButton(onPressed: _apply, child: const Text('Übernehmen')),
                          OutlinedButton(onPressed: _reset, child: const Text('Zurücksetzen')),
                          IconButton(icon: const Icon(Icons.refresh), onPressed: _load, tooltip: 'Reload'),
                        ],
                      ),
                    ],
                  ),
                ],
              ),
            ),
    );
  }
}
