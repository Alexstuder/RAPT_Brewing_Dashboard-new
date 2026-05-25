class BrewSession {
  final String id;                             // uuid PK
  final String? profileId;                     // RAPT-Profile (kann sich für mehrere Sessions wiederholen) oder 'manual.<uuid>'
  final String name;
  final DateTime startDate;
  final DateTime endDate;
  final DateTime? customStartDate;
  final DateTime? customEndDate;
  final String? tempKey;
  final bool? isHydrometerOnly;
  final bool isManual;

  BrewSession({
    required this.id,
    this.profileId,
    required this.name,
    required this.startDate,
    required this.endDate,
    this.customStartDate,
    this.customEndDate,
    this.tempKey,
    this.isHydrometerOnly,
    this.isManual = false,
  });

  DateTime get effectiveStart => customStartDate ?? startDate;
  DateTime get effectiveEnd => customEndDate ?? endDate;

  factory BrewSession.fromJson(Map<String, dynamic> j) => BrewSession(
        id: j['id'] as String,
        profileId: j['profile_id'] as String?,
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
        isManual: (j['is_manual'] as bool?) ?? false,
      );
}

/// Aggregierte Telemetrie-Phase aus device_activity Sicht.
class DeviceActivityPhase {
  final String deviceId;
  final String? profileId;   // null = unzugeordnet
  final String? profileName;
  final int sessionIndex;    // 1,2,3 falls Profile mit Gap mehrfach genutzt
  final DateTime firstSeen;
  final DateTime lastSeen;
  final int pointCount;

  DeviceActivityPhase({
    required this.deviceId,
    this.profileId,
    this.profileName,
    required this.sessionIndex,
    required this.firstSeen,
    required this.lastSeen,
    required this.pointCount,
  });
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

class UserProfile {
  final String id;
  final String name;
  final String? avatarBlob;
  final String? raptUserId;
  /// True when a RAPT API key is stored in the vault. The key itself is never
  /// returned to the client — only this flag is readable via the profile row.
  final bool raptConfigured;

  UserProfile({
    required this.id,
    required this.name,
    this.avatarBlob,
    this.raptUserId,
    this.raptConfigured = false,
  });

  factory UserProfile.fromJson(Map<String, dynamic> j) => UserProfile(
        id: j['id'] as String,
        name: (j['name'] as String?) ?? '',
        avatarBlob: j['avatar_blob'] as String?,
        raptUserId: j['rapt_user_id'] as String?,
        raptConfigured: (j['rapt_configured'] as bool?) ?? false,
      );

  /// Only non-secret profile fields. `rapt_user_id` / RAPT API key are
  /// written exclusively via the `set_my_rapt_creds` RPC so they are never
  /// accidentally nulled out by a plain profile upsert.
  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'avatar_blob': avatarBlob,
      };
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
