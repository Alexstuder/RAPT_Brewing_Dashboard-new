import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../utils/telemetry_processor.dart';

class RaptTelemetryView extends StatelessWidget {
  final List<UnifiedTelemetryPoint> points;
  final bool isLoading;
  final bool isActive;
  final String? profileName;
  final Widget? headerActions;
  final List<Widget>? footerControls;
  final bool hideInactiveStatus;

  const RaptTelemetryView({
    super.key,
    required this.points,
    this.isLoading = false,
    this.isActive = false,
    this.profileName,
    this.headerActions,
    this.footerControls,
    this.hideInactiveStatus = false,
  });

  @override
  Widget build(BuildContext context) {
    if (isLoading && points.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }

    final result = TelemetryProcessor.process(points);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            if (!(hideInactiveStatus && !isActive)) _statusBadge(isActive),
            if (headerActions != null) headerActions!,
          ],
        ),
        const SizedBox(height: 16),
        Text(
          profileName ?? 'RAPT Gerät',
          style: const TextStyle(
              color: Colors.white, fontSize: 24, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 24),

        // Summary Tiles
        LayoutBuilder(
          builder: (ctx, constraints) {
            final children = [
              _summaryTile('Temperatur', result.latestTemp, '°C', Colors.blue, null),
              const SizedBox(height: 16, width: 16),
              _summaryTile('Gravity', result.latestGravity, 'SG', Colors.red, _gravityExtra(result)),
              const SizedBox(height: 16, width: 16),
              _summaryTile('Alkohol', result.latestAbv, 'Vol.%', Colors.amber, null),
            ];

            if (constraints.maxWidth < 600) {
              return Column(children: children.whereType<Widget>().toList());
            }
            return IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(child: children[0]),
                  children[1],
                  Expanded(child: children[2]),
                  children[3],
                  Expanded(child: children[4]),
                ],
              ),
            );
          },
        ),

        const SizedBox(height: 24),

        Container(
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            color: const Color(0xFF04060F).withValues(alpha: 0.94),
            borderRadius: BorderRadius.circular(40),
            boxShadow: [
              BoxShadow(
                  color: Colors.blue.withValues(alpha: 0.05),
                  blurRadius: 0,
                  spreadRadius: 1),
            ],
          ),
          child: Column(
            children: [
              _legend(),
              const SizedBox(height: 16),
              SizedBox(
                height: 400,
                child: points.isEmpty
                    ? const Center(
                        child: Text('Keine Daten',
                            style: TextStyle(color: Colors.white54)))
                    : Stack(
                        children: [
                          _chart(result),
                          Positioned(
                            right: 88, top: 0, bottom: 45,
                            child: Center(
                              child: RotatedBox(
                                quarterTurns: 3,
                                child: Text('Gravity',
                                    style: TextStyle(
                                        color: Colors.red.withValues(alpha: 0.5),
                                        fontSize: 9,
                                        fontWeight: FontWeight.bold)),
                              ),
                            ),
                          ),
                          Positioned(
                            right: 42, top: 0, bottom: 45,
                            child: Center(
                              child: RotatedBox(
                                quarterTurns: 3,
                                child: Text('SG/Tag',
                                    style: TextStyle(
                                        color: Colors.brown.withValues(alpha: 0.5),
                                        fontSize: 9,
                                        fontWeight: FontWeight.bold)),
                              ),
                            ),
                          ),
                          Positioned(
                            right: 5, top: 0, bottom: 45,
                            child: Center(
                              child: RotatedBox(
                                quarterTurns: 3,
                                child: Text('Alkohol %',
                                    style: TextStyle(
                                        color: Colors.amber.withValues(alpha: 0.5),
                                        fontSize: 9,
                                        fontWeight: FontWeight.bold)),
                              ),
                            ),
                          ),
                        ],
                      ),
              ),
              if (footerControls != null) ...[
                const SizedBox(height: 24),
                ...footerControls!,
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _statusBadge(bool active) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: active
              ? Colors.green.withValues(alpha: 0.2)
              : Colors.red.withValues(alpha: 0.2),
          border: Border.all(
              color:
                  active ? Colors.green : Colors.red.withValues(alpha: 0.5)),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(
          active ? 'Gerade am Gären' : 'Gärt nicht',
          style: TextStyle(
              color: active ? Colors.greenAccent : Colors.redAccent,
              fontSize: 12,
              fontWeight: FontWeight.bold),
        ),
      );

  Widget _summaryTile(String label, double? value, String unit, Color color, Widget? extra) =>
      Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: const Color(0xFF0F172A).withValues(alpha: 0.65),
          border: Border.all(color: color.withValues(alpha: 0.4)),
          borderRadius: BorderRadius.circular(18),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(label.toUpperCase(),
                style: TextStyle(
                    color: Colors.indigo[100],
                    fontSize: 13,
                    letterSpacing: 0.5)),
            const SizedBox(height: 6),
            Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Text(
                  value != null
                      ? (label == 'Gravity'
                          ? value.toStringAsFixed(4)
                          : value.toStringAsFixed(1))
                      : '–',
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 32,
                      fontWeight: FontWeight.bold),
                ),
                const SizedBox(width: 4),
                Text(unit, style: const TextStyle(color: Colors.white70, fontSize: 14)),
              ],
            ),
            if (extra != null) ...[const SizedBox(height: 8), extra],
          ],
        ),
      );

  Widget _gravityExtra(TelemetryProcessingResult res) {
    final dStr = res.delta24h != null
        ? (res.delta24h! > 0
            ? '+${res.delta24h!.toStringAsFixed(4)}'
            : res.delta24h!.toStringAsFixed(4))
        : '–';
    return Column(children: [
      _row('OG', res.og != null ? res.og!.toStringAsFixed(4) : '–'),
      _row('Δ 24h', dStr),
    ]);
  }

  Widget _row(String l, String v) => Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(l, style: const TextStyle(color: Colors.white54, fontSize: 11)),
          Text(v, style: const TextStyle(color: Colors.white, fontSize: 11)),
        ],
      );

  Widget _legend() => Wrap(
        spacing: 16,
        runSpacing: 8,
        alignment: WrapAlignment.center,
        children: [
          _legendItem('Temp (°C)', Colors.blue),
          _legendItem('Soll-Temp', Colors.blueGrey),
          _legendItem('Gravity', Colors.red),
          _legendItem('Alkohol (%)', Colors.amber),
          _legendItem('Gärgeschw. (SG/Tag)', Colors.brown),
        ],
      );

  Widget _legendItem(String label, Color color) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(width: 12, height: 2, color: color),
          const SizedBox(width: 6),
          Text(label,
              style: const TextStyle(color: Colors.white70, fontSize: 11)),
        ],
      );

  Widget _chart(TelemetryProcessingResult res) {
    if (res.pointsTemp.isEmpty && res.pointsGravity.isEmpty) return const SizedBox();

    final firstX = res.sortedPoints.first.createdOn.millisecondsSinceEpoch.toDouble();
    final lastX = res.sortedPoints.last.createdOn.millisecondsSinceEpoch.toDouble();
    final hours = (lastX - firstX) / 3600000;
    double interval = hours <= 48 ? 3600000 * 6 : 3600000 * 24;

    final List<VerticalLine> dayLines = [];
    if (hours > 24) {
      final fd = res.sortedPoints.first.createdOn;
      var it = DateTime(fd.year, fd.month, fd.day).add(const Duration(days: 1));
      while (it.millisecondsSinceEpoch <= lastX) {
        if (it.millisecondsSinceEpoch >= firstX) {
          dayLines.add(VerticalLine(
            x: it.millisecondsSinceEpoch.toDouble(),
            color: Colors.white10,
            strokeWidth: 1,
            dashArray: [5, 5],
          ));
        }
        it = it.add(const Duration(days: 1));
      }
    }

    return LineChart(LineChartData(
      minY: res.minTemp,
      maxY: res.maxTemp,
      minX: firstX,
      maxX: lastX,
      extraLinesData: ExtraLinesData(verticalLines: dayLines),
      gridData: FlGridData(
        show: true,
        drawVerticalLine: hours <= 24,
        getDrawingHorizontalLine: _grid,
        getDrawingVerticalLine: _grid,
      ),
      borderData: FlBorderData(show: false),
      titlesData: FlTitlesData(
        bottomTitles: AxisTitles(
          sideTitles: SideTitles(
            showTitles: true,
            interval: interval,
            reservedSize: 45,
            getTitlesWidget: (val, _) {
              final d = DateTime.fromMillisecondsSinceEpoch(val.toInt());
              final delta = res.dailyDeltas[DateFormat('yyyy-MM-dd').format(d)];
              return Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Column(children: [
                  Text(
                    hours <= 48 ? DateFormat('HH:mm').format(d) : DateFormat('dd.MM.').format(d),
                    style: const TextStyle(color: Colors.white54, fontSize: 10),
                  ),
                  if (delta != null && delta != 0)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        delta > 0
                            ? '+${delta.toStringAsFixed(4)}'
                            : delta.toStringAsFixed(4),
                        style: TextStyle(
                          color: delta < 0 ? Colors.greenAccent : Colors.redAccent,
                          fontSize: 9,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                ]),
              );
            },
          ),
        ),
        leftTitles: AxisTitles(
          sideTitles: SideTitles(
            showTitles: true,
            reservedSize: 30,
            getTitlesWidget: (val, _) => Text(val.toStringAsFixed(0),
                style: const TextStyle(color: Colors.blue, fontSize: 10)),
          ),
        ),
        rightTitles: AxisTitles(
          sideTitles: SideTitles(
            showTitles: true,
            reservedSize: 140,
            getTitlesWidget: (val, _) {
              final g = res.denormalizeGravity(val);
              final a = res.denormalizeAbv(val);
              final v = res.denormalizeVel(val) / 1000.0;
              return Padding(
                padding: const EdgeInsets.only(left: 8),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(
                      width: 38,
                      child: Text(g.toStringAsFixed(3),
                          style: const TextStyle(color: Colors.red, fontSize: 9),
                          textAlign: TextAlign.right),
                    ),
                    const SizedBox(width: 8),
                    SizedBox(
                      width: 38,
                      child: Text(v.toStringAsFixed(3),
                          style: const TextStyle(color: Colors.brown, fontSize: 9),
                          textAlign: TextAlign.right),
                    ),
                    const SizedBox(width: 8),
                    SizedBox(
                      width: 25,
                      child: Text(a.toStringAsFixed(1),
                          style: const TextStyle(color: Colors.amber, fontSize: 9),
                          textAlign: TextAlign.right),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
        topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
      ),
      lineTouchData: LineTouchData(
        touchTooltipData: LineTouchTooltipData(
          getTooltipColor: (_) => Colors.black87,
          getTooltipItems: (touched) {
            final items = touched.map((s) {
              if (s.barIndex == 0) {
                return LineTooltipItem('${s.y.toStringAsFixed(1)} °C',
                    const TextStyle(color: Colors.blue));
              }
              if (s.barIndex == 1) {
                return LineTooltipItem('${s.y.toStringAsFixed(1)} °C (Soll)',
                    const TextStyle(color: Colors.blueGrey));
              }
              if (s.barIndex == 2) {
                return LineTooltipItem(
                    '${res.denormalizeGravity(s.y).toStringAsFixed(4)} SG',
                    const TextStyle(color: Colors.red));
              }
              if (s.barIndex == 3) {
                return LineTooltipItem(
                    '${res.denormalizeAbv(s.y).toStringAsFixed(1)} %',
                    const TextStyle(color: Colors.amber));
              }
              return LineTooltipItem(
                  '${(res.denormalizeVel(s.y) / 1000.0).toStringAsFixed(4)} SG/Tag',
                  const TextStyle(color: Colors.brown));
            }).toList();

            if (items.isNotEmpty && touched.isNotEmpty) {
              final dt = DateTime.fromMillisecondsSinceEpoch(touched.first.x.toInt());
              final first = items.first;
              items[0] = LineTooltipItem(
                '${DateFormat('dd.MM.yyyy HH:mm').format(dt)}\n',
                const TextStyle(
                    color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12),
                children: [TextSpan(text: first.text, style: first.textStyle)],
              );
            }
            return items;
          },
        ),
      ),
      lineBarsData: [
        _bar(res.pointsTemp, Colors.blue, true, true),
        _bar(res.pointsTargetTemp, Colors.blueGrey, false, false, width: 1.5, isDashed: true),
        _bar(res.pointsGravity, Colors.red, true, true),
        _bar(res.pointsAbv, Colors.amber, true, true),
        _bar(res.pointsVelocity, Colors.brown, false, false, width: 1.5),
      ],
    ));
  }

  static FlLine _grid(double _) =>
      const FlLine(color: Colors.white10, strokeWidth: 1);

  LineChartBarData _bar(List<FlSpot> spots, Color color, bool curved, bool below,
      {double width = 2, bool isDashed = false}) {
    return LineChartBarData(
      spots: spots,
      color: color,
      isCurved: curved,
      barWidth: width,
      dotData: const FlDotData(show: false),
      belowBarData: BarAreaData(show: below, color: color.withValues(alpha: 0.1)),
      dashArray: isDashed ? [5, 5] : null,
    );
  }
}
