import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:intl/date_symbol_data_local.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:web/web.dart' as web;

import 'pages/auth_page.dart';
import 'pages/landing_page.dart';
import 'utils/env_config.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeDateFormatting('de_DE', null);
  await dotenv.load(fileName: '.env');

  await Supabase.initialize(
    url: EnvConfig.supabaseUrl(),
    anonKey: EnvConfig.supabaseAnonKey(),
    postgrestOptions: const PostgrestClientOptions(schema: 'rapt'),
  );

  // SSO-Ticket einlösen, falls das URL-Fragment `sso=<ticket>` enthält.
  await _redeemSsoTicketIfPresent();

  runApp(
    const ProviderScope(
      child: RaptDashboardApp(),
    ),
  );
}

/// Parst das URL-Fragment nach `sso=<ticket>`. Gibt null zurück wenn keines vorhanden.
String? _extractSsoTicket() {
  final fragment = Uri.base.fragment;
  if (fragment.isEmpty) return null;
  final params = Uri.splitQueryString(fragment);
  final ticket = params['sso'];
  return (ticket != null && ticket.isNotEmpty) ? ticket : null;
}

/// Entfernt das Fragment aus der Browser-URL (kein Reload, kein History-Eintrag).
void _clearFragment() {
  try {
    final url = '${web.window.location.pathname}${web.window.location.search}';
    web.window.history.replaceState(null, '', url);
  } catch (e) {
    debugPrint('SSO: Fragment-Clearing fehlgeschlagen: $e');
  }
}

/// Löst das SSO-Ticket über den rapt-Proxy ein und setzt die Supabase-Session.
/// Wird nur aufgerufen wenn ein Ticket im Fragment vorhanden und noch keine
/// Session aktiv ist.
Future<void> _redeemSsoTicketIfPresent() async {
  final ticket = _extractSsoTicket();
  if (ticket == null) return;

  // Fragment immer entfernen — egal ob Redeem erfolgreich oder nicht.
  _clearFragment();

  // Kein Doppel-Redeem wenn bereits eingeloggt.
  final auth = Supabase.instance.client.auth;
  if (auth.currentSession != null) {
    debugPrint('SSO: Session bereits vorhanden — Ticket verworfen.');
    return;
  }

  debugPrint('SSO: Löse Ticket ein …');
  try {
    final uri = Uri.parse('${EnvConfig.proxyUrl()}/sso/redeem');
    final response = await http.post(
      uri,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'ticket': ticket}),
    );

    if (response.statusCode != 200) {
      debugPrint('SSO: Redeem fehlgeschlagen (HTTP ${response.statusCode}) — normaler Login-Flow.');
      return;
    }

    final body = jsonDecode(response.body) as Map<String, dynamic>;
    final refreshToken = body['refresh_token'] as String?;
    final accessToken = body['access_token'] as String?;

    if (refreshToken == null || refreshToken.isEmpty) {
      debugPrint('SSO: Proxy-Antwort enthält keinen refresh_token — normaler Login-Flow.');
      return;
    }

    await auth.setSession(refreshToken, accessToken: accessToken);
    debugPrint('SSO: Session erfolgreich gesetzt.');
  } catch (e) {
    debugPrint('SSO: Redeem-Fehler: $e — normaler Login-Flow.');
  }
}

class RaptDashboardApp extends StatelessWidget {
  const RaptDashboardApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'RAPT Brewing Dashboard',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        colorScheme: const ColorScheme.dark(primary: Color(0xFF2563EB)),
      ),
      home: const AuthGate(signedIn: LandingPage()),
    );
  }
}

/// Wraps the app: shows AuthPage when no session, [signedIn] when a session
/// exists. Listens to onAuthStateChange so login/logout transitions are
/// reflected immediately.
class AuthGate extends StatefulWidget {
  const AuthGate({super.key, required this.signedIn});

  final Widget signedIn;

  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  @override
  Widget build(BuildContext context) {
    return StreamBuilder<AuthState>(
      stream: Supabase.instance.client.auth.onAuthStateChange,
      builder: (context, snapshot) {
        final session = Supabase.instance.client.auth.currentSession;

        // While the stream is still connecting (cold-start token refresh),
        // show the signed-in view if a session is already cached, or a
        // spinner if there is no session yet — avoids a false Auth-page flash.
        if (snapshot.connectionState == ConnectionState.waiting) {
          if (session != null) return widget.signedIn;
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }

        if (session == null) {
          return const AuthPage();
        }
        return widget.signedIn;
      },
    );
  }
}
