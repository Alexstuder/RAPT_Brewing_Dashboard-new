import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/brew_session.dart';
import '../services/rapt_repository.dart';

class UserProfilePage extends ConsumerStatefulWidget {
  const UserProfilePage({super.key});
  @override
  ConsumerState<UserProfilePage> createState() => _UserProfilePageState();
}

class _UserProfilePageState extends ConsumerState<UserProfilePage> {
  final _name = TextEditingController();
  final _raptUserId = TextEditingController();
  final _raptApiKey = TextEditingController();

  bool _loading = true;
  bool _saving = false;
  String? _error;
  bool _obscureRapt = true;

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
        _raptApiKey.text = p.raptApiKey ?? '';
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
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final repo = ref.read(raptRepositoryProvider);
      await repo.upsertUserProfile(UserProfile(
        id: 'default',
        name: _name.text.trim(),
        raptUserId: _emptyToNull(_raptUserId.text),
        raptApiKey: _emptyToNull(_raptApiKey.text),
      ));
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

  static String? _emptyToNull(String s) => s.trim().isEmpty ? null : s.trim();

  InputDecoration _dec(String label, {Widget? suffix}) => InputDecoration(
        labelText: label,
        labelStyle: const TextStyle(color: Colors.white60),
        suffixIcon: suffix,
        filled: true,
        fillColor: const Color(0xFF0F172A),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
      );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF020617),
      appBar: AppBar(
        title: const Text('User Profile'),
        backgroundColor: Colors.transparent,
        elevation: 0,
        actions: [
          if (!_loading)
            IconButton(
              icon: _saving
                  ? const SizedBox(
                      width: 18, height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.save),
              onPressed: _saving ? null : _save,
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
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (_error != null)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 16),
                          child: Text('Fehler: $_error',
                              style: const TextStyle(color: Colors.redAccent)),
                        ),

                      const _Section('Anzeige'),
                      TextField(
                        controller: _name,
                        style: const TextStyle(color: Colors.white),
                        decoration: _dec('Name'),
                      ),

                      const SizedBox(height: 24),

                      const _Section('RAPT.io Credentials'),
                      const Text(
                          'Werden vom brew-proxy Worker für den 5-Minuten-Sync der Telemetrie genutzt.',
                          style: TextStyle(color: Colors.white54, fontSize: 12)),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _raptUserId,
                        style: const TextStyle(color: Colors.white),
                        decoration: _dec('RAPT Username (E-Mail)'),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _raptApiKey,
                        obscureText: _obscureRapt,
                        style: const TextStyle(color: Colors.white),
                        decoration: _dec(
                          'RAPT API Key',
                          suffix: IconButton(
                            icon: Icon(_obscureRapt
                                ? Icons.visibility
                                : Icons.visibility_off),
                            onPressed: () =>
                                setState(() => _obscureRapt = !_obscureRapt),
                          ),
                        ),
                      ),

                      const SizedBox(height: 24),
                      FilledButton.icon(
                        onPressed: _saving ? null : _save,
                        icon: const Icon(Icons.save),
                        label: const Text('Speichern'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
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
      child: Text(title,
          style: const TextStyle(
              color: Color(0xFF2563EB),
              fontSize: 16,
              fontWeight: FontWeight.bold)),
    );
  }
}
