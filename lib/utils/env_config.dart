import 'package:flutter_dotenv/flutter_dotenv.dart';

/// Runtime-Konfiguration: leitet Backend-URLs aus dem aktuellen Hostname ab.
/// Lokal → http://localhost:54331 (kong-rapt) / :8085
/// VPS   → https://db-rapt.[domain] / https://api-rapt.[domain]
///
/// SUPABASE_URL und PROXY_URL sind via dotenv .env Asset override-fähig.
/// Leer/nicht gesetzt → Hostname-Ableitung (Single-VPS-Default).
class EnvConfig {
  static bool _isLocalHost() {
    final h = Uri.base.host;
    return h == 'localhost' || h == '127.0.0.1' || h.isEmpty;
  }

  static String _baseDomain() =>
      Uri.base.host.replaceFirst(RegExp(r'^[^.]+\.'), '');

  /// Supabase Kong Gateway URL — eigene Lean-Supabase des rapt-Stacks.
  /// Override via .env (SUPABASE_URL); lokal: kong-rapt :54331; non-local: `db-rapt.[domain]`.
  static String supabaseUrl() {
    final override = dotenv.env['SUPABASE_URL'];
    if (override != null && override.isNotEmpty) return override;
    if (_isLocalHost()) return 'http://localhost:54331';
    return 'https://db-rapt.${_baseDomain()}';
  }

  /// RAPT-Proxy URL (für /api/rapt, …).
  /// Override via .env (PROXY_URL); non-local-Default: `api-rapt.[domain]/api`.
  static String proxyUrl() {
    final override = dotenv.env['PROXY_URL'];
    if (override != null && override.isNotEmpty) return override;
    if (_isLocalHost()) return 'http://localhost:8085/api';
    return 'https://api-rapt.${_baseDomain()}/api';
  }

  static String supabaseAnonKey() => dotenv.env['SUPABASE_ANON_KEY'] ?? '';
}
