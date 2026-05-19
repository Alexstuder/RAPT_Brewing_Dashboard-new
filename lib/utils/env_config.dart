import 'package:flutter_dotenv/flutter_dotenv.dart';

/// Runtime-Konfiguration: leitet Backend-URLs aus dem aktuellen Hostname ab.
/// Lokal → http://localhost:54321 / :8083
/// VPS   → https://db.<domain> / https://api.<domain>
class EnvConfig {
  static bool _isLocalHost() {
    final h = Uri.base.host;
    return h == 'localhost' || h == '127.0.0.1' || h.isEmpty;
  }

  static String _baseDomain() =>
      Uri.base.host.replaceFirst(RegExp(r'^[^.]+\.'), '');

  static String supabaseUrl() {
    if (_isLocalHost()) return 'http://localhost:54321';
    return 'https://db.${_baseDomain()}';
  }

  static String proxyUrl() {
    if (_isLocalHost()) return 'http://localhost:8083/api';
    return 'https://api.${_baseDomain()}/api';
  }

  static String supabaseAnonKey() => dotenv.env['SUPABASE_ANON_KEY'] ?? '';
}
