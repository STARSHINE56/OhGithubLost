import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ohgithublost/domain/ai/ai_github_tools.dart';
import 'package:ohgithublost/domain/ai/ai_models.dart';
import 'package:ohgithublost/domain/ai/ai_service.dart';
import 'package:ohgithublost/kernel/contract/disk_store.dart';

void main() {
  test('account repository listing requires no chosen repository and is paginated', () {
    final plan = AiGithubTools.read({'action': 'my_repositories', 'page': 2}, '');
    expect(plan.path, '/user/repos');
    expect(plan.query['page'], '2');
    expect(plan.query['per_page'], '100');
    expect(plan.query['visibility'], 'all');
  });
  test('arbitrary URLs actions and invalid pagination are rejected', () {
    for (final args in [{'action': 'https://evil.example'},
      {'action': 'my_repositories', 'page': 0}, {'action': 'repository', 'repository': '../'}]) {
      expect(() => AiGithubTools.read(args, ''), throwsA(isA<AiException>()));
    }
    expect(() => AiGithubTools.write({'action': 'force_push'}, 'owner/repo'), throwsA(isA<AiException>()));
    expect(() => AiGithubTools.write({'action': 'update_repository', 'body': {'token': 'secret'}}, 'owner/repo'), throwsA(isA<AiException>()));
  });
  test('merging pull requires confirmed head SHA and no force options', () {
    expect(() => AiGithubTools.write({'action': 'merge_pull', 'number': 1, 'body': {}}, 'owner/repo'), throwsA(isA<AiException>()));
    final plan = AiGithubTools.write({'action': 'merge_pull', 'number': 1,
      'body': {'sha': 'a' * 40, 'merge_method': 'squash'}}, 'owner/repo');
    expect(plan.path, '/repos/owner/repo/pulls/1/merge');
  });
  test('new account operation cannot write before confirmation or after account switch', () async {
    var user = 'alice';
    var writes = 0;
    final service = AiService(store: InMemoryKv(), vault: InMemoryVault(),
      github: (_, __, ___, ____) async { writes++; return {}; },
      provider: (_, __, ___, ____) async => {}, account: () async => user);
    final p = AiProposal(operation: 'github_manage', accountId: 'alice', repo: '', branch: '',
      payload: {'action': 'create_repository', 'body': {'name': 'new-repo', 'private': true}});
    expect((await service.executeProposal(p, (_) async => false))['cancelled'], isTrue);
    expect(writes, 0);
    await expectLater(service.executeProposal(p, (_) async { user = 'bob'; return true; }), throwsA(isA<AiException>()));
    expect(writes, 0);
    user = 'alice';
    await service.executeProposal(p, (_) async => true);
    expect(writes, 1);
  });
  test('assistant lists repositories without selecting a repository or exposing a token', () async {
    var turns = 0;
    final calls = <String>[];
    final service = AiService(store: InMemoryKv(), vault: InMemoryVault(),
      github: (method, path, body, query) async {
        calls.add(path);
        if (query['page'] == '1') {
          return List.generate(100, (i) => {'full_name': 'alice/repo$i', 'private': true});
        }
        return [{'full_name': 'alice/example', 'private': true}];
      },
      provider: (config, endpoint, key, body) async {
        if (endpoint == 'models') return {'data': [{'id': 'model'}]};
        return {'choices': [{'message': ++turns == 1 ? {
          'role': 'assistant', 'content': null, 'tool_calls': [{
            'id': '1', 'type': 'function', 'function': {'name': 'github_read',
              'arguments': jsonEncode({'action': 'my_repositories', 'page': 1})}}]
        } : {'role': 'assistant', 'content': 'alice/example'}}]};
      }, account: () async => 'alice');
    await service.saveSettings(const AiSettings(enabled: true), key: 'AI-only');
    final chat = await service.newConversation();
    await service.send(chat, 'List my repositories', (_) async => false);
    expect(calls, ['/user/repos', '/user/repos']);
    expect(chat.messages.last.content, 'alice/example');
  });
  test('credential gist filenames remain blocked', () {
    expect(() => AiGithubTools.write({'action': 'create_gist',
      'body': {'files': {'.env': {'content': 'secret'}}}}, ''), throwsA(isA<AiException>()));
  });
}
