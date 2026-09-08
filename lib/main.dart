import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
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
  final List<DownloadItem> queue = [];
  String output = 'Choose a folder in Settings';

  Future<void> addUrl() async {
    final url = controller.text.trim();
    if (url.isEmpty) return;
    setState(() {
      queue.insert(0, DownloadItem(url: url, status: 'Ready'));
      controller.clear();
    });
  }

  Future<void> chooseFolder() async {
    final path = await FilePicker.platform.getDirectoryPath();
    if (path == null) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('output_dir', path);
    setState(() => output = path);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Music Collecter'), actions: [
        IconButton(onPressed: chooseFolder, icon: const Icon(Icons.folder_open))
      ]),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 900),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              const Text('Authorized Media Downloader', style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              const Text('Use URLs and media you are authorized to download. The app does not bypass platform restrictions.'),
              const SizedBox(height: 24),
              Row(children: [
                Expanded(child: TextField(controller: controller, decoration: const InputDecoration(labelText: 'Paste a media or playlist URL', border: OutlineInputBorder()), onSubmitted: (_) => addUrl())),
                const SizedBox(width: 12),
                FilledButton.icon(onPressed: addUrl, icon: const Icon(Icons.add), label: const Text('Add')),
              ]),
              const SizedBox(height: 18),
              Text('Output: $output', maxLines: 1, overflow: TextOverflow.ellipsis),
              const SizedBox(height: 18),
              Expanded(child: queue.isEmpty ? const Center(child: Text('Your download queue is empty.')) : ListView.separated(
                itemCount: queue.length,
                separatorBuilder: (_, __) => const Divider(),
                itemBuilder: (_, i) => ListTile(leading: const Icon(Icons.music_note), title: Text(queue[i].url), subtitle: Text(queue[i].status), trailing: const Icon(Icons.more_horiz)),
              )),
            ]),
          ),
        ),
      ),
    );
  }
}

class DownloadItem {
  final String url;
  final String status;
  DownloadItem({required this.url, required this.status});
}
