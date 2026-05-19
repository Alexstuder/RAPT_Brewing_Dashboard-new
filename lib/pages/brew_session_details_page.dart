import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../models/brew_session.dart';
import '../services/rapt_repository.dart';

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
  List<ControllerTelemetryPoint> _ctrl = [];
  List<HydrometerTelemetryPoint> _hyd = [];

  late DateTime _from;
  late DateTime _to;

  @override
  void initState() {
    super.initState();
    _from = widget.session.effectiveStart;
    _to = widget.session.effectiveEnd;
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final repo = ref.read(raptRepositoryProvider);
      final futures = await Future.wait([
        repo.fetchControllerTelemetry(
          profileId: widget.session.profileId,
          from: _from,
          to: _to,
        ),
        repo.fetchHydrometerTelemetry(from: _from, to: _to),
      ]);
      if (!mounted) return;
      setState(() {
        _ctrl = futures[0] as List<ControllerTelemetryPoint>;
        _hyd = futures[1] as List<HydrometerTelemetryPoint>;
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
    setState(() => _from = d);
    final repo = ref.read(raptRepositoryProvider);
    await repo.updateCustomDates(widget.session.profileId, customStart: d, customEnd: _to);
    _load();
  }

  Future<void> _pickEnd() async {
    final d = await showDatePicker(
      context: context,
      initialDate: _to,
      firstDate: _from,
      lastDate: DateTime.now(),
    );
    if (d == null) return;
    setState(() => _to = d);
    final repo = ref.read(raptRepositoryProvider);
    await repo.updateCustomDates(widget.session.profileId, customStart: _from, customEnd: d);
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final df = DateFormat('dd.MM.yyyy');
    return Scaffold(
      backgroundColor: const Color(0xFF020617),
      appBar: AppBar(
        title: Text(widget.session.name),
        backgroundColor: Colors.transparent,
        elevation: 0,
        actions: [
          IconButton(icon: const Icon(Icons.refresh), onPressed: _load),
        ],
      ),
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
              : SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: TextButton.icon(
                              icon: const Icon(Icons.calendar_today),
                              label: Text('Start: ${df.format(_from)}'),
                              onPressed: _pickStart,
                            ),
                          ),
                          Expanded(
                            child: TextButton.icon(
                              icon: const Icon(Icons.calendar_today),
                              label: Text('Ende: ${df.format(_to)}'),
                              onPressed: _pickEnd,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      _buildChartCard(
                        title: 'Temperatur (Controller)',
                        unit: '°C',
                        points: _ctrl
                            .where((p) => p.temperature != null)
                            .map((p) => FlSpot(
                                  p.ts.millisecondsSinceEpoch.toDouble(),
                                  p.temperature!,
                                ))
                            .toList(),
                      ),
                      const SizedBox(height: 16),
                      _buildChartCard(
                        title: 'Stammwürze / Restextrakt (Hydrometer SG)',
                        unit: '',
                        points: _hyd
                            .where((p) => p.gravity != null)
                            .map((p) => FlSpot(
                                  p.ts.millisecondsSinceEpoch.toDouble(),
                                  p.gravity!,
                                ))
                            .toList(),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        '${_ctrl.length} Controller-Punkte, ${_hyd.length} Hydrometer-Punkte',
                        style: const TextStyle(color: Colors.white54),
                      ),
                    ],
                  ),
                ),
    );
  }

  Widget _buildChartCard({
    required String title,
    required String unit,
    required List<FlSpot> points,
  }) {
    return Card(
      color: const Color(0xFF0F172A),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title,
                style: const TextStyle(
                    color: Colors.white, fontWeight: FontWeight.bold)),
            const SizedBox(height: 12),
            SizedBox(
              height: 240,
              child: points.isEmpty
                  ? Center(
                      child: Text('Keine Daten in diesem Zeitraum',
                          style: TextStyle(color: Colors.white38)),
                    )
                  : LineChart(LineChartData(
                      gridData: const FlGridData(show: false),
                      borderData: FlBorderData(show: false),
                      titlesData: FlTitlesData(
                        leftTitles: AxisTitles(
                          sideTitles: SideTitles(
                            showTitles: true,
                            reservedSize: 44,
                            getTitlesWidget: (v, _) => Text(
                              unit.isEmpty
                                  ? v.toStringAsFixed(3)
                                  : v.toStringAsFixed(1),
                              style: const TextStyle(
                                  color: Colors.white54, fontSize: 10),
                            ),
                          ),
                        ),
                        bottomTitles: AxisTitles(
                          sideTitles: SideTitles(
                            showTitles: true,
                            reservedSize: 30,
                            interval: (points.last.x - points.first.x) / 4,
                            getTitlesWidget: (v, _) {
                              final d = DateTime.fromMillisecondsSinceEpoch(
                                  v.toInt());
                              return Text(DateFormat('dd.MM').format(d),
                                  style: const TextStyle(
                                      color: Colors.white54, fontSize: 10));
                            },
                          ),
                        ),
                        topTitles: const AxisTitles(),
                        rightTitles: const AxisTitles(),
                      ),
                      lineBarsData: [
                        LineChartBarData(
                          spots: points,
                          isCurved: false,
                          barWidth: 2,
                          color: const Color(0xFF2563EB),
                          dotData: const FlDotData(show: false),
                        ),
                      ],
                    )),
            ),
          ],
        ),
      ),
    );
  }
}
