import 'package:flutter_test/flutter_test.dart';
import 'package:ohgithublost/domain/ai/ai_models.dart';
import 'package:ohgithublost/domain/ai/ai_service.dart';
import 'package:ohgithublost/kernel/contract/disk_store.dart';

class ReadTrackingVault extends InMemoryVault {
  final reads = <String>[];
  @override
  Future<String?> readSecret(String key) { reads.add(key); return super.readSecret(key); }
}

void main() {
  test('summary reads no full body and renaming a summary preserves full messages', () async {
    final vault = ReadTrackingVault();
    final ai = AiService(store: InMemoryKv(), vault: vault,
      github: (_, __, ___, ____) async => {}, provider: (_, __, ___, ____) async => {}, account: () async => 'alice');
    final chat = await ai.newConversation();
    chat.messages.addAll([AiMessage('user', 'long' * 100), AiMessage('assistant', 'answer')]);
    await ai.saveConversation(chat);
    vault.reads.clear();
    final summary = (await ai.conversationSummaries()).single;
    expect(vault.reads, isNot(contains('ai.chat.alice.${chat.id}')));
    expect(summary.messages.single.content.length, 120);
    await ai.renameConversation(summary, 'New title');
    final loaded = await ai.loadConversation(chat.id);
    expect(loaded.messages.length, 2);
    expect(loaded.messages.first.content.length, 400);
    expect(loaded.title, 'New title');
  });

  test('response retry reuses last user message and does not execute returned tools', () async {
    var writes = 0;
    final ai = AiService(store: InMemoryKv(), vault: InMemoryVault(),
      github: (_, __, ___, ____) async { writes++; return {}; },
      provider: (_, endpoint, __, body) async {
        if (endpoint == 'models') return {'data': [{'id': 'model'}]};
        expect(body!['tools'], isEmpty);
        return {'choices': [{'message': {'role': 'assistant', 'content': 'done'}}]};
      }, account: () async => 'alice');
    await ai.saveSettings(const AiSettings(enabled: true), key: 'AI');
    final chat = await ai.newConversation();
    chat.messages.add(AiMessage('user', 'hello'));
    await ai.saveConversation(chat);
    await ai.send(chat, 'hello', (_) async => false, retry: true);
    expect(chat.messages.where((m) => m.role == 'user').length, 1);
    expect(writes, 0);
  });
}
