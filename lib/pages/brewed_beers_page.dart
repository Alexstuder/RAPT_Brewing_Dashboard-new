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
      // Server sortiert nach start_date; client-side nach effectiveStart
      // sortieren damit Custom-Dates die Reihenfolge bestimmen.
      list.sort((a, b) => b.effectiveStart.compareTo(a.effectiveStart));
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
                      child: Padding(
                        padding: EdgeInsets.all(32),
                        child: Text(
                          'Noch keine Sude. Sobald dein RAPT-Sync läuft, erscheinen deine Biere hier.',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Colors.white54),
                        ),
                      ),
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.all(16),
                      itemCount: _sessions.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 8),
                      itemBuilder: (context, i) {
                        final s = _sessions[i];
                        final df = DateFormat('dd.MM.yyyy HH:mm');
                        final start = df.format(s.effectiveStart.toLocal());
                        final end = df.format(s.effectiveEnd.toLocal());
                        final dur = s.effectiveEnd.difference(s.effectiveStart);
                        final days = dur.inDays;
                        final hours = dur.inHours % 24;
                        final durStr = days > 0 ? '${days}d ${hours}h' : '${dur.inHours}h';
                        final hasCustom = s.customStartDate != null || s.customEndDate != null;
                        return Card(
                          color: const Color(0xFF0F172A),
                          child: ListTile(
                            title: Row(
                              children: [
                                Expanded(
                                  child: Text(s.name,
                                      style: const TextStyle(
                                          color: Colors.white,
                                          fontWeight: FontWeight.bold)),
                                ),
                                if (hasCustom)
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                    decoration: BoxDecoration(
                                      color: Colors.amber.withValues(alpha: 0.15),
                                      borderRadius: BorderRadius.circular(4),
                                    ),
                                    child: const Text('custom',
                                        style: TextStyle(color: Colors.amber, fontSize: 10)),
                                  ),
                              ],
                            ),
                            subtitle: Text('$start  →  $end  ($durStr)',
                                style: const TextStyle(color: Colors.white60)),
                            trailing: const Icon(Icons.arrow_forward_ios,
                                size: 16, color: Colors.white38),
                            onTap: () async {
                              await Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (_) =>
                                      BrewSessionDetailsPage(session: s),
                                ),
                              );
                              // Liste neu laden, weil sich custom_*_date in der
                              // Detail-Page geändert haben könnte.
                              if (mounted) _load();
                            },
                          ),
                        );
                      },
                    ),
    );
  }
}
