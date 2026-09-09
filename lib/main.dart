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
    return MaterialApp(
      title: 'Music Collecter',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.indigo),
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
  bool busy = false;
  String message = '';

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    final storedOutput = prefs.getString('output_dir');
    final storedApi = prefs.getString('api_url');
    if (!mounted) return;
    setState(() {
      output = storedOutput ?? 'App storage';
      apiController.text = storedApi ?? 'http://127.0.0.1:8000';
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
    setState(() => message = 'API address saved.');
  }

  void addUrl() {
    final url = controller.text.trim();
    if (url.isEmpty) return;
    setState(() {
      queue.insert(0, DownloadItem(url: url, status: 'Ready'));
      controller.clear();
      message = '';
    });
  }

  Future<void> analyzeAndDownload(int index) async {
    if (busy || index < 0 || index >= queue.length) return;

    final item = queue[index];
    final base = apiController.text.trim().replaceAll(RegExp(r'/$'), '');
    if (base.isEmpty) {
      _setItemStatus(item, 'Failed: API address is empty');
      return;
    }

    setState(() {
      busy = true;
      item.status = 'Analyzing';
      item.progress = 0;
      message = '';
    });

    try {
      final analyze = await client.post(
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
      final download = await client.post(
        Uri.parse('$base/download'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'url': item.url}),
      );
      if (download.statusCode < 200 || download.statusCode >= 300) {
        throw Exception(_error(download.body));
      }

      final result = jsonDecode(download.body) as Map<String, dynamic>;
      final filename = (result['filename'] ?? 'track').toString();
      final remotePath = (result['download_url'] ?? '').toString();
      if (remotePath.isEmpty) throw Exception('Server did not return a file URL.');

      setState(() {
        item.status = 'Saving to device';
        item.progress = 0;
      });
      await _saveRemoteFile(base, remotePath, filename, item);
      _setItemStatus(item, 'Completed: $filename');
    } catch (e) {
      _setItemStatus(item, 'Failed: ${_cleanException(e)}');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _saveRemoteFile(
    String base,
    String remotePath,
    String filename,
    DownloadItem item,
  ) async {
    final directory = await _outputDirectory();
    final target = await _uniqueFile(directory, filename);
    final temporary = File('${target.path}.part');

    try {
      final request = http.Request('GET', Uri.parse('$base$remotePath'));
      final response = await client.send(request);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw Exception('Could not retrieve downloaded file (${response.statusCode}).');
      }

      final total = response.contentLength;
      var received = 0;
      final sink = temporary.openWrite();
      try {
        await for (final chunk in response.stream) {
          sink.add(chunk);
          received += chunk.length;
          if (mounted && total != null && total > 0) {
            setState(() => item.progress = received / total);
          }
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
    final safeName = clean.isEmpty ? 'track' : clean;
    var target = File('${directory.path}/$safeName');
    var counter = 1;
    final dot = safeName.lastIndexOf('.');
    final stem = dot > 0 ? safeName.substring(0, dot) : safeName;
    final extension = dot > 0 ? safeName.substring(dot) : '';

    while (await target.exists()) {
      target = File('${directory.path}/$stem ($counter)$extension');
      counter++;
    }
    return target;
  }

  Future<void> downloadAll() async {
    for (var i = 0; i < queue.length; i++) {
      if (queue[i].status.startsWith('Completed')) continue;
      await analyzeAndDownload(i);
    }
  }

  Future<void> testConnection() async {
    final base = apiController.text.trim().replaceAll(RegExp(r'/$'), '');
    if (base.isEmpty) return;
    setState(() => message = 'Checking API…');
    try {
      final response = await client.get(Uri.parse('$base/health'));
      if (response.statusCode == 200) {
        setState(() => message = 'API is connected.');
      } else {
        setState(() => message = 'API returned HTTP ${response.statusCode}.');
      }
    } catch (e) {
      setState(() => message = 'Connection failed: ${_cleanException(e)}');
    }
  }

  void _setItemStatus(DownloadItem item, String status) {
    if (!mounted) return;
    setState(() => item.status = status);
  }

  String _error(String body) {
    try {
      final json = jsonDecode(body) as Map<String, dynamic>;
      return (json['detail'] ?? json['message'] ?? 'Request failed').toString();
    } catch (_) {
      return 'Request failed';
    }
  }

  String _cleanException(Object error) {
    return error.toString().replaceFirst('Exception: ', '').trim();
  }

  @override
  void dispose() {
    controller.dispose();
    apiController.dispose();
    client.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Music Collecter'),
        actions: [
          IconButton(
            onPressed: chooseFolder,
            tooltip: 'Output folder',
            icon: const Icon(Icons.folder_open),
          ),
          IconButton(
            onPressed: _showSettings,
            tooltip: 'Settings',
            icon: const Icon(Icons.settings_outlined),
          ),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1000),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Music Collecter',
                  style: Theme.of(context).textTheme.headlineLarge?.copyWith(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 6),
                Text(
                  'Collect media you own or are explicitly authorized to download.',
                  style: Theme.of(context).textTheme.bodyLarge,
                ),
                const SizedBox(height: 24),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: controller,
                        decoration: const InputDecoration(
                          hintText: 'Paste an authorized direct audio URL',
                          prefixIcon: Icon(Icons.link),
                          border: OutlineInputBorder(),
                        ),
                        onSubmitted: (_) => addUrl(),
                      ),
                    ),
                    const SizedBox(width: 12),
                    FilledButton.icon(
                      onPressed: busy ? null : addUrl,
                      icon: const Icon(Icons.add),
                      label: const Text('Add'),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Output: $output',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 12),
                    FilledButton.icon(
                      onPressed: queue.isEmpty || busy ? null : downloadAll,
                      icon: const Icon(Icons.download),
                      label: const Text('Download all'),
                    ),
                  ],
                ),
                if (message.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: Text(message),
                  ),
                const SizedBox(height: 18),
                Expanded(
                  child: queue.isEmpty
                      ? const Center(child: Text('Your download queue is empty.'))
                      : ListView.separated(
                          itemCount: queue.length,
                          separatorBuilder: (_, __) => const SizedBox(height: 8),
                          itemBuilder: (_, i) {
                            final item = queue[i];
                            return Card(
                              child: ListTile(
                                leading: CircleAvatar(child: Text('${i + 1}')),
                                title: Text(item.url, maxLines: 1, overflow: TextOverflow.ellipsis),
                                subtitle: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    const SizedBox(height: 4),
                                    Text(item.status),
                                    if (item.progress > 0 && item.progress < 1)
                                      Padding(
                                        padding: const EdgeInsets.only(top: 6),
                                        child: LinearProgressIndicator(value: item.progress),
                                      ),
                                  ],
                                ),
                                trailing: IconButton(
                                  icon: const Icon(Icons.download_outlined),
                                  onPressed: busy ? null : () => analyzeAndDownload(i),
                                ),
                              ),
                            );
                          },
                        ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _showSettings() async {
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Settings'),
        content: TextField(
          controller: apiController,
          decoration: const InputDecoration(
            labelText: 'FastAPI server URL',
            hintText: 'http://192.168.x.x:8000',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('Cancel')),
          TextButton(
            onPressed: () {
              Navigator.pop(dialogContext);
              saveApi();
            },
            child: const Text('Save'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(dialogContext);
              saveApi().then((_) => testConnection());
            },
            child: const Text('Save & test'),
          ),
        ],
      ),
    );
  }
}

class DownloadItem {
  final String url;
  String status;
  double progress;

  DownloadItem({required this.url, required this.status, this.progress = 0});
}
