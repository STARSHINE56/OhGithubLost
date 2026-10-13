import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ohgithublost/surface/pages/ai_chat_page.dart';
import 'package:ohgithublost/surface/types.dart';

import 'ai_lifecycle_test.dart' as fixture;

class StreamingUiAi extends fixture.DelayedAi {
  final release = Completer<void>();
  void Function(String)? update;
  void Function(Map<String, String>)? tool;
  bool active = false;
  @override
  bool get canCancel => active;
  @override
  void cancelRequest() { if (!release.isCompleted) release.complete(); }
  @override
  Future<void> send(AiConversation chat, String text, AiConfirmation confirm,
      {void Function(String)? onProgress, void Function(String)? onText,
       void Function(Map<String, String>)? onTool, bool retry = false}) async {
    active = true;
    update = onText; tool = onTool;
    chat.messages.add(AiMessage('user', text));
    onProgress?.call('messageAccepted');
    onProgress?.call('requestingResponse');
    onText?.call('Streaming partial');
    await release.future;
    active = false;
    chat.messages.add(AiMessage('assistant', 'Streaming complete'));
    onProgress?.call('messagesUpdated');
  }
}

void main() {
  testWidgets('streaming text and tool card update before completion without duplicate reply', (tester) async {
    final ai = StreamingUiAi();
    final surface = await fixture.bridge(ai);
    await surface.domain.auth.saveAccount(const GhAccount(id: 'alice', login: 'alice'), const GhToken('ghp_test'));
    await surface.domain.auth.switchTo('alice');
    await tester.pumpWidget(MaterialApp(home: AiChatPage(surface: surface)));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Hello');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.arrow_upward));
    await tester.pump();
    expect(find.text('Streaming partial'), findsOneWidget);
    ai.update?.call('Streaming partial extended');
    ai.tool?.call({'name': 'github_read', 'repo': 'alice/repo', 'status': 'running'});
    await tester.pump();
    expect(find.text('Streaming partial extended'), findsOneWidget);
    expect(find.byType(ExpansionTile), findsOneWidget);
    expect(find.byIcon(Icons.stop_circle_outlined), findsOneWidget);
    ai.release.complete();
    await tester.pumpAndSettle();
    expect(find.text('Streaming partial extended'), findsNothing);
    expect(find.text('Streaming complete'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
