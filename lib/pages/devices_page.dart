import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../models/brew_session.dart';
import '../services/rapt_repository.dart';
import 'device_details_page.dart';

class DevicesPage extends ConsumerStatefulWidget {
  const DevicesPage({super.key});
  @override
  ConsumerState<DevicesPage> createState() => _DevicesPageState();
}

class _DevicesPageState extends ConsumerState<DevicesPage> {
  bool _loading = true;
  String? _error;
  List<Device> _devices = [];

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
      final list = await repo.fetchDevices();
      if (!mounted) return;
      setState(() {
        _devices = list;
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
    final df = DateFormat('dd.MM.yyyy HH:mm');
    return Scaffold(
      backgroundColor: const Color(0xFF020617),
      appBar: AppBar(
        title: const Text('Devices'),
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
              : _devices.isEmpty
                  ? const Center(
                      child: Padding(
                        padding: EdgeInsets.all(32),
                        child: Text(
                          'Noch keine Geräte. Hinterlege deinen RAPT-Key im Profil — '
                          'der Sync holt deine Geräte dann automatisch.',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Colors.white54),
                        ),
                      ),
                    )
                  : ListView.separated(
                  padding: const EdgeInsets.all(16),
                  itemCount: _devices.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 8),
                  itemBuilder: (context, i) {
                    final d = _devices[i];
                    return Card(
                      color: const Color(0xFF0F172A),
                      child: ListTile(
                        leading: Icon(
                            d.kind == 'controller'
                                ? Icons.thermostat
                                : Icons.water_drop_outlined,
                            color: const Color(0xFF2563EB)),
                        title: Text(d.name,
                            style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.bold)),
                        subtitle: Text(
                            '${d.kind}  ${d.lastSeen != null ? '· last seen ${df.format(d.lastSeen!.toLocal())}' : ''}',
                            style: const TextStyle(color: Colors.white60)),
                        trailing: const Icon(Icons.arrow_forward_ios,
                            size: 14, color: Colors.white38),
                        onTap: () => Navigator.push(
                          context,
                          MaterialPageRoute(builder: (_) => DeviceDetailsPage(device: d)),
                        ),
                      ),
                    );
                  },
                ),
    );
  }
}
