import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ohgithublost/surface/widgets/ai_message_body.dart';

void main() {
  testWidgets('fenced code exposes independent copy action while preserving prose', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: SingleChildScrollView(
      child: AiMessageBody(text: 'Intro\n\n```dart\nprint("hello");\n```\n\nConclusion')))));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.copy), findsOneWidget);
    expect(find.text('dart'), findsOneWidget);
    expect(find.text('print("hello");\n'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
