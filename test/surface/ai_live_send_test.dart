import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ohgithublost/domain/ai/ai_service.dart';
import 'package:ohgithublost/kernel/contract/disk_store.dart';
import 'package:ohgithublost/surface/pages/ai_chat_page.dart';
import 'package:ohgithublost/surface/pages/ai_settings_page.dart';
import 'package:ohgithublost/surface/types.dart';

import 'ai_lifecycle_test.dart' as fixture;

class LiveAi extends fixture.DelayedAi {
  final started = Completer<void>();
  final release = Completer<void>();
  @override
  Future<void> send(AiConversation chat, String text, AiConfirmation confirm,
      {void Function(String state)? onProgress, void Function(String text)? onText,
      void Function(Map<String, String> event)? onTool, bool retry = false}) async {
    onProgress?.call('preparingRequest');
    started.complete();
    await release.future;
    chat.messages.add(AiMessage('user', text));
    onProgress?.call('messageAccepted');
    onProgress?.call('executingTool');
    await Future<void>.delayed(Duration.zero);
    chat.messages.add(AiMessage('assistant', 'Answer arrived'));
    onProgress?.call('messagesUpdated');
  }
}

void main() {
  testWidgets('user message and preparation state show before request finishes exactly once', (tester) async {
    final ai = LiveAi();
    final surface = await fixture.bridge(ai);
    await surface.domain.auth.saveAccount(const GhAccount(id: 'alice', login: 'alice'), const GhToken('ghp_test'));
    await surface.domain.auth.switchTo('alice');
    await tester.pumpWidget(MaterialApp(home: AiChatPage(surface: surface)));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Immediate message');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.arrow_upward));
    await tester.pump();
    expect(ai.started.isCompleted, isTrue);
    expect(find.text('Immediate message'), findsOneWidget);
    expect(find.text(aiText('preparingRequest')), findsOneWidget);
    expect(find.text('Answer arrived'), findsNothing);
    ai.release.complete();
    await tester.pumpAndSettle();
    expect(find.text('Immediate message'), findsOneWidget);
    expect(find.text('Answer arrived'), findsOneWidget);
    expect(find.byKey(const ValueKey('ai-send-status')), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  test('real service emits accepted message and request state while provider is pending', () async {
    final waiting = Completer<Map<String, dynamic>>();
    final requested = Completer<void>();
    final states = <String>[];
    final ai = AiService(store: InMemoryKv(), vault: InMemoryVault(),
      account: () async => 'alice', github: (_, __, ___, ____) async => {},
      provider: (_, endpoint, __, ___) async {
        if (endpoint == 'models') return {'data': [{'id': 'model'}]};
        requested.complete();
        return waiting.future;
      });
    await ai.saveSettings(const AiSettings(enabled: true), key: 'AI-test');
    final chat = await ai.newConversation();
    final operation = ai.send(chat, 'Hello', (_) async => false, onProgress: states.add);
    await requested.future;
    expect(chat.messages.single.content, 'Hello');
    expect(states, containsAllInOrder(['preparingRequest', 'messageAccepted', 'requestingResponse']));
    waiting.complete({'choices': [{'message': {'role': 'assistant', 'content': 'Done'}}]});
    await operation;
    expect(chat.messages.where((m) => m.role == 'user').length, 1);
    expect(states.last, 'messagesUpdated');
  });
}
