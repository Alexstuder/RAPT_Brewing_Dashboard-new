import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/brew_session.dart';
import '../utils/telemetry_processor.dart';

/// Backend-First Repository: liest aus dem `rapt` Schema in Supabase.
/// brew-proxy synced RAPT-API → Postgres periodisch; diese App liest nur (+
/// schreibt custom_start_date / custom_end_date wenn der User es ändert).
class RaptRepository {
  RaptRepository(this._client);

  final SupabaseClient _client;
  SupabaseQueryBuilder _t(String table) =>
      _client.schema('rapt').from(table);

  // ---------------------------------------------------------------------------
  // Brew Sessions (= gebraute Biere)
  // ---------------------------------------------------------------------------

  Future<List<BrewSession>> fetchBrewSessions() async {
    final rows = await _t('brew_sessions')
        .select()
        .order('start_date', ascending: false);
    return (rows as List)
        .map((r) => BrewSession.fromJson(r as Map<String, dynamic>))
        .toList();
  }

  /// Jüngster Sud (= "Currently Brewing" wenn endDate in der Zukunft / heute).
  Future<BrewSession?> fetchYoungestSession() async {
    final rows = await _t('brew_sessions')
        .select()
        .order('start_date', ascending: false)
        .limit(1);
    final list = rows as List;
    if (list.isEmpty) return null;
    return BrewSession.fromJson(list.first as Map<String, dynamic>);
  }

  /// Aktiv-Status: jüngster Sud, dessen Ende noch in der Zukunft liegt
  /// (oder höchstens 24h alt — Telemetry-Lag).
  Future<bool> isBrewing() async {
    final s = await fetchYoungestSession();
    if (s == null) return false;
    final end = s.effectiveEnd;
    return end.isAfter(DateTime.now().subtract(const Duration(hours: 24)));
  }

  /// Aktualisiert Custom-Dates einer brew_session.
  /// owner wird NICHT im Update-Map gesetzt: die RLS USING-Policy
  /// (owner = auth.uid()) macht fremde Rows für diesen Update unsichtbar
  /// (Update trifft 0 Rows statt fremde zu ändern). owner bleibt unverändert.
  Future<void> updateCustomDates(
    String id, {
    DateTime? customStart,
    DateTime? customEnd,
  }) async {
    await _t('brew_sessions').update({
      'custom_start_date': customStart?.toUtc().toIso8601String(),
      'custom_end_date': customEnd?.toUtc().toIso8601String(),
    }).eq('id', id);
  }

  Future<BrewSession?> fetchSession(String id) async {
    final rows = await _t('brew_sessions').select().eq('id', id);
    final list = rows as List;
    if (list.isEmpty) return null;
    return BrewSession.fromJson(list.first as Map<String, dynamic>);
  }

  /// Erstellt eine manuelle BrewSession (ohne RAPT-Profil-Zuordnung).
  /// profile_id = 'manual.&lt;uuid&gt;' damit Worker es nicht überschreibt.
  /// Stempelt owner = auth.uid() damit die RLS WITH CHECK Policy greift.
  Future<BrewSession> createManualSession({
    required String name,
    required DateTime start,
    required DateTime end,
  }) async {
    final uid = Supabase.instance.client.auth.currentUser?.id;
    if (uid == null) {
      throw StateError(
        'createManualSession: kein eingeloggter User — '
        'bitte zuerst anmelden.',
      );
    }
    final uuid = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
    final pid = 'manual.$uuid';
    final rows = await _t('brew_sessions').insert({
      'profile_id': pid,
      'name': name,
      'start_date': start.toUtc().toIso8601String(),
      'end_date': end.toUtc().toIso8601String(),
      'is_manual': true,
      'owner': uid,
    }).select();
    return BrewSession.fromJson((rows as List).first as Map<String, dynamic>);
  }

  /// Phasen aus der Telemetrie: pro profile_id (inkl. NULL) MIN/MAX + Anzahl Punkte.
  /// Für die DeviceDetailsPage — zeigt was im Controller alles drin war,
  /// auch unzugeordnete Phasen.
  Future<List<DeviceActivityPhase>> fetchControllerActivity(String deviceId) async {
    // PostgREST kann GROUP BY nicht direkt, aber mit RPC-Funktion oder mit
    // einem View. Workaround: holen wir distinct profile_ids + min/max einzeln.
    // Einfacher: einen kleinen SQL-View einmal anlegen — siehe device_activity.
    final rows = await _client
        .schema('rapt')
        .from('device_activity_controllers')
        .select()
        .eq('device_id', deviceId)
        .order('last_seen', ascending: false);
    return (rows as List).map((r) {
      final m = r as Map<String, dynamic>;
      return DeviceActivityPhase(
        deviceId: m['device_id'] as String,
        profileId: m['profile_id'] as String?,
        profileName: m['profile_name'] as String?,
        sessionIndex: (m['session_index'] as num?)?.toInt() ?? 1,
        firstSeen: DateTime.parse(m['first_seen'] as String),
        lastSeen: DateTime.parse(m['last_seen'] as String),
        pointCount: (m['point_count'] as num).toInt(),
      );
    }).toList();
  }

  // ---------------------------------------------------------------------------
  // Telemetrie (per Sud, also nach profile_id + Zeitraum)
  // ---------------------------------------------------------------------------

  /// [profileId] = null → keine Profile-Filterung (für manuelle Sessions oder
  /// Zeitbereiche ohne Profile-Zuordnung in der Telemetrie).
  Future<List<ControllerTelemetryPoint>> fetchControllerTelemetry({
    String? profileId,
    required DateTime from,
    required DateTime to,
  }) async {
    var q = _t('telemetry_controllers')
        .select('created_on, temperature, target_temperature, profile_id')
        .gte('created_on', from.toUtc().toIso8601String())
        .lte('created_on', to.toUtc().toIso8601String());
    if (profileId != null) {
      q = q.eq('profile_id', profileId);
    }
    final rows = await q.order('created_on', ascending: true);
    return (rows as List)
        .map((r) => ControllerTelemetryPoint.fromJson(r as Map<String, dynamic>))
        .toList();
  }

  /// Hydrometer hat keine profile_id-Spalte (gleicher Brewer aber unabhängiges Gerät),
  /// daher filtern wir auf Zeitraum.
  Future<List<HydrometerTelemetryPoint>> fetchHydrometerTelemetry({
    required DateTime from,
    required DateTime to,
  }) async {
    final rows = await _t('telemetry_hydrometers')
        .select('created_on, temperature, gravity, battery')
        .gte('created_on', from.toUtc().toIso8601String())
        .lte('created_on', to.toUtc().toIso8601String())
        .order('created_on', ascending: true);
    return (rows as List)
        .map((r) => HydrometerTelemetryPoint.fromJson(r as Map<String, dynamic>))
        .toList();
  }

  /// Mergt Controller- und Hydrometer-Telemetrie zu vereinheitlichten
  /// Datenpunkten (chronologisch sortiert), wie sie der TelemetryProcessor /
  /// die RaptTelemetryView erwartet.
  /// [profileId] = null → keine Profile-Filterung beim Controller (für manuelle
  /// Sessions). Hydrometer hat keine profile_id-Spalte, also immer Date-only.
  Future<List<UnifiedTelemetryPoint>> fetchUnifiedTelemetry({
    String? profileId,
    required DateTime from,
    required DateTime to,
  }) async {
    final ctrl = await fetchControllerTelemetry(profileId: profileId, from: from, to: to);
    final hyd = await fetchHydrometerTelemetry(from: from, to: to);
    final unified = <UnifiedTelemetryPoint>[
      for (final c in ctrl)
        UnifiedTelemetryPoint(
          createdOn: c.ts,
          temperature: c.temperature,
          targetTemperature: c.targetTemperature,
        ),
      for (final h in hyd)
        UnifiedTelemetryPoint(
          createdOn: h.ts,
          temperature: h.temperature,
          // RAPT API liefert Gravity als *1000 Werte (z.B. 1052.7 statt 1.0527).
          // normalizeGravity teilt Werte >500 durch 1000 → echter SG-Wert.
          gravity: UnifiedTelemetryPoint.normalizeGravity(h.gravity),
          battery: h.battery,
        ),
    ]..sort((a, b) => a.createdOn.compareTo(b.createdOn));
    return unified;
  }

  // ---------------------------------------------------------------------------
  // User Profile (multi-tenant — reads own row via auth.uid() + RLS)
  // ---------------------------------------------------------------------------

  /// Loads the profile row for the currently signed-in user.
  /// RLS enforces that only the owner's row is returned; a plain
  /// .maybeSingle() without an explicit eq() is therefore sufficient,
  /// but we also add the eq() for defence-in-depth and clarity.
  Future<UserProfile?> fetchUserProfile() async {
    final uid = Supabase.instance.client.auth.currentUser?.id;
    if (uid == null) return null;
    final row = await _t('user_profiles')
        .select()
        .eq('id', uid)
        .maybeSingle();
    if (row == null) return null;
    return UserProfile.fromJson(row);
  }

  /// Saves the non-secret profile fields (name, avatar_blob) via a plain
  /// upsert. The RAPT API key is NOT written here — use [setRaptCreds].
  Future<void> upsertUserProfile(UserProfile p) async {
    await _t('user_profiles').upsert(p.toJson());
  }

  /// Writes (or clears) RAPT credentials via the `rapt.set_my_rapt_creds`
  /// RPC. The API key is stored encrypted in the vault — never in a
  /// client-readable column.
  ///
  /// Pass [apiKey] as null or empty string to clear the stored key.
  Future<void> setRaptCreds(String raptUserId, String? apiKey) async {
    await _client.schema('rapt').rpc(
      'set_my_rapt_creds',
      params: {
        'p_rapt_user_id': raptUserId,
        'p_api_key': (apiKey?.isEmpty ?? true) ? null : apiKey,
      },
    );
  }

  // ---------------------------------------------------------------------------
  // Devices (Stammdaten — Controller + Hydrometer)
  // ---------------------------------------------------------------------------

  Future<List<Device>> fetchDevices() async {
    final ctrl = await _t('controllers').select().order('name');
    final hyd = await _t('hydrometers').select().order('name');
    return [
      ...(ctrl as List).map((r) => Device.fromJson(r as Map<String, dynamic>, 'controller')),
      ...(hyd as List).map((r) => Device.fromJson(r as Map<String, dynamic>, 'hydrometer')),
    ];
  }
}

final raptRepositoryProvider = Provider<RaptRepository>((ref) {
  return RaptRepository(Supabase.instance.client);
});
