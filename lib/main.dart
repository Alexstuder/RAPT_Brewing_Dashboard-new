import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

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

  runApp(const ProviderScope(child: RaptDashboardApp()));
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
      home: const LandingPage(),
    );
  }
}
