import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ohgithublost/domain/ai/ai_conversation_store.dart';
import 'package:ohgithublost/domain/ai/ai_models.dart';
import 'package:ohgithublost/kernel/contract/disk_store.dart';

AiConversation chat(String id, [String user = 'alice']) => AiConversation(
  id: id, accountId: user, messages: [AiMessage('user', 'message-$id')]);

class FailingVault extends InMemoryVault {
  String? failKey;
  @override
  Future<void> writeSecret(String key, String value) async {
    if (key == failKey) throw StateError('write failed');
    await super.writeSecret(key, value);
  }
}

void main() {
  test('legacy migration preserves messages and supports deleting migrated data', () async {
    final vault = InMemoryVault();
    await vault.writeSecret('ai.chats.alice', jsonEncode([chat('one').toJson()]));
    final store = AiConversationStore(vault);
    expect((await store.list('alice')).single.messages.single.content, 'message-one');
    expect(await vault.readSecret('ai.chats.alice'), isNull);
    await store.delete('alice', 'one');
    expect(await store.list('alice'), isEmpty);
    expect(await vault.readSecret('ai.chat.alice.one'), isNull);
  });

  test('failed migration keeps legacy data and next operation retries', () async {
    final vault = FailingVault();
    await vault.writeSecret('ai.chats.alice', jsonEncode([chat('one').toJson()]));
    vault.failKey = 'ai.chat-index.alice';
    final store = AiConversationStore(vault);
    await expectLater(store.list('alice'), throwsStateError);
    expect(await vault.readSecret('ai.chats.alice'), isNotNull);
    vault.failKey = null;
    expect((await store.list('alice')).single.id, 'one');
  });

  test('concurrent saves do not lose index entries or truncate history at 50', () async {
    final vault = InMemoryVault();
    final store = AiConversationStore(vault);
    await Future.wait(List.generate(55, (i) => store.save(chat('$i'))));
    expect((await store.list('alice')).length, 55);
    await store.save(chat('bob-chat', 'bob'));
    expect((await store.list('bob')).single.id, 'bob-chat');
    expect((await store.list('alice')).length, 55);
  });

  test('saving one conversation does not rewrite another conversation', () async {
    final vault = InMemoryVault();
    final store = AiConversationStore(vault);
    await store.save(chat('one'));
    await store.save(chat('two'));
    final original = await vault.readSecret('ai.chat.alice.one');
    final updated = chat('two')..messages.add(AiMessage('assistant', 'reply'));
    await store.save(updated);
    expect(await vault.readSecret('ai.chat.alice.one'), original);
    expect((await store.list('alice')).first.messages.length, 2);
  });
}
