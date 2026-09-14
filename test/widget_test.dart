import 'package:flutter_test/flutter_test.dart';

import 'package:music_collecter/main.dart';

void main() {
  testWidgets('Music Collecter starts with an empty queue', (tester) async {
    await tester.pumpWidget(const MusicCollecterApp());
    expect(find.text('Music Collecter'), findsWidgets);
    expect(find.text('Nothing in the queue yet.'), findsOneWidget);
    expect(find.text('Add a track to get started.'), findsOneWidget);
  });
}
