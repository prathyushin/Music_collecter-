import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() => runApp(const MusicCollecterApp());

class MusicCollecterApp extends StatelessWidget {
  const MusicCollecterApp({super.key});

  @override
  Widget build(BuildContext context) {
    const ink = Color(0xFF151515);
    const paper = Color(0xFFF7F7F4);
    return MaterialApp(
      title: 'Music Collecter',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        scaffoldBackgroundColor: paper,
        colorScheme: ColorScheme.fromSeed(seedColor: ink, brightness: Brightness.light),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: Colors.white,
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide.none),
          enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: const BorderSide(color: Color(0xFFE6E6E2))),
          focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: const BorderSide(color: ink, width: 1.2)),
        ),
      ),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final controller = TextEditingController();
  final apiController = TextEditingController(text: 'http://127.0.0.1:8000');
  final List<DownloadItem> queue = [];
  final http.Client client = http.Client();

  String output = 'App storage';
  String message = '';
  bool busy = false;

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      output = prefs.getString('output_dir') ?? 'App storage';
      apiController.text = prefs.getString('api_url') ?? 'http://127.0.0.1:8000';
    });
  }

  Future<Directory> _outputDirectory() async {
    if (output != 'App storage') {
      final directory = Directory(output);
      if (await directory.exists()) return directory;
    }
    final directory = await getApplicationDocumentsDirectory();
    await directory.create(recursive: true);
    return directory;
  }

  Future<void> chooseFolder() async {
    final path = await FilePicker.platform.getDirectoryPath();
    if (path == null) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('output_dir', path);
    if (!mounted) return;
    setState(() => output = path);
  }

  Future<void> saveApi() async {
    final value = apiController.text.trim().replaceAll(RegExp(r'/$'), '');
    if (value.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('api_url', value);
    if (!mounted) return;
    setState(() => message = 'Server address saved.');
  }

  void addUrl() {
    final url = controller.text.trim();
    if (url.isEmpty) return;
    setState(() {
      queue.insert(0, DownloadItem(url: url));
      controller.clear();
      message = '';
    });
  }

  Future<void> analyzeAndDownload(int index) async {
    if (busy || index < 0 || index >= queue.length) return;
    final item = queue[index];
    final base = apiController.text.trim().replaceAll(RegExp(r'/$'), '');
    if (base.isEmpty) {
      _setStatus(item, 'Server address is empty');
      return;
    }
    setState(() {
      busy = true;
      item.status = 'Checking source';
      item.progress = 0;
    });
    try {
      final analyze = await client.post(Uri.parse('$base/analyze'), headers: {'Content-Type': 'application/json'}, body: jsonEncode({'url': item.url}));
      if (analyze.statusCode < 200 || analyze.statusCode >= 300) throw Exception(_error(analyze.body));
      final info = jsonDecode(analyze.body) as Map<String, dynamic>;
      if (info['supported'] != true) throw Exception(info['message'] ?? 'Unsupported source');

      setState(() => item.status = 'Downloading');
      final download = await client.post(Uri.parse('$base/download'), headers: {'Content-Type': 'application/json'}, body: jsonEncode({'url': item.url}));
      if (download.statusCode < 200 || download.statusCode >= 300) throw Exception(_error(download.body));
      final result = jsonDecode(download.body) as Map<String, dynamic>;
      final filename = (result['filename'] ?? 'track').toString();
      final remotePath = (result['download_url'] ?? '').toString();
      if (remotePath.isEmpty) throw Exception('Server returned no file.');

      setState(() {
        item.status = 'Saving';
        item.progress = 0;
      });
      await _saveRemoteFile(base, remotePath, filename, item);
      _setStatus(item, filename, completed: true);
    } catch (e) {
      _setStatus(item, _cleanException(e), failed: true);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _saveRemoteFile(String base, String remotePath, String filename, DownloadItem item) async {
    final directory = await _outputDirectory();
    final target = await _uniqueFile(directory, filename);
    final temporary = File('${target.path}.part');
    try {
      final uri = Uri.parse(remotePath.startsWith('http://') || remotePath.startsWith('https://') ? remotePath : '$base$remotePath');
      final response = await client.send(http.Request('GET', uri));
      if (response.statusCode < 200 || response.statusCode >= 300) throw Exception('File transfer failed (${response.statusCode}).');
      final total = response.contentLength;
      var received = 0;
      final sink = temporary.openWrite();
      try {
        await for (final chunk in response.stream) {
          sink.add(chunk);
          received += chunk.length;
          if (mounted && total != null && total > 0) setState(() => item.progress = received / total);
        }
      } finally {
        await sink.close();
      }
      await temporary.rename(target.path);
    } catch (_) {
      if (await temporary.exists()) await temporary.delete();
      rethrow;
    }
  }

  Future<File> _uniqueFile(Directory directory, String filename) async {
    final clean = filename.replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f]'), '_').trim();
    final safe = clean.isEmpty ? 'track' : clean;
    var target = File('${directory.path}/$safe');
    var counter = 1;
    final dot = safe.lastIndexOf('.');
    final stem = dot > 0 ? safe.substring(0, dot) : safe;
    final extension = dot > 0 ? safe.substring(dot) : '';
    while (await target.exists()) {
      target = File('${directory.path}/$stem ($counter)$extension');
      counter++;
    }
    return target;
  }

  Future<void> downloadAll() async {
    for (var i = 0; i < queue.length; i++) {
      if (!queue[i].completed) await analyzeAndDownload(i);
    }
  }

  Future<void> testConnection() async {
    final base = apiController.text.trim().replaceAll(RegExp(r'/$'), '');
    if (base.isEmpty) return;
    setState(() => message = 'Checking server…');
    try {
      final response = await client.get(Uri.parse('$base/health'));
      setState(() => message = response.statusCode == 200 ? 'Server connected.' : 'Server returned HTTP ${response.statusCode}.');
    } catch (e) {
      setState(() => message = 'Connection failed: ${_cleanException(e)}');
    }
  }

  void _setStatus(DownloadItem item, String value, {bool completed = false, bool failed = false}) {
    if (!mounted) return;
    setState(() {
      item.status = value;
      item.completed = completed;
      item.failed = failed;
      if (completed) item.progress = 1;
    });
  }

  String _error(String body) {
    try {
      final json = jsonDecode(body) as Map<String, dynamic>;
      return (json['detail'] ?? json['message'] ?? 'Request failed').toString();
    } catch (_) {
      return 'Request failed';
    }
  }

  String _cleanException(Object error) => error.toString().replaceFirst('Exception: ', '').trim();

  @override
  void dispose() {
    controller.dispose();
    apiController.dispose();
    client.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        titleSpacing: 20,
        title: const Text('Music Collecter', style: TextStyle(fontWeight: FontWeight.w700, letterSpacing: -0.5)),
        actions: [
          IconButton(onPressed: chooseFolder, tooltip: 'Storage', icon: const Icon(Icons.folder_outlined)),
          IconButton(onPressed: _showSettings, tooltip: 'Settings', icon: const Icon(Icons.tune_rounded)),
          const SizedBox(width: 8),
        ],
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 920),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Spacer(),
                  Text('Collect your music.', style: theme.textTheme.displaySmall?.copyWith(fontWeight: FontWeight.w700, letterSpacing: -1.6)),
                  const SizedBox(height: 8),
                  Text('Paste an authorized direct audio link. Keep the interface simple; let the queue do the work.', style: theme.textTheme.bodyLarge?.copyWith(color: Colors.black54, height: 1.45)),
                  const SizedBox(height: 28),
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(22), border: Border.all(color: const Color(0xFFE6E6E2))),
                    child: Row(children: [
                      Expanded(child: TextField(controller: controller, onSubmitted: (_) => addUrl(), decoration: const InputDecoration(hintText: 'Paste audio URL', prefixIcon: Icon(Icons.link_rounded), filled: false, border: InputBorder.none, enabledBorder: InputBorder.none, focusedBorder: InputBorder.none))),
                      const SizedBox(width: 4),
                      FilledButton(onPressed: busy ? null : addUrl, style: FilledButton.styleFrom(minimumSize: const Size(92, 52), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16))), child: const Text('Add')),
                    ]),
                  ),
                  const SizedBox(height: 14),
                  Row(children: [
                    const Icon(Icons.folder_copy_outlined, size: 17),
                    const SizedBox(width: 7),
                    Expanded(child: Text(output, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodySmall?.copyWith(color: Colors.black54))),
                    TextButton.icon(onPressed: queue.isEmpty || busy ? null : downloadAll, icon: const Icon(Icons.download_rounded, size: 18), label: const Text('Download all')),
                  ]),
                  if (message.isNotEmpty) ...[const SizedBox(height: 8), Text(message, style: theme.textTheme.bodySmall?.copyWith(color: Colors.black54))],
                  const SizedBox(height: 22),
                  if (queue.isEmpty)
                    Container(
                      padding: const EdgeInsets.symmetric(vertical: 38),
                      decoration: BoxDecoration(border: Border.all(color: const Color(0xFFE2E2DE)), borderRadius: BorderRadius.circular(20)),
                      child: const Column(children: [Icon(Icons.queue_music_rounded, size: 30), SizedBox(height: 10), Text('Nothing in the queue yet.'), SizedBox(height: 4), Text('Add a track to get started.', style: TextStyle(color: Colors.black45))]),
                    )
                  else
                    Expanded(child: ListView.separated(itemCount: queue.length, separatorBuilder: (_, __) => const SizedBox(height: 8), itemBuilder: (_, i) => _queueTile(queue[i], i))),
                  if (queue.isEmpty) const Spacer(),
                  const SizedBox(height: 18),
                  const Text('For media you own or are explicitly authorized to download.', textAlign: TextAlign.center, style: TextStyle(fontSize: 11, color: Colors.black38)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _queueTile(DownloadItem item, int index) {
    final statusIcon = item.completed ? Icons.check_circle_rounded : item.failed ? Icons.error_outline_rounded : Icons.music_note_rounded;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(18), border: Border.all(color: const Color(0xFFE6E6E2))),
      child: Row(children: [
        Container(width: 42, height: 42, decoration: BoxDecoration(color: const Color(0xFFF0F0ED), borderRadius: BorderRadius.circular(13)), child: Icon(statusIcon, size: 20)),
        const SizedBox(width: 12),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(item.url, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600)), const SizedBox(height: 3), Text(item.status, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12, color: Colors.black54)), if (item.progress > 0 && item.progress < 1) ...[const SizedBox(height: 7), LinearProgressIndicator(value: item.progress, minHeight: 3)]])),
        const SizedBox(width: 8),
        IconButton(onPressed: busy || item.completed ? null : () => analyzeAndDownload(index), icon: const Icon(Icons.arrow_downward_rounded)),
      ]),
    );
  }

  Future<void> _showSettings() async {
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Connection'),
        content: TextField(controller: apiController, keyboardType: TextInputType.url, decoration: const InputDecoration(labelText: 'FastAPI server', hintText: 'http://192.168.x.x:8000')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('Cancel')),
          TextButton(onPressed: () { Navigator.pop(dialogContext); saveApi(); }, child: const Text('Save')),
          FilledButton(onPressed: () { Navigator.pop(dialogContext); saveApi().then((_) => testConnection()); }, child: const Text('Save & test')),
        ],
      ),
    );
  }
}

class DownloadItem {
  final String url;
  String status = 'Ready';
  double progress = 0;
  bool completed = false;
  bool failed = false;

  DownloadItem({required this.url});
}
