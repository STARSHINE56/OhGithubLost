import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ohgithublost/surface/pages/ai_chat_page.dart';
import 'package:ohgithublost/surface/types.dart';

import 'ai_lifecycle_test.dart' as fixture;
import 'ai_live_send_test.dart' as live;

void main() {
  testWidgets('blank send is disabled and draft remains editable while waiting', (tester) async {
    final ai = live.LiveAi();
    final surface = await fixture.bridge(ai);
    await surface.domain.auth.saveAccount(const GhAccount(id: 'alice', login: 'alice'), const GhToken('ghp_test'));
    await surface.domain.auth.switchTo('alice');
    await tester.pumpWidget(MaterialApp(home: AiChatPage(surface: surface)));
    await tester.pumpAndSettle();
    final send = find.widgetWithIcon(IconButton, Icons.arrow_upward);
    expect(tester.widget<IconButton>(send).onPressed, isNull);
    await tester.enterText(find.byType(TextField), 'First message');
    await tester.pump();
    await tester.tap(send);
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'Next draft');
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, 'Next draft');
    expect(tester.widget<IconButton>(send).onPressed, isNull);
    ai.release.complete();
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, 'Next draft');
    expect(find.byIcon(Icons.copy_outlined), findsNWidgets(2));
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
