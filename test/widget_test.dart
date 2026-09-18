import 'package:flutter_test/flutter_test.dart';

import 'package:music_collecter/main.dart';

void main() {
  testWidgets('Music Collecter starts with an empty queue', (tester) async {
    await tester.pumpWidget(const MusicCollecterApp());
    expect(find.text('Music Collecter'), findsWidgets);
    expect(find.text('Your queue is empty'), findsOneWidget);
    expect(find.text('Paste a direct audio link above.'), findsOneWidget);
  });
}
