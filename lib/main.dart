import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'pages/auth_page.dart';
import 'pages/landing_page.dart';
import 'utils/cookie_session_storage.dart';
import 'utils/env_config.dart';
import 'utils/session_sync_widget.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeDateFormatting('de_DE', null);
  await dotenv.load(fileName: '.env');

  await Supabase.initialize(
    url: EnvConfig.supabaseUrl(),
    anonKey: EnvConfig.supabaseAnonKey(),
    postgrestOptions: const PostgrestClientOptions(schema: 'rapt'),
    authOptions: FlutterAuthClientOptions(localStorage: CookieSessionStorage()),
  );

  runApp(
    const ProviderScope(
      child: SessionSyncWidget(child: RaptDashboardApp()),
    ),
  );
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
