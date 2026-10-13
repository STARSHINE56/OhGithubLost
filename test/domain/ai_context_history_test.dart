import 'package:flutter_test/flutter_test.dart';
import 'package:ohgithublost/domain/ai/ai_models.dart';
import 'package:ohgithublost/domain/ai/ai_service.dart';
import 'package:ohgithublost/kernel/contract/disk_store.dart';

void main() {
  test('old conversation remains readable and title persists without changing messages', () async {
    final old = AiConversation(id: 'chat', accountId: 'alice', messages: [AiMessage('user', 'Original')]).toJson()..remove('title');
    expect(AiConversation.fromJson(Map<String, dynamic>.from(old)).title, '');
    final ai = AiService(store: InMemoryKv(), vault: InMemoryVault(),
      github: (_, __, ___, ____) async => {}, provider: (_, __, ___, ____) async => {},
      account: () async => 'alice');
    final chat = AiConversation.fromJson(Map<String, dynamic>.from(old));
    await ai.saveConversation(chat);
    await ai.renameConversation(chat, '  Work  ');
    final saved = (await ai.conversations()).single;
    expect(saved.title, 'Work');
    expect(saved.messages.single.content, 'Original');
    await ai.renameConversation(chat, '');
    expect((await ai.conversations()).single.title, '');
  });

  test('context selection is account-bound, validates branch, and persists only after success', () async {
    var user = 'alice';
    var fail = false;
    final calls = <String>[];
    final ai = AiService(store: InMemoryKv(), vault: InMemoryVault(),
      github: (_, __, ___, ____) async => throw StateError('unbound'),
      accountGithub: (id, method, path, body, query) async {
        expect(id, 'alice'); expect(method, 'GET'); calls.add(path);
        if (fail) throw StateError('not found');
        if (path == '/user/repos') return [{'full_name': 'alice/repo'}];
        if (path.endsWith('/branches')) return [{'name': 'feature/test'}];
        return {'name': 'feature/test'};
      }, provider: (_, __, ___, ____) async => {}, account: () async => user);
    final chat = await ai.newConversation();
    expect((await ai.contextRepositories()).single['full_name'], 'alice/repo');
    expect(await ai.contextBranches('alice/repo'), ['feature/test']);
    await ai.setContext(chat, 'alice/repo', 'feature/test');
    expect(calls.last, '/repos/alice/repo/branches/feature%2Ftest');
    expect((await ai.conversations()).single.branch, 'feature/test');
    fail = true;
    await expectLater(ai.setContext(chat, 'alice/repo', 'missing'), throwsStateError);
    expect(chat.branch, 'feature/test');
    user = 'bob';
    await expectLater(ai.renameConversation(chat, 'Other'), throwsA(isA<AiException>()));
    expect(chat.title, '');
  });
}
