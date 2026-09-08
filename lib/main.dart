import 'dart:convert';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

void main() => runApp(const MusicCollecterApp());

class MusicCollecterApp extends StatelessWidget {
  const MusicCollecterApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Music Collecter',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.indigo),
        home: const HomePage(),
      );
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
  String output = 'Choose a folder';
  bool busy = false;
  String message = '';

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      output = prefs.getString('output_dir') ?? 'Choose a folder';
      apiController.text = prefs.getString('api_url') ?? 'http://127.0.0.1:8000';
    });
  }

  Future<void> chooseFolder() async {
    final path = await FilePicker.platform.getDirectoryPath();
    if (path == null) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('output_dir', path);
    setState(() => output = path);
  }

  Future<void> saveApi() async {
    final value = apiController.text.trim().replaceAll(RegExp(r'/$'), '');
    if (value.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('api_url', value);
    setState(() => message = 'API address saved.');
  }

  Future<void> addUrl() async {
    final url = controller.text.trim();
    if (url.isEmpty) return;
    setState(() {
      queue.insert(0, DownloadItem(url: url, status: 'Ready'));
      controller.clear();
      message = '';
    });
  }

  Future<void> analyzeAndDownload(int index) async {
    if (busy) return;
    final item = queue[index];
    final base = apiController.text.trim().replaceAll(RegExp(r'/$'), '');
    setState(() {
      busy = true;
      item.status = 'Analyzing';
      message = '';
    });
    try {
      final analyze = await http.post(
        Uri.parse('$base/analyze'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'url': item.url}),
      );
      if (analyze.statusCode < 200 || analyze.statusCode >= 300) {
        throw Exception(_error(analyze.body));
      }
      final info = jsonDecode(analyze.body) as Map<String, dynamic>;
      if (info['supported'] != true) {
        throw Exception(info['message'] ?? 'Unsupported media URL');
      }

      setState(() => item.status = 'Downloading');
      final download = await http.post(
        Uri.parse('$base/download'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'url': item.url}),
      );
      if (download.statusCode < 200 || download.statusCode >= 300) {
        throw Exception(_error(download.body));
      }
      final result = jsonDecode(download.body) as Map<String, dynamic>;
      setState(() => item.status = 'Completed: ${result['filename']}');
    } catch (e) {
      setState(() => item.status = 'Failed: $e');
    } finally {
      setState(() => busy = false);
    }
  }

  String _error(String body) {
    try {
      final json = jsonDecode(body) as Map<String, dynamic>;
      return (json['detail'] ?? json['message'] ?? 'Request failed').toString();
    } catch (_) {
      return 'Request failed (${body.trim()})';
    }
  }

  Future<void> downloadAll() async {
    for (var i = 0; i < queue.length; i++) {
      if (queue[i].status.startsWith('Completed')) continue;
      await analyzeAndDownload(i);
    }
  }

  @override
  void dispose() {
    controller.dispose();
    apiController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          title: const Text('Music Collecter'),
          actions: [
            IconButton(onPressed: chooseFolder, tooltip: 'Output folder', icon: const Icon(Icons.folder_open)),
            IconButton(onPressed: _showSettings, tooltip: 'Settings', icon: const Icon(Icons.settings_outlined)),
          ],
        ),
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1000),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Text('Music Collecter', style: Theme.of(context).textTheme.headlineLarge?.copyWith(fontWeight: FontWeight.bold)),
                const SizedBox(height: 6),
                Text('Download media you own or are explicitly authorized to download.', style: Theme.of(context).textTheme.bodyLarge),
                const SizedBox(height: 24),
                Row(children: [
                  Expanded(child: TextField(controller: controller, decoration: const InputDecoration(hintText: 'Paste an authorized direct audio URL', prefixIcon: Icon(Icons.link), border: OutlineInputBorder()), onSubmitted: (_) => addUrl())),
                  const SizedBox(width: 12),
                  FilledButton.icon(onPressed: addUrl, icon: const Icon(Icons.add), label: const Text('Add')),
                ]),
                const SizedBox(height: 12),
                Row(children: [
                  Expanded(child: Text('Output: $output', maxLines: 1, overflow: TextOverflow.ellipsis)),
                  const SizedBox(width: 12),
                  FilledButton.icon(onPressed: queue.isEmpty || busy ? null : downloadAll, icon: const Icon(Icons.download), label: const Text('Download all')),
                ]),
                if (message.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 10), child: Text(message)),
                const SizedBox(height: 18),
                Expanded(
                  child: queue.isEmpty
                      ? const Center(child: Text('Your download queue is empty.'))
                      : ListView.separated(
                          itemCount: queue.length,
                          separatorBuilder: (_, __) => const SizedBox(height: 8),
                          itemBuilder: (_, i) => Card(
                            child: ListTile(
                              leading: CircleAvatar(child: Text('${i + 1}')),
                              title: Text(queue[i].url, maxLines: 1, overflow: TextOverflow.ellipsis),
                              subtitle: Text(queue[i].status),
                              trailing: IconButton(icon: const Icon(Icons.download_outlined), onPressed: busy ? null : () => analyzeAndDownload(i)),
                            ),
                          ),
                        ),
                ),
              ]),
            ),
          ),
        ),
      );

  Future<void> _showSettings() async {
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Settings'),
        content: TextField(controller: apiController, decoration: const InputDecoration(labelText: 'FastAPI server URL', border: OutlineInputBorder())),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')), FilledButton(onPressed: () { saveApi(); Navigator.pop(context); }, child: const Text('Save'))],
      ),
    );
  }
}

class DownloadItem {
  final String url;
  String status;
  DownloadItem({required this.url, required this.status});
}
