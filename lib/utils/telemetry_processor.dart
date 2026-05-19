import 'dart:math';
import 'package:fl_chart/fl_chart.dart';
import 'package:intl/intl.dart';

/// Vereinheitlichter Daten-Punkt. Wird aus Controller- + Hydrometer-Telemetrie
/// zusammengeführt (per Timestamp). Felder sind alle nullable, weil ein
/// einzelner Controller-Row nur Temp+Target hat, ein Hydrometer-Row nur Gravity+Battery.
class UnifiedTelemetryPoint {
  final DateTime createdOn;
  final double? temperature;
  final double? targetTemperature;
  final double? gravity;
  final double? battery;
  final String? profileName;

  UnifiedTelemetryPoint({
    required this.createdOn,
    this.temperature,
    this.targetTemperature,
    this.gravity,
    this.battery,
    this.profileName,
  });

  static double normalizeGravity(double? val) {
    if (val == null) return 0.0;
    if (val > 500) return val / 1000.0; // RAPT-API liefert manchmal *1000
    return val;
  }
}

class TelemetryProcessingResult {
  final List<UnifiedTelemetryPoint> sortedPoints;
  final List<FlSpot> pointsTemp;
  final List<FlSpot> pointsTargetTemp;
  final List<FlSpot> pointsGravity;
  final List<FlSpot> pointsAbv;
  final List<FlSpot> pointsVelocity;
  final Map<String, double> dailyDeltas;

  final double? latestTemp;
  final double? latestGravity;
  final double? latestAbv;
  final double? og;
  final double? delta24h;
  final double? latestBattery;

  final double minTemp;
  final double maxTemp;
  final double minGrav;
  final double maxGrav;
  final double minAbv;
  final double maxAbv;
  final double minVel;
  final double maxVel;

  TelemetryProcessingResult({
    required this.sortedPoints,
    required this.pointsTemp,
    required this.pointsTargetTemp,
    required this.pointsGravity,
    required this.pointsAbv,
    required this.pointsVelocity,
    required this.dailyDeltas,
    this.latestTemp,
    this.latestGravity,
    this.latestAbv,
    this.og,
    this.delta24h,
    this.latestBattery,
    required this.minTemp,
    required this.maxTemp,
    required this.minGrav,
    required this.maxGrav,
    required this.minAbv,
    required this.maxAbv,
    required this.minVel,
    required this.maxVel,
  });

  double denormalizeGravity(double y) =>
      (y - minTemp) / (maxTemp - minTemp) * (maxGrav - minGrav) + minGrav;
  double denormalizeAbv(double y) =>
      (y - minTemp) / (maxTemp - minTemp) * (maxAbv - minAbv) + minAbv;
  double denormalizeVel(double y) =>
      (y - minTemp) / (maxTemp - minTemp) * (maxVel - minVel) + minVel;
}

class TelemetryProcessor {
  static double _median(List<double> vals) {
    if (vals.isEmpty) return 0;
    final s = List<double>.from(vals)..sort();
    final m = s.length ~/ 2;
    return s.length.isEven ? (s[m - 1] + s[m]) / 2 : s[m];
  }

  static List<double> _medianFilter(List<double> v, int window) {
    if (v.length < window) return v;
    final out = <double>[];
    final half = window ~/ 2;
    for (int i = 0; i < v.length; i++) {
      out.add(_median(v.sublist(max(0, i - half), min(v.length, i + half + 1))));
    }
    return out;
  }

  static TelemetryProcessingResult process(List<UnifiedTelemetryPoint> points) {
    if (points.isEmpty) {
      return TelemetryProcessingResult(
        sortedPoints: [],
        pointsTemp: [], pointsTargetTemp: [], pointsGravity: [],
        pointsAbv: [], pointsVelocity: [], dailyDeltas: {},
        minTemp: 0, maxTemp: 30, minGrav: 1.000, maxGrav: 1.080,
        minAbv: 0, maxAbv: 8, minVel: 0, maxVel: 10,
      );
    }

    final sorted = List<UnifiedTelemetryPoint>.from(points)
      ..sort((a, b) => a.createdOn.compareTo(b.createdOn));

    final withTemp = sorted.where((p) => p.temperature != null).toList();
    final withTarget = sorted.where((p) => p.targetTemperature != null).toList();
    final withGrav = sorted.where((p) => p.gravity != null && p.gravity! > 0.5).toList();

    final rawGravs = withGrav.map((p) => p.gravity!).toList();
    final filteredGravs = _medianFilter(rawGravs, 5);

    final pTemp = <FlSpot>[];
    final pTarget = <FlSpot>[];
    final pGravRaw = <FlSpot>[];
    final pAbvRaw = <FlSpot>[];
    final pVelRaw = <FlSpot>[];
    final dailyDeltas = <String, double>{};

    double? og;
    if (filteredGravs.isNotEmpty) og = filteredGravs.reduce(max);

    double? latestTemp;
    double? latestGravity;
    double? latestAbv;
    double? latestBattery;
    DateTime? lastDate;

    if (withTemp.isNotEmpty) latestTemp = withTemp.last.temperature;
    if (filteredGravs.isNotEmpty) latestGravity = filteredGravs.last;
    if (sorted.isNotEmpty) {
      lastDate = sorted.last.createdOn;
      for (var i = sorted.length - 1; i >= 0; i--) {
        if (sorted[i].battery != null) {
          latestBattery = sorted[i].battery;
          break;
        }
      }
    }

    final currentG = latestGravity;
    if (og != null && currentG != null && currentG > 0.5) {
      latestAbv = (og - currentG) * 131.25;
      if (latestAbv < 0) latestAbv = 0;
    }

    double? delta24h;
    if (latestGravity != null && lastDate != null && withGrav.isNotEmpty) {
      final target = lastDate.subtract(const Duration(hours: 24));
      int closest = -1;
      int minDiff = 86400 * 1000;
      for (int i = 0; i < withGrav.length; i++) {
        final d = (withGrav[i].createdOn.difference(target)).inMilliseconds.abs();
        if (d < minDiff) {
          minDiff = d;
          closest = i;
        }
      }
      if (closest != -1 && minDiff < 3600 * 1000 * 6) {
        delta24h = latestGravity - filteredGravs[closest];
      }
    }

    DateTime? lastDay;
    double? lastDayG;
    for (int i = 0; i < withGrav.length; i++) {
      final g = filteredGravs[i];
      final t = withGrav[i].createdOn;
      final day = DateTime(t.year, t.month, t.day);
      if (lastDay == null) {
        lastDay = day;
        lastDayG = g;
      } else if (day.isAfter(lastDay)) {
        if (lastDayG != null) {
          dailyDeltas[DateFormat('yyyy-MM-dd').format(day)] = g - lastDayG;
        }
        lastDay = day;
        lastDayG = g;
      }
    }

    for (final p in withTemp) {
      pTemp.add(FlSpot(p.createdOn.millisecondsSinceEpoch.toDouble(), p.temperature!));
    }
    for (final p in withTarget) {
      pTarget.add(FlSpot(p.createdOn.millisecondsSinceEpoch.toDouble(), p.targetTemperature!));
    }
    for (int i = 0; i < withGrav.length; i++) {
      final p = withGrav[i];
      final g = filteredGravs[i];
      final x = p.createdOn.millisecondsSinceEpoch.toDouble();
      pGravRaw.add(FlSpot(x, g));

      if (og != null) {
        double a = (og - g) * 131.25;
        if (a < 0) a = 0;
        if (pAbvRaw.isNotEmpty && a < pAbvRaw.last.y) a = pAbvRaw.last.y;
        pAbvRaw.add(FlSpot(x, a));
      }

      const windowMs = 12 * 60 * 60 * 1000;
      int? startIdx;
      for (int j = i - 1; j >= 0; j--) {
        if (withGrav[j].createdOn.millisecondsSinceEpoch <= x - windowMs) {
          startIdx = j;
          break;
        }
      }
      if (startIdx != null) {
        final dtDays = (x - withGrav[startIdx].createdOn.millisecondsSinceEpoch) /
            (1000 * 60 * 60 * 24);
        if (dtDays >= 0.05) {
          double dg = (filteredGravs[startIdx] - g) * 1000;
          double vel = dg / dtDays;
          if (vel < 0) vel = 0;
          pVelRaw.add(FlSpot(x, vel));
        }
      } else {
        pVelRaw.add(FlSpot(x, 0));
      }
    }

    double minTemp = pTemp.isNotEmpty ? pTemp.map((e) => e.y).reduce(min) - 5 : 0;
    double maxTemp = pTemp.isNotEmpty ? pTemp.map((e) => e.y).reduce(max) + 5 : 30;
    double minGrav = pGravRaw.isNotEmpty ? pGravRaw.map((e) => e.y).reduce(min) - 0.005 : 1.000;
    double maxGrav = pGravRaw.isNotEmpty ? pGravRaw.map((e) => e.y).reduce(max) + 0.005 : 1.080;
    double minAbv = 0.0;
    double maxAbv = pAbvRaw.isNotEmpty ? pAbvRaw.map((e) => e.y).reduce(max) + 1.0 : 8.0;
    double minVel = 0;
    double maxVel = pVelRaw.isNotEmpty
        ? (pVelRaw.map((e) => e.y).reduce(max) * 1.2 / 5).ceil() * 5.0
        : 10.0;
    if (maxVel < 5) maxVel = 5;

    double nG(double g) => (maxGrav == minGrav)
        ? minTemp + (maxTemp - minTemp) / 2
        : (g - minGrav) / (maxGrav - minGrav) * (maxTemp - minTemp) + minTemp;
    double nA(double a) => (maxAbv == minAbv)
        ? minTemp + (maxTemp - minTemp) / 2
        : (a - minAbv) / (maxAbv - minAbv) * (maxTemp - minTemp) + minTemp;
    double nV(double v) => (maxVel == minVel)
        ? minTemp + (maxTemp - minTemp) / 2
        : (v - minVel) / (maxVel - minVel) * (maxTemp - minTemp) + minTemp;

    return TelemetryProcessingResult(
      sortedPoints: sorted,
      pointsTemp: pTemp,
      pointsTargetTemp: pTarget,
      pointsGravity: pGravRaw.map((e) => FlSpot(e.x, nG(e.y))).toList(),
      pointsAbv: pAbvRaw.map((e) => FlSpot(e.x, nA(e.y))).toList(),
      pointsVelocity: pVelRaw.map((e) => FlSpot(e.x, nV(e.y))).toList(),
      dailyDeltas: dailyDeltas,
      latestTemp: latestTemp,
      latestGravity: latestGravity,
      latestAbv: latestAbv,
      og: og,
      delta24h: delta24h,
      latestBattery: latestBattery,
      minTemp: minTemp, maxTemp: maxTemp,
      minGrav: minGrav, maxGrav: maxGrav,
      minAbv: minAbv, maxAbv: maxAbv,
      minVel: minVel, maxVel: maxVel,
    );
  }
}
