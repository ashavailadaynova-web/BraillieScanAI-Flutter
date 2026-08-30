import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../services/database_service.dart';
import '../services/scan_flow.dart';
import 'scan_screen.dart';

/// Layar utama (Home): tombol "Mulai Scan" yang besar dan daftar riwayat
/// scan tersimpan di SQLite di bawahnya.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final DatabaseService _database = DatabaseService.instance;
  final ScanFlow _scanFlow = ScanFlow();

  bool _uploading = false;

  List<ScanRecord> _records = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadHistory();
  }

  Future<void> _loadHistory() async {
    try {
      final List<ScanRecord> records = await _database.getAllRecords();
      if (!mounted) return;
      setState(() {
        _records = records;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  Future<void> _startScan() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const ScanScreen()),
    );
    _loadHistory();
  }

  Future<void> _uploadFromGallery() async {
    if (_uploading) return;
    setState(() => _uploading = true);
    try {
      await _scanFlow.pickAndProcessFromGallery(context);
    } finally {
      if (mounted) setState(() => _uploading = false);
      _loadHistory();
    }
  }

  @override
  void dispose() {
    _scanFlow.dispose();
    super.dispose();
  }

  Future<void> _confirmDelete(ScanRecord record) async {
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('Hapus riwayat'),
        content: const Text('Hapus rekaman scan ini dari riwayat?'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Batal'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Hapus'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;
    await _database.deleteRecord(record.id);
    _loadHistory();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('BrailleScan AI'),
        centerTitle: true,
      ),
      body: Column(
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Column(
              children: <Widget>[
                SizedBox(
                  width: double.infinity,
                  height: 64,
                  child: FilledButton.icon(
                    onPressed: _startScan,
                    icon: const Icon(Icons.center_focus_strong, size: 28),
                    label: const Text(
                      'Mulai Scan (Kamera)',
                      style: TextStyle(fontSize: 18),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  height: 56,
                  child: OutlinedButton.icon(
                    onPressed: _uploading ? null : _uploadFromGallery,
                    icon: _uploading
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child:
                                CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.upload_file_outlined, size: 26),
                    label: const Text(
                      'Upload Gambar dari Galeri',
                      style: TextStyle(fontSize: 16),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'Riwayat Scan',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
            ),
          ),
          Expanded(child: _buildHistoryList()),
        ],
      ),
    );
  }

  Widget _buildHistoryList() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_records.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: 32),
          child: Text(
            'Belum ada riwayat scan.\n\n'
            'Tekan "Mulai Scan" untuk mengambil gambar dokumen Braille '
            'dan lihat hasil terjemahannya di sini.',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    return ListView.separated(
      itemCount: _records.length,
      separatorBuilder: (BuildContext _, int __) =>
          const Divider(height: 1, indent: 16),
      itemBuilder: (BuildContext context, int index) {
        final ScanRecord record = _records[index];
        return ListTile(
          leading: const CircleAvatar(child: Icon(Icons.description_outlined)),
          title: Text(
            record.text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Text(
            DateFormat('dd/MM/yyyy HH:mm').format(record.timestamp),
          ),
          trailing: IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: 'Hapus',
            onPressed: () => _confirmDelete(record),
          ),
        );
      },
    );
  }
}