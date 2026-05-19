class BrewSession {
  final String profileId;
  final String name;
  final DateTime startDate;
  final DateTime endDate;
  final DateTime? customStartDate;
  final DateTime? customEndDate;
  final String? tempKey;
  final bool? isHydrometerOnly;

  BrewSession({
    required this.profileId,
    required this.name,
    required this.startDate,
    required this.endDate,
    this.customStartDate,
    this.customEndDate,
    this.tempKey,
    this.isHydrometerOnly,
  });

  DateTime get effectiveStart => customStartDate ?? startDate;
  DateTime get effectiveEnd => customEndDate ?? endDate;

  factory BrewSession.fromJson(Map<String, dynamic> j) => BrewSession(
        profileId: j['profile_id'] as String,
        name: (j['name'] as String?) ?? '(unbenannt)',
        startDate: DateTime.parse(j['start_date'] as String),
        endDate: DateTime.parse(j['end_date'] as String),
        customStartDate: j['custom_start_date'] == null
            ? null
            : DateTime.parse(j['custom_start_date'] as String),
        customEndDate: j['custom_end_date'] == null
            ? null
            : DateTime.parse(j['custom_end_date'] as String),
        tempKey: j['temp_key'] as String?,
        isHydrometerOnly: j['is_hydrometer_only'] as bool?,
      );
}

class ControllerTelemetryPoint {
  final DateTime ts;
  final double? temperature;
  final double? targetTemperature;
  final String? profileId;

  ControllerTelemetryPoint({
    required this.ts,
    this.temperature,
    this.targetTemperature,
    this.profileId,
  });

  factory ControllerTelemetryPoint.fromJson(Map<String, dynamic> j) =>
      ControllerTelemetryPoint(
        ts: DateTime.parse(j['created_on'] as String),
        temperature: (j['temperature'] as num?)?.toDouble(),
        targetTemperature: (j['target_temperature'] as num?)?.toDouble(),
        profileId: j['profile_id'] as String?,
      );
}

class HydrometerTelemetryPoint {
  final DateTime ts;
  final double? temperature;
  final double? gravity;
  final double? battery;

  HydrometerTelemetryPoint({
    required this.ts,
    this.temperature,
    this.gravity,
    this.battery,
  });

  factory HydrometerTelemetryPoint.fromJson(Map<String, dynamic> j) =>
      HydrometerTelemetryPoint(
        ts: DateTime.parse(j['created_on'] as String),
        temperature: (j['temperature'] as num?)?.toDouble(),
        gravity: (j['gravity'] as num?)?.toDouble(),
        battery: (j['battery'] as num?)?.toDouble(),
      );
}

class Device {
  final String raptId;
  final String name;
  final DateTime? lastSeen;
  final String kind; // 'controller' or 'hydrometer'

  Device({
    required this.raptId,
    required this.name,
    required this.kind,
    this.lastSeen,
  });

  factory Device.fromJson(Map<String, dynamic> j, String kind) => Device(
        raptId: j['rapt_id'] as String,
        name: (j['name'] as String?) ?? '(unbenannt)',
        lastSeen: j['last_seen'] == null
            ? null
            : DateTime.parse(j['last_seen'] as String),
        kind: kind,
      );
}
