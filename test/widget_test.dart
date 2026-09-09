import 'package:flutter_test/flutter_test.dart';

import 'package:music_collecter/main.dart';

void main() {
  testWidgets('Music Collecter starts', (tester) async {
    await tester.pumpWidget(const MusicCollecterApp());
    expect(find.text('Music Collecter'), findsWidgets);
    expect(find.text('Your download queue is empty.'), findsOneWidget);
  });
}
