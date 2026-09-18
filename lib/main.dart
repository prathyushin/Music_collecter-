import 'dart:convert';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

const kApiBaseUrl = String.fromEnvironment('MUSIC_COLLECTER_API_URL', defaultValue: 'https://music-collecter-api.onrender.com');

void main() => runApp(const MusicCollecterApp());

class MusicCollecterApp extends StatelessWidget {
  const MusicCollecterApp({super.key});
  @override
  Widget build(BuildContext context) {
    const ink = Color(0xFF171717);
    const paper = Color(0xFFF7F7F4);
    return MaterialApp(
      title: 'Music Collecter',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        scaffoldBackgroundColor: paper,
        colorScheme: ColorScheme.fromSeed(seedColor: ink, brightness: Brightness.light),
        appBarTheme: const AppBarTheme(backgroundColor: Colors.transparent, surfaceTintColor: Colors.transparent, elevation: 0),
        inputDecorationTheme: const InputDecorationTheme(
          filled: true, fillColor: Colors.white,
          border: OutlineInputBorder(borderRadius: BorderRadius.all(Radius.circular(18)), borderSide: BorderSide(color: Color(0xFFE6E6E1))),
          enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.all(Radius.circular(18)), borderSide: BorderSide(color: Color(0xFFE6E6E1))),
          focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.all(Radius.circular(18)), borderSide: BorderSide(color: ink, width: 1.2)),
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
  final client = http.Client();
  final queue = <DownloadItem>[];
  String output = 'App storage';
  String serviceText = 'Connecting…';
  bool serviceOnline = false;
  bool busy = false;

  String get baseUrl => kApiBaseUrl.replaceAll(RegExp(r'/$'), '');

  @override
  void initState() {
    super.initState();
    _loadSettings();
    _checkService();
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() => output = prefs.getString('output_dir') ?? 'App storage');
  }

  Future<Directory> _outputDirectory() async {
    if (output != 'App storage') {
      final chosen = Directory(output);
      if (await chosen.exists()) return chosen;
    }
    final dir = await getApplicationDocumentsDirectory();
    await dir.create(recursive: true);
    return dir;
  }

  Future<void> chooseFolder() async {
    final path = await FilePicker.platform.getDirectoryPath();
    if (path == null) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('output_dir', path);
    if (!mounted) return;
    setState(() => output = path);
  }

  Future<void> _checkService() async {
    if (mounted) setState(() => serviceText = 'Connecting…');
    try {
      final response = await client.get(Uri.parse('$baseUrl/health')).timeout(const Duration(seconds: 25));
      if (!mounted) return;
      setState(() {
        serviceOnline = response.statusCode == 200;
        serviceText = serviceOnline ? 'Ready' : 'Service unavailable';
      });
    } catch (_) {
      if (!mounted) return;
      setState(() { serviceOnline = false; serviceText = 'Tap to retry'; });
    }
  }

  void addUrl() {
    final url = controller.text.trim();
    final uri = Uri.tryParse(url);
    if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https') || uri.host.isEmpty) {
      _show('Enter a valid http or https media link.');
      return;
    }
    if (queue.any((item) => item.url == url && !item.failed)) {
      _show('That link is already in the queue.');
      return;
    }
    setState(() {
      queue.insert(0, DownloadItem(url: url));
      controller.clear();
    });
  }

  Future<void> downloadItem(int index) async {
    if (busy || index < 0 || index >= queue.length) return;
    final item = queue[index];
    setState(() {
      busy = true; item.status = 'Checking source…'; item.failed = false; item.progress = 0;
    });

    try {
      final analyze = await client.post(
        Uri.parse('$baseUrl/analyze'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'url': item.url}),
      ).timeout(const Duration(seconds: 60));

      if (analyze.statusCode < 200 || analyze.statusCode >= 300) throw Exception(_error(analyze.body));
      final info = jsonDecode(analyze.body) as Map<String, dynamic>;
      if (info['supported'] != true) throw Exception((info['message'] ?? 'This source is not supported.').toString());
      if (mounted) setState(() => item.status = 'Downloading…');

      final request = http.Request('POST', Uri.parse('$baseUrl/download'))
        ..headers['Content-Type'] = 'application/json'
        ..body = jsonEncode({'url': item.url});
      final response = await client.send(request);

      if (response.statusCode < 200 || response.statusCode >= 300) {
        final body = await response.stream.bytesToString();
        throw Exception(_error(body));
      }

      final filename = response.headers['x-music-collecter-filename'] ??
          _filenameFromDisposition(response.headers['content-disposition']) ??
          'track\${_extension(response.headers['content-type'])}';

      await _saveStream(response, filename, item);
      if (!mounted) return;
      setState(() {
        item.status = filename; item.completed = true; item.progress = 1;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        item.status = _cleanException(e); item.failed = true; item.completed = false;
      });
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _saveStream(http.StreamedResponse response, String filename, DownloadItem item) async {
    final dir = await _outputDirectory();
    final target = await _uniqueFile(dir, filename);
    final temporary = File('\${target.path}.part');
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

  Future<File> _uniqueFile(Directory dir, String filename) async {
    final clean = filename.replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f]'), '_').trim();
    final safe = clean.isEmpty ? 'track.audio' : clean;
    var file = File('\${dir.path}/\$safe');
    var n = 1;
    final dot = safe.lastIndexOf('.');
    final stem = dot > 0 ? safe.substring(0, dot) : safe;
    final ext = dot > 0 ? safe.substring(dot) : '';
    while (await file.exists()) {
      file = File('\${dir.path}/\$stem (\$n)\$ext');
      n++;
    }
    return file;
  }

  Future<void> downloadAll() async {
    for (var i = 0; i < queue.length; i++) {
      if (!queue[i].completed) await downloadItem(i);
    }
  }

  void removeItem(int index) {
    if (busy) return;
    setState(() => queue.removeAt(index));
  }

  String? _filenameFromDisposition(String? value) {
    if (value == null) return null;
    return RegExp(r'filename="?([^";]+)').firstMatch(value)?.group(1);
  }

  String _extension(String? value) {
    switch ((value ?? '').split(';').first.toLowerCase()) {
      case 'audio/mpeg': return '.mp3';
      case 'audio/mp4':
      case 'audio/x-m4a': return '.m4a';
      case 'audio/aac': return '.aac';
      case 'audio/ogg': return '.ogg';
      case 'audio/flac': return '.flac';
      case 'audio/wav':
      case 'audio/x-wav': return '.wav';
      case 'audio/webm': return '.webm';
      default: return '.audio';
    }
  }

  String _error(String body) {
    try {
      final data = jsonDecode(body) as Map<String, dynamic>;
      return (data['detail'] ?? data['message'] ?? 'Request failed').toString();
    } catch (_) {
      return 'The service could not complete that request.';
    }
  }

  String _cleanException(Object error) {
    final value = error.toString().replaceFirst('Exception: ', '').trim();
    if (value.contains('SocketException') || value.contains('ClientException')) return 'Network connection failed. Try again.';
    if (value.contains('TimeoutException')) return 'The request took too long. Try again.';
    return value;
  }

  void _show(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)..hideCurrentSnackBar()..showSnackBar(SnackBar(content: Text(text)));
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
        titleSpacing: 20,
        title: const Text('Music Collecter', style: TextStyle(fontWeight: FontWeight.w700, letterSpacing: -0.6)),
        actions: [
          IconButton(tooltip: 'Storage', onPressed: chooseFolder, icon: const Icon(Icons.folder_outlined)),
          const SizedBox(width: 8),
        ],
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 10, 20, 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _ServicePill(online: serviceOnline, text: serviceText, onTap: serviceOnline ? null : _checkService),
                  const SizedBox(height: 22),
                  Text('Collect your music.', style: theme.textTheme.displaySmall?.copyWith(fontWeight: FontWeight.w700, letterSpacing: -1.8)),
                  const SizedBox(height: 7),
                  Text('One link. One tap. Saved on your device.', style: theme.textTheme.bodyLarge?.copyWith(color: Colors.black54, height: 1.4)),
                  const SizedBox(height: 24),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: TextField(
                          controller: controller,
                          keyboardType: TextInputType.url,
                          textInputAction: TextInputAction.done,
                          onSubmitted: (_) => addUrl(),
                          autocorrect: false,
                          enableSuggestions: false,
                          decoration: const InputDecoration(
                            hintText: 'Paste an audio link',
                            prefixIcon: Icon(Icons.link_rounded),
                            contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 17),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      FilledButton(
                        onPressed: busy ? null : addUrl,
                        style: FilledButton.styleFrom(minimumSize: const Size(72, 56), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18))),
                        child: const Icon(Icons.arrow_forward_rounded),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      const Icon(Icons.folder_outlined, size: 16),
                      const SizedBox(width: 6),
                      Expanded(child: Text(output, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodySmall?.copyWith(color: Colors.black45))),
                      if (queue.isNotEmpty) TextButton(onPressed: busy ? null : downloadAll, child: const Text('Download all')),
                    ],
                  ),
                  const SizedBox(height: 18),
                  Expanded(
                    child: queue.isEmpty
                        ? const _EmptyState()
                        : ListView.separated(
                            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
                            itemCount: queue.length,
                            separatorBuilder: (_, __) => const SizedBox(height: 8),
                            itemBuilder: (_, index) => _QueueCard(
                              item: queue[index],
                              onDownload: busy ? null : () => downloadItem(index),
                              onRemove: busy ? null : () => removeItem(index),
                            ),
                          ),
                  ),
                  const SizedBox(height: 14),
                  const Text('For media you own or are explicitly authorized to download.', textAlign: TextAlign.center, style: TextStyle(fontSize: 11, color: Colors.black38)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ServicePill extends StatelessWidget {
  const _ServicePill({required this.online, required this.text, required this.onTap});
  final bool online;
  final String text;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(30),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
          decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(30), border: Border.all(color: const Color(0xFFE6E6E1))),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(width: 7, height: 7, decoration: BoxDecoration(shape: BoxShape.circle, color: online ? Colors.green : Colors.black26)),
              const SizedBox(width: 7),
              Text(text, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Colors.black54)),
            ],
          ),
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();
  @override
  Widget build(BuildContext context) {
    return Center(
      child: SingleChildScrollView(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: const [
            Icon(Icons.queue_music_rounded, size: 32),
            SizedBox(height: 12),
            Text('Your queue is empty', style: TextStyle(fontWeight: FontWeight.w600)),
            SizedBox(height: 5),
            Text('Paste a direct audio link above.', style: TextStyle(color: Colors.black45)),
          ],
        ),
      ),
    );
  }
}

class _QueueCard extends StatelessWidget {
  const _QueueCard({required this.item, required this.onDownload, required this.onRemove});
  final DownloadItem item;
  final VoidCallback? onDownload;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final icon = item.completed ? Icons.check_rounded : item.failed ? Icons.refresh_rounded : Icons.music_note_rounded;
    return Container(
      padding: const EdgeInsets.fromLTRB(13, 12, 8, 12),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(18), border: Border.all(color: const Color(0xFFE6E6E1))),
      child: Column(
        children: [
          Row(
            children: [
              Container(width: 42, height: 42, decoration: BoxDecoration(color: const Color(0xFFF0F0EC), borderRadius: BorderRadius.circular(13)), child: Icon(icon, size: 20)),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(item.completed ? item.status : item.url, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600)),
                    const SizedBox(height: 3),
                    Text(item.completed ? 'Saved' : item.status, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12, color: Colors.black54)),
                  ],
                ),
              ),
              IconButton(tooltip: item.completed ? 'Saved' : 'Download', onPressed: item.completed ? null : onDownload, icon: Icon(item.completed ? Icons.check_circle_rounded : item.failed ? Icons.refresh_rounded : Icons.download_rounded)),
              IconButton(tooltip: 'Remove', onPressed: onRemove, icon: const Icon(Icons.close_rounded, size: 20)),
            ],
          ),
          if (item.progress > 0 && item.progress < 1) ...[
            const SizedBox(height: 9),
            LinearProgressIndicator(value: item.progress, minHeight: 3, borderRadius: BorderRadius.circular(3)),
          ],
        ],
      ),
    );
  }
}

class DownloadItem {
  DownloadItem({required this.url});
  final String url;
  String status = 'Ready to download';
  double progress = 0;
  bool completed = false;
  bool failed = false;
}
