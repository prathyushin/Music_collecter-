import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

const kApiBaseUrl = String.fromEnvironment(
  'MUSIC_COLLECTER_API_URL',
  defaultValue: 'https://music-collecter-api.onrender.com',
);

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
  final List<DownloadItem> queue = [];
  final http.Client client = http.Client();

  String output = 'App storage';
  String message = 'Connecting to Music Collecter…';
  bool serverOnline = false;
  bool busy = false;

  @override
  void initState() {
    super.initState();
    _loadSettings();
    _checkServer();
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() => output = prefs.getString('output_dir') ?? 'App storage');
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

  String get _baseUrl => kApiBaseUrl.replaceAll(RegExp(r'/$'), '');

  Future<void> _checkServer() async {
    try {
      final response = await client.get(Uri.parse('$_baseUrl/health')).timeout(const Duration(seconds: 12));
      if (!mounted) return;
      setState(() {
        serverOnline = response.statusCode == 200;
        message = serverOnline ? 'Ready.' : 'Service is temporarily unavailable.';
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        serverOnline = false;
        message = 'Can’t reach Music Collecter right now. Try again in a moment.';
      });
    }
  }

  void addUrl() {
    final url = controller.text.trim();
    if (url.isEmpty) return;
    setState(() {
      queue.insert(0, DownloadItem(url: url));
      controller.clear();
      message = serverOnline ? 'Ready.' : 'Checking the service…';
    });
    if (!serverOnline) _checkServer();
  }

  Future<void> analyzeAndDownload(int index) async {
    if (busy || index < 0 || index >= queue.length) return;
    final item = queue[index];
    setState(() {
      busy = true;
      item.status = 'Checking source';
      item.progress = 0;
      message = '';
    });

    try {
      final analyze = await client
          .post(Uri.parse('$_baseUrl/analyze'), headers: {'Content-Type': 'application/json'}, body: jsonEncode({'url': item.url}))
          .timeout(const Duration(seconds: 30));
      if (analyze.statusCode < 200 || analyze.statusCode >= 300) throw Exception(_error(analyze.body));
      final info = jsonDecode(analyze.body) as Map<String, dynamic>;
      if (info['supported'] != true) throw Exception(info['message'] ?? 'This source is not supported.');

      setState(() => item.status = 'Downloading');
      final request = http.Request('POST', Uri.parse('$_baseUrl/download'))
        ..headers['Content-Type'] = 'application/json'
        ..body = jsonEncode({'url': item.url});
      final response = await client.send(request);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        final body = await response.stream.bytesToString();
        throw Exception(_error(body));
      }

      final filename = response.headers['x-music-collecter-filename'] ?? _filenameFromContentDisposition(response.headers['content-disposition']) ?? 'track${_extensionForContentType(response.headers['content-type'])}';
      await _saveStream(response, filename, item);
      _setStatus(item, filename, completed: true);
    } catch (e) {
      _setStatus(item, _cleanException(e), failed: true);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _saveStream(http.StreamedResponse response, String filename, DownloadItem item) async {
    final directory = await _outputDirectory();
    final target = await _uniqueFile(directory, filename);
    final temporary = File('${target.path}.part');
    final total = response.contentLength;
    var received = 0;
    try {
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

  String? _filenameFromContentDisposition(String? value) {
    if (value == null) return null;
    final match = RegExp(r'filename="?([^";]+)').firstMatch(value);
    return match?.group(1);
  }

  String _extensionForContentType(String? value) {
    final type = (value ?? '').split(';').first.toLowerCase();
    const types = {
      'audio/mpeg': '.mp3',
      'audio/mp4': '.m4a',
      'audio/x-m4a': '.m4a',
      'audio/aac': '.aac',
      'audio/ogg': '.ogg',
      'audio/flac': '.flac',
      'audio/wav': '.wav',
      'audio/x-wav': '.wav',
      'audio/webm': '.webm',
    };
    return types[type] ?? '.audio';
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
      return 'The service could not complete that request.';
    }
  }

  String _cleanException(Object error) {
    final text = error.toString().replaceFirst('Exception: ', '').trim();
    if (text.contains('SocketException') || text.contains('ClientException')) return 'Network connection failed. Please try again.';
    if (text.contains('TimeoutException')) return 'The request timed out. Please try again.';
    return text;
  }

  @override
  void dispose() {
    controller.dispose();
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
                  Row(children: [
                    Container(width: 8, height: 8, decoration: BoxDecoration(shape: BoxShape.circle, color: serverOnline ? Colors.green : Colors.black26)),
                    const SizedBox(width: 8),
                    Text(serverOnline ? 'Online' : 'Connecting', style: theme.textTheme.labelLarge?.copyWith(color: Colors.black54)),
                  ]),
                  const SizedBox(height: 12),
                  Text('Collect your music.', style: theme.textTheme.displaySmall?.copyWith(fontWeight: FontWeight.w700, letterSpacing: -1.6)),
                  const SizedBox(height: 8),
                  Text('Paste an authorized direct audio link. No server setup required.', style: theme.textTheme.bodyLarge?.copyWith(color: Colors.black54, height: 1.45)),
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
}

class DownloadItem {
  final String url;
  String status = 'Ready';
  double progress = 0;
  bool completed = false;
  bool failed = false;

  DownloadItem({required this.url});
}
