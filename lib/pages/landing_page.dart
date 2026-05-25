import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../services/rapt_repository.dart';
import 'brewed_beers_page.dart';
import 'brew_session_details_page.dart';
import 'devices_page.dart';
import 'user_profile_page.dart';

class LandingPage extends ConsumerStatefulWidget {
  const LandingPage({super.key});
  @override
  ConsumerState<LandingPage> createState() => _LandingPageState();
}

class _LandingPageState extends ConsumerState<LandingPage> {
  bool _isBrewing = false;

  @override
  void initState() {
    super.initState();
    _checkBrewing();
  }

  Future<void> _checkBrewing() async {
    try {
      final repo = ref.read(raptRepositoryProvider);
      final brewing = await repo.isBrewing();
      if (mounted) setState(() => _isBrewing = brewing);
    } catch (e) {
      debugPrint('LandingPage: isBrewing check failed: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('RAPT Brewing'),
        backgroundColor: Colors.transparent,
        elevation: 0,
        actions: [
          IconButton(
            icon: const Icon(Icons.logout),
            tooltip: 'Abmelden',
            onPressed: () => Supabase.instance.client.auth.signOut(),
          ),
        ],
      ),
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              Theme.of(context).colorScheme.surface,
              Theme.of(context).colorScheme.primary.withValues(alpha: 0.1),
            ],
          ),
        ),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  Icons.water_drop_outlined,
                  size: 80,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(height: 24),
                Text(
                  'RAPT Brewing',
                  style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                        letterSpacing: 1.2,
                      ),
                ),
                const SizedBox(height: 48),
                _LandingButton(
                  title: 'Gebraute Biere',
                  icon: Icons.local_drink_outlined,
                  onPressed: () => Navigator.push(context,
                      MaterialPageRoute(builder: (_) => const BrewedBeersPage())),
                ),
                const SizedBox(height: 16),
                if (_isBrewing)
                  _LandingButton(
                    title: 'Aktiver Sud',
                    icon: Icons.timer_outlined,
                    onPressed: () async {
                      final repo = ref.read(raptRepositoryProvider);
                      final s = await repo.fetchYoungestSession();
                      if (!context.mounted || s == null) return;
                      Navigator.push(
                          context,
                          MaterialPageRoute(
                              builder: (_) =>
                                  BrewSessionDetailsPage(session: s)));
                    },
                  ),
                if (_isBrewing) const SizedBox(height: 16),
                _LandingButton(
                  title: 'Profil',
                  icon: Icons.person_outline,
                  onPressed: () => Navigator.push(context,
                      MaterialPageRoute(builder: (_) => const UserProfilePage())),
                ),
                const SizedBox(height: 16),
                _LandingButton(
                  title: 'Geräte',
                  icon: Icons.device_thermostat,
                  onPressed: () => Navigator.push(context,
                      MaterialPageRoute(builder: (_) => const DevicesPage())),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _LandingButton extends StatelessWidget {
  const _LandingButton(
      {required this.title, required this.icon, required this.onPressed});
  final String title;
  final IconData icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 40),
      child: ElevatedButton(
        style: ElevatedButton.styleFrom(
          padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 24),
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16)),
          backgroundColor:
              Theme.of(context).colorScheme.primary.withValues(alpha: 0.1),
          foregroundColor: Colors.white,
          elevation: 0,
        ).copyWith(
          side: WidgetStateProperty.all(
            BorderSide(
                color: Theme.of(context)
                    .colorScheme
                    .primary
                    .withValues(alpha: 0.3),
                width: 1),
          ),
        ),
        onPressed: onPressed,
        child: Row(
          children: [
            Icon(icon, size: 28),
            const SizedBox(width: 16),
            Text(title,
                style: const TextStyle(
                    fontSize: 18, fontWeight: FontWeight.w600)),
            const Spacer(),
            const Icon(Icons.arrow_forward_ios, size: 16),
          ],
        ),
      ),
    );
  }
}
