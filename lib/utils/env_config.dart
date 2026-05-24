import 'package:flutter_dotenv/flutter_dotenv.dart';

/// Runtime-Konfiguration: leitet Backend-URLs aus dem aktuellen Hostname ab.
/// Lokal → http://localhost:54321 / :8083
/// VPS   → https://supabase.[domain] / https://api.[domain]
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

  /// Supabase Kong Gateway URL.
  /// Override via .env (SUPABASE_URL); non-local-Default: `supabase.[domain]` (kanonisch).
  static String supabaseUrl() {
    final override = dotenv.env['SUPABASE_URL'];
    if (override != null && override.isNotEmpty) return override;
    if (_isLocalHost()) return 'http://localhost:54321';
    return 'https://supabase.${_baseDomain()}';
  }

  /// Brew-Proxy URL (für /api/rapt, /api/openai, …).
  /// Override via .env (PROXY_URL); non-local-Default: `api.[domain]/api`.
  static String proxyUrl() {
    final override = dotenv.env['PROXY_URL'];
    if (override != null && override.isNotEmpty) return override;
    if (_isLocalHost()) return 'http://localhost:8083/api';
    return 'https://api.${_baseDomain()}/api';
  }

  static String supabaseAnonKey() => dotenv.env['SUPABASE_ANON_KEY'] ?? '';
}
