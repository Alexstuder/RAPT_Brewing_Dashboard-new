import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../models/brew_session.dart';
import '../services/rapt_repository.dart';
import 'brew_session_details_page.dart';

class BrewedBeersPage extends ConsumerStatefulWidget {
  const BrewedBeersPage({super.key});
  @override
  ConsumerState<BrewedBeersPage> createState() => _BrewedBeersPageState();
}

class _BrewedBeersPageState extends ConsumerState<BrewedBeersPage> {
  bool _loading = true;
  String? _error;
  List<BrewSession> _sessions = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final repo = ref.read(raptRepositoryProvider);
      final list = await repo.fetchBrewSessions();
      if (!mounted) return;
      setState(() {
        _sessions = list;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF020617),
      appBar: AppBar(
        title: const Text('Gebraute Biere'),
        backgroundColor: Colors.transparent,
        elevation: 0,
        actions: [
          IconButton(icon: const Icon(Icons.refresh), onPressed: _load),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text('Fehler: $_error',
                        style: const TextStyle(color: Colors.redAccent)),
                  ),
                )
              : _sessions.isEmpty
                  ? const Center(
                      child: Text(
                        'Noch keine Sude in der Datenbank.\nbrew-proxy synct alle 5 Min.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.white54),
                      ),
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.all(16),
                      itemCount: _sessions.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 8),
                      itemBuilder: (context, i) {
                        final s = _sessions[i];
                        final start = DateFormat('dd.MM.yyyy').format(s.startDate);
                        final end = DateFormat('dd.MM.yyyy').format(s.endDate);
                        final days = s.endDate.difference(s.startDate).inDays;
                        return Card(
                          color: const Color(0xFF0F172A),
                          child: ListTile(
                            title: Text(s.name,
                                style: const TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.bold)),
                            subtitle: Text('$start  →  $end  ($days Tage)',
                                style: const TextStyle(color: Colors.white60)),
                            trailing: const Icon(Icons.arrow_forward_ios,
                                size: 16, color: Colors.white38),
                            onTap: () => Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) =>
                                    BrewSessionDetailsPage(session: s),
                              ),
                            ),
                          ),
                        );
                      },
                    ),
    );
  }
}
