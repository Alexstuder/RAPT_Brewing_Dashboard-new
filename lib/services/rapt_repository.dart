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

  Future<void> updateCustomDates(
    String profileId, {
    DateTime? customStart,
    DateTime? customEnd,
  }) async {
    await _t('brew_sessions').update({
      'custom_start_date': customStart?.toUtc().toIso8601String(),
      'custom_end_date': customEnd?.toUtc().toIso8601String(),
    }).eq('profile_id', profileId);
  }

  Future<BrewSession?> fetchSession(String profileId) async {
    final rows = await _t('brew_sessions').select().eq('profile_id', profileId);
    final list = rows as List;
    if (list.isEmpty) return null;
    return BrewSession.fromJson(list.first as Map<String, dynamic>);
  }

  // ---------------------------------------------------------------------------
  // Telemetrie (per Sud, also nach profile_id + Zeitraum)
  // ---------------------------------------------------------------------------

  Future<List<ControllerTelemetryPoint>> fetchControllerTelemetry({
    required String profileId,
    required DateTime from,
    required DateTime to,
  }) async {
    final rows = await _t('telemetry_controllers')
        .select('created_on, temperature, target_temperature, profile_id')
        .eq('profile_id', profileId)
        .gte('created_on', from.toUtc().toIso8601String())
        .lte('created_on', to.toUtc().toIso8601String())
        .order('created_on', ascending: true);
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
  Future<List<UnifiedTelemetryPoint>> fetchUnifiedTelemetry({
    required String profileId,
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
  // User Profile (single-user jetzt, multi-user-ready)
  // ---------------------------------------------------------------------------

  Future<UserProfile?> fetchUserProfile({String id = 'default'}) async {
    final rows = await _t('user_profiles').select().eq('id', id);
    final list = rows as List;
    if (list.isEmpty) return null;
    return UserProfile.fromJson(list.first as Map<String, dynamic>);
  }

  Future<void> upsertUserProfile(UserProfile p) async {
    await _t('user_profiles').upsert(p.toJson());
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
