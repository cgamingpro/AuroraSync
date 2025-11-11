// lib/main.dart
import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:xml/xml.dart' as xml;
import 'package:path/path.dart' as p;

void main() {
  runApp(const MaterialApp(home: SyncXmlApp()));
}

class SyncXmlApp extends StatefulWidget {
  const SyncXmlApp({super.key});
  @override
  State<SyncXmlApp> createState() => _SyncXmlAppState();
}

class _SyncXmlAppState extends State<SyncXmlApp> {
  final _ipCtrl = TextEditingController();
  final _portCtrl = TextEditingController(text: '5050');
  List<String> watchDirs = [];
  String status = 'Idle';
  Timer? periodicTimer;
  bool syncing = false;

  @override
  void initState() {
    super.initState();
    _loadConfig();
    periodicTimer = Timer.periodic(const Duration(minutes: 15), (_) => _periodicSync());
  }

  @override
  void dispose() {
    periodicTimer?.cancel();
    super.dispose();
  }

  Future<void> _loadConfig() async {
    final prefs = await SharedPreferences.getInstance();
    _ipCtrl.text = prefs.getString('server_ip') ?? '';
    _portCtrl.text = prefs.getString('server_port') ?? '5050';
    watchDirs = prefs.getStringList('watch_dirs') ?? [
      '/storage/emulated/0/DCIM',
      '/storage/emulated/0/Download',
      '/storage/emulated/0/Pictures'
    ];
    setState(() {});
  }

  Future<void> _saveConfig() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('server_ip', _ipCtrl.text.trim());
    await prefs.setString('server_port', _portCtrl.text.trim());
    await prefs.setStringList('watch_dirs', watchDirs);
    setState(() => status = 'Settings saved');
  }

  String get serverBase => 'http://${_ipCtrl.text.trim()}:${_portCtrl.text.trim()}';

  Future<bool> _checkServer() async {
    try {
      final resp = await http.get(Uri.parse('$serverBase/')).timeout(const Duration(seconds: 3));
      return resp.statusCode >= 200 && resp.statusCode < 500;
    } catch (_) {
      return false;
    }
  }

  Future<void> _ensurePermissions() async {
    if (!Platform.isAndroid) return;
    if (!await Permission.manageExternalStorage.isGranted) {
      final st = await Permission.manageExternalStorage.request();
      if (!st.isGranted) {
        await openAppSettings();
      }
    }
  }

  // Build inventory entries by scanning watchDirs (returns list of maps)
  Future<List<Map<String, dynamic>>> _gatherInventoryEntries() async {
    final List<Map<String, dynamic>> entries = [];
    for (final dirPath in watchDirs) {
      final dir = Directory(dirPath);
      if (!await dir.exists()) continue;
      try {
        await for (final fse in dir.list(recursive: true, followLinks: false)) {
          if (fse is File) {
            try {
              final stat = await fse.stat();
              final rel = _computeRel(fse.path);
              final size = await fse.length();
              entries.add({
                'path': fse.path,
                'rel': rel,
                'name': p.basename(fse.path),
                'lastModified': stat.modified.millisecondsSinceEpoch,
                'size': size
              });
            } catch (e) {
              // skip inaccessible file
            }
          }
        }
      } catch (e) {
        // skip inaccessible folder
      }
    }
    return entries;
  }

  String _computeRel(String fullPath) {
    final norm = fullPath.replaceAll('\\', '/');
    const marker = '/storage/emulated/0/';
    if (norm.toLowerCase().contains(marker)) {
      final idx = norm.toLowerCase().indexOf(marker);
      return norm.substring(idx + marker.length);
    }
    // if not under storage root, try to find which watchDir it belongs to
    for (final d in watchDirs) {
      final dNorm = d.replaceAll('\\', '/');
      if (norm.startsWith(dNorm)) {
        return norm.substring(dNorm.length).replaceFirst(RegExp(r'^/+'), '');
      }
    }
    return p.basename(norm);
  }

  // Build XML string from entries
  String _buildInventoryXmlFromEntries(List<Map<String, dynamic>> entries) {
    final builder = xml.XmlBuilder();
    builder.processing('xml', 'version="1.0" encoding="utf-8"');
    builder.element('files', nest: () {
      for (final e in entries) {
        builder.element('file', nest: () {
          builder.element('path', nest: e['path']);
          builder.element('rel', nest: e['rel']);
          builder.element('name', nest: e['name']);
          builder.element('lastModified', nest: e['lastModified'].toString());
          builder.element('size', nest: e['size'].toString());
        });
      }
    });
    return builder.buildDocument().toXmlString(pretty: false);
  }

  Future<List<Map<String, dynamic>>> _sendInventoryAndGetNeeded(String xmlPayload) async {
    final uri = Uri.parse('$serverBase/sync-list');
    final resp = await http.post(uri, headers: {'Content-Type': 'application/xml'}, body: xmlPayload).timeout(const Duration(seconds: 10));
    if (resp.statusCode != 200) throw Exception('Server returned ${resp.statusCode}');
    final doc = xml.XmlDocument.parse(resp.body);
    final needed = <Map<String, dynamic>>[];
    for (final f in doc.findAllElements('file')) {
      final relNode = f.findElements('rel').first;
      final lmNode = f.findElements('lastModified').first;
      final sizeNode = f.findElements('size').first;
      needed.add({
        'rel': relNode.text,
        'lastModified': int.tryParse(lmNode.text) ?? 0,
        'size': int.tryParse(sizeNode.text) ?? 0,
      });
    }
    return needed;
  }

  Future<bool> _uploadOne(String fullPath, String rel, int lastModified, int size) async {
    try {
      final file = File(fullPath);
      if (!file.existsSync()) return false;
      final uri = Uri.parse('$serverBase/upload');
      final req = http.MultipartRequest('POST', uri);
      req.fields['filepath'] = fullPath;
      req.fields['rel'] = rel;
      req.fields['lastModified'] = lastModified.toString();
      req.fields['size'] = size.toString();
      req.files.add(await http.MultipartFile.fromPath('file', fullPath));
      final streamed = await req.send().timeout(const Duration(seconds: 60));
      final respStr = await streamed.stream.bytesToString();
      if (streamed.statusCode == 200) {
        debugPrint('Uploaded $fullPath -> $rel');
        return true;
      } else {
        debugPrint('Upload failed ($streamed.statusCode): $respStr');
        return false;
      }
    } catch (e) {
      debugPrint('Upload exception: $e');
      return false;
    }
  }

  Future<void> doSyncOnce({bool uiUpdate = true}) async {
    if (syncing) return;
    syncing = true;
    if (uiUpdate) setState(() => status = 'Ensuring permissions...');
    await _ensurePermissions();
    if (uiUpdate) setState(() => status = 'Checking server...');
    final ok = await _checkServer();
    if (!ok) {
      if (uiUpdate) setState(() => status = 'Server not reachable at $serverBase');
      syncing = false;
      return;
    }
    if (uiUpdate) setState(() => status = 'Gathering inventory...');
    final entries = await _gatherInventoryEntries();
    final xmlPayload = _buildInventoryXmlFromEntries(entries);

    if (uiUpdate) setState(() => status = 'Sending inventory...');
    List<Map<String, dynamic>> needed;
    try {
      needed = await _sendInventoryAndGetNeeded(xmlPayload);
    } catch (e) {
      if (uiUpdate) setState(() => status = 'Inventory send failed: $e');
      syncing = false;
      return;
    }

    if (needed.isEmpty) {
      if (uiUpdate) setState(() => status = 'Server already up to date.');
      syncing = false;
      return;
    }

    // Upload each required file
    int succ = 0;
    for (final f in needed) {
      final rel = f['rel'] as String;
      final lastModified = f['lastModified'] as int;
      final size = f['size'] as int;

      String? foundFull;

      // 1) try each watchDir + rel
      for (final d in watchDirs) {
        final candidate = p.join(d, rel);
        if (File(candidate).existsSync()) {
          foundFull = candidate;
          break;
        }
      }

      // 2) try storage root + rel
      if (foundFull == null) {
        final candidate = p.join('/storage/emulated/0', rel);
        if (File(candidate).existsSync()) foundFull = candidate;
      }

      // 3) fallback: try to find by filename in watchDirs
      if (foundFull == null) {
        final filename = p.basename(rel);
        bool stop = false;
        for (final d in watchDirs) {
          try {
            await for (final e in Directory(d).list(recursive: true, followLinks: false)) {
              if (e is File && p.basename(e.path) == filename) {
                foundFull = e.path;
                stop = true;
                break;
              }
            }
          } catch (_) {}
          if (stop) break;
        }
      }

      if (foundFull == null) {
        debugPrint('File not found locally for rel="$rel"');
        continue;
      }

      if (uiUpdate) setState(() => status = 'Uploading ${p.basename(foundFull!)}');
      final okUpload = await _uploadOne(foundFull, rel, lastModified, size);
      if (okUpload) succ++;
      await Future.delayed(const Duration(milliseconds: 200));
    }

    if (uiUpdate) setState(() => status = 'Sync done. Uploaded: $succ / ${needed.length}');
    syncing = false;
  }

  Future<void> _periodicSync() async {
    if (_ipCtrl.text.trim().isEmpty) return;
    await doSyncOnce(uiUpdate: false);
  }

  Future<void> _addDirectoryDialog() async {
    final ctrl = TextEditingController();
    await showDialog(context: context, builder: (ctx) {
      return AlertDialog(
        title: const Text('Add directory to watch'),
        content: TextField(controller: ctrl, decoration: const InputDecoration(hintText: '/storage/emulated/0/WhatsApp/Media')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          ElevatedButton(onPressed: () {
            final val = ctrl.text.trim();
            if (val.isNotEmpty) {
              setState(() => watchDirs.add(val));
              _saveConfig();
            }
            Navigator.pop(ctx);
          }, child: const Text('Add'))
        ],
      );
    });
  }

  Future<void> _removeDirectory(int idx) async {
    setState(() => watchDirs.removeAt(idx));
    await _saveConfig();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('AuroraSync XML Sync')),
      body: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(children: [
          Row(children: [
            Expanded(child: TextField(controller: _ipCtrl, decoration: const InputDecoration(labelText: 'Laptop IP'))),
            const SizedBox(width: 8),
            SizedBox(width: 90, child: TextField(controller: _portCtrl, decoration: const InputDecoration(labelText: 'Port'))),
            const SizedBox(width: 8),
            ElevatedButton(onPressed: _saveConfig, child: const Text('Save')),
          ]),
          const SizedBox(height: 12),
          Row(children: [
            ElevatedButton(onPressed: () => doSyncOnce(uiUpdate: true), child: const Text('Sync Now')),
            const SizedBox(width: 12),
            ElevatedButton(onPressed: _addDirectoryDialog, child: const Text('Add Dir')),
          ]),
          const SizedBox(height: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text('Watch directories:'),
                Expanded(
                  child: ListView.builder(
                    itemCount: watchDirs.length,
                    itemBuilder: (ctx, i) {
                      return ListTile(
                        title: Text(watchDirs[i]),
                        trailing: IconButton(icon: const Icon(Icons.delete), onPressed: () => _removeDirectory(i)),
                      );
                    },
                  ),
                )
              ],
            ),
          ),
          const SizedBox(height: 8),
          Text('Status: $status'),
        ]),
      ),
    );
  }
}
