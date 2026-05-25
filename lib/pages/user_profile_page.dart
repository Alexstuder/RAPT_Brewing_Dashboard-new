import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/brew_session.dart';
import '../services/rapt_repository.dart';

// #3B82F6 on #020617 = 5.48:1 — passes WCAG 2.1 AA body-text (≥4.5:1)
const _kSectionHeaderColor = Color(0xFF3B82F6);

class UserProfilePage extends ConsumerStatefulWidget {
  const UserProfilePage({super.key});
  @override
  ConsumerState<UserProfilePage> createState() => _UserProfilePageState();
}

class _UserProfilePageState extends ConsumerState<UserProfilePage> {
  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _raptUserId = TextEditingController();
  final _raptApiKey = TextEditingController();

  bool _loading = true;
  bool _saving = false;
  bool _raptConfigured = false;
  bool _apiKeyVisible = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _name.dispose();
    _raptUserId.dispose();
    _raptApiKey.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final repo = ref.read(raptRepositoryProvider);
      final p = await repo.fetchUserProfile();
      if (!mounted) return;
      if (p != null) {
        _name.text = p.name;
        _raptUserId.text = p.raptUserId ?? '';
        _raptConfigured = p.raptConfigured;
      }
      setState(() => _loading = false);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  Future<void> _save() async {
    if (!(_formKey.currentState?.validate() ?? true)) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final repo = ref.read(raptRepositoryProvider);
      final uid = Supabase.instance.client.auth.currentUser!.id;

      // Save non-secret profile fields (name, avatar_blob).
      await repo.upsertUserProfile(UserProfile(
        id: uid,
        name: _name.text.trim(),
      ));

      // Write RAPT credentials via vault RPC only when the API-key field has
      // content. An empty key field means "do not change what is stored".
      // Username-only changes without a key are not applied here — the key is
      // required to set or update credentials (UI hint text reflects this).
      final newKey = _raptApiKey.text.trim();
      final newUserId = _raptUserId.text.trim();
      if (newKey.isNotEmpty) {
        await repo.setRaptCreds(newUserId, newKey);
        // Re-fetch to update the configured flag.
        final updated = await repo.fetchUserProfile();
        if (!mounted) return;
        if (updated != null) {
          setState(() => _raptConfigured = updated.raptConfigured);
        }
        _raptApiKey.clear();
      }

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Profil gespeichert')),
      );
      setState(() => _saving = false);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _saving = false;
      });
    }
  }

  Future<void> _clearRaptCreds() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('RAPT-Key löschen?'),
        content: const Text(
          'Der gespeicherte API-Key wird aus dem Vault entfernt. '
          'Die Telemetrie-Synchronisierung stoppt, bis ein neuer Key hinterlegt wird.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Abbrechen'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(
              backgroundColor: Colors.red.shade700,
            ),
            child: const Text('Löschen'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final repo = ref.read(raptRepositoryProvider);
      await repo.setRaptCreds('', null);
      final updated = await repo.fetchUserProfile();
      if (!mounted) return;
      setState(() {
        _raptConfigured = updated?.raptConfigured ?? false;
        _raptUserId.clear();
        _raptApiKey.clear();
        _saving = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('RAPT-Zugangsdaten gelöscht')),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _saving = false;
      });
    }
  }

  InputDecoration _dec(
    String label, {
    Widget? suffix,
    String? helperText,
  }) =>
      InputDecoration(
        labelText: label,
        suffixIcon: suffix,
        helperText: helperText,
        helperMaxLines: 2,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
      );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF020617),
      appBar: AppBar(
        title: const Text('Profil'),
        backgroundColor: Colors.transparent,
        elevation: 0,
        actions: [
          if (!_loading)
            Semantics(
              label: 'Speichern',
              button: true,
              child: IconButton(
                icon: _saving
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Icon(Icons.save_outlined),
                tooltip: 'Speichern',
                onPressed: _saving ? null : _save,
              ),
            ),
          IconButton(
            icon: const Icon(Icons.logout),
            tooltip: 'Abmelden',
            onPressed: () => Supabase.instance.client.auth.signOut(),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 600),
                child: DefaultTextStyle.merge(
                  style: const TextStyle(color: Colors.white),
                  child: Form(
                    key: _formKey,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                      // Error banner
                      if (_error != null)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 16),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Icon(
                                Icons.error_outline,
                                color: Colors.redAccent,
                                size: 18,
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  'Fehler: $_error',
                                  style: const TextStyle(
                                    color: Colors.redAccent,
                                    height: 1.3,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),

                      // ── Anzeige ───────────────────────────────────────────
                      const _Section('Anzeige'),
                      TextFormField(
                        controller: _name,
                        style: const TextStyle(color: Colors.white),
                        decoration: _dec('Name'),
                        validator: (v) {
                          if (v == null || v.trim().isEmpty) {
                            return 'Name erforderlich';
                          }
                          return null;
                        },
                      ),

                      const SizedBox(height: 24),

                      // ── RAPT.io Zugangsdaten ───────────────────────────────
                      const _Section('RAPT.io Zugangsdaten'),
                      const Text(
                        'Werden vom brew-proxy Worker für den 5-Minuten-Sync der Telemetrie genutzt.',
                        style: TextStyle(color: Colors.white54, fontSize: 12),
                      ),
                      const SizedBox(height: 12),

                      // Status chip
                      _RaptStatusChip(
                        configured: _raptConfigured,
                        saving: _saving,
                        onClear: _clearRaptCreds,
                      ),

                      const SizedBox(height: 12),
                      TextField(
                        controller: _raptUserId,
                        style: const TextStyle(color: Colors.white),
                        decoration: _dec(
                          'RAPT Username (E-Mail)',
                          helperText:
                              'Username und API-Key müssen zusammen gespeichert werden — '
                              'nur der Username allein hat keine Wirkung.',
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _raptApiKey,
                        obscureText: !_apiKeyVisible,
                        style: const TextStyle(color: Colors.white),
                        decoration: _dec(
                          _raptConfigured
                              ? 'Neuer RAPT API-Key (leer lassen = unverändert)'
                              : 'RAPT API-Key',
                          suffix: Semantics(
                            label: _apiKeyVisible
                                ? 'API-Key verbergen'
                                : 'API-Key anzeigen',
                            button: true,
                            child: IconButton(
                              icon: Icon(
                                _apiKeyVisible
                                    ? Icons.visibility_off_outlined
                                    : Icons.visibility_outlined,
                              ),
                              onPressed: () => setState(
                                () => _apiKeyVisible = !_apiKeyVisible,
                              ),
                            ),
                          ),
                        ),
                      ),

                      const SizedBox(height: 24),
                      SizedBox(
                        height: 48,
                        child: FilledButton.icon(
                          onPressed: _saving ? null : _save,
                          icon: _saving
                              ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Colors.white,
                                  ),
                                )
                              : const Icon(Icons.save_outlined),
                          label:
                              Text(_saving ? 'Wird gespeichert…' : 'Speichern'),
                        ),
                      ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
    );
  }
}

/// Status chip for RAPT credentials — icon + text + background, not color-only.
class _RaptStatusChip extends StatelessWidget {
  const _RaptStatusChip({
    required this.configured,
    required this.saving,
    required this.onClear,
  });

  final bool configured;
  final bool saving;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    if (configured) {
      return Row(
        children: [
          Chip(
            avatar: const Icon(
              Icons.check_circle_outline,
              size: 16,
              color: Colors.greenAccent,
            ),
            label: const Text(
              'Key gesetzt',
              style: TextStyle(color: Colors.greenAccent, fontSize: 12),
            ),
            backgroundColor: const Color(0xFF1A4731),
            padding: EdgeInsets.zero,
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          const Spacer(),
          TextButton.icon(
            onPressed: saving ? null : onClear,
            icon: const Icon(Icons.delete_outline, size: 16),
            label: const Text('Key löschen'),
            style: TextButton.styleFrom(
              foregroundColor: Colors.redAccent,
              minimumSize: const Size(48, 48), // WCAG touch target ≥48dp
            ),
          ),
        ],
      );
    }
    return Chip(
      avatar: const Icon(
        Icons.radio_button_unchecked,
        size: 16,
        color: Colors.white54,
      ),
      label: const Text(
        'Kein Key',
        style: TextStyle(color: Colors.white54, fontSize: 12),
      ),
      backgroundColor: const Color(0xFF1E293B),
      padding: EdgeInsets.zero,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
    );
  }
}

class _Section extends StatelessWidget {
  const _Section(this.title);
  final String title;
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        title,
        style: const TextStyle(
          color: _kSectionHeaderColor, // 5.48:1 on #020617 — WCAG AA body text
          fontSize: 16,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }
}
