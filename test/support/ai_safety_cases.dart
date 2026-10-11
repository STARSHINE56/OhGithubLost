// 离线入口不经过 pub，必须保留可解析的相对路径。
// ignore_for_file: avoid_relative_lib_imports

/// 同一组安全回归同时用于 Flutter CI 与无 Flutter 的离线自检。
library;

import 'dart:convert';

import '../../lib/domain/ai/ai_models.dart';
import '../../lib/domain/ai/ai_provider.dart';
import '../../lib/domain/ai/ai_service.dart';
import '../../lib/domain/productivity/productivity_service.dart';
import '../../lib/kernel/contract/disk_store.dart';

void require(bool condition, String message) {
  if (!condition) {
    throw StateError(message);
  }
}

Future<void> rejects(Future<void> Function() action, String code) async {
  try {
    await action();
  } on AiException catch (e) {
    require(e.code == code, 'Expected $code, got ${e.code}');
    return;
  }
  throw StateError('Expected rejection $code');
}

/// 模拟真实 Git 对象与 ref，包含并发提交造成的非快进冲突。
class FakeGithub {
  String head = 'base', tree = 'old-tree', user = 'alice';
  bool race = false;
  final calls = <Map<String, dynamic>>[];
  Future<Object?> request(
    String method,
    String path,
    Map<String, Object?>? body,
    Map<String, String> query,
  ) async {
    calls.add({'method': method, 'path': path, 'body': body, 'query': query});
    if (method == 'GET') {
      if (path.contains('/git/ref/')) {
        return {
          'object': {'sha': head},
        };
      }
      if (path.contains('/git/commits/')) {
        return {
          'tree': {'sha': tree},
        };
      }
      if (path.contains('/git/trees/')) {
        return {
          'tree': [
            {
              'path': 'run.sh',
              'type': 'blob',
              'mode': '100755',
              'sha': 'blob',
              'size': 3,
            },
            {
              'path': 'old.dart',
              'type': 'blob',
              'mode': '100644',
              'sha': 'blob',
              'size': 3,
            },
          ],
          'truncated': false,
        };
      }
      if (path.contains('/git/blobs/')) {
        return {'content': base64Encode(utf8.encode('old'))};
      }
      if (path == '/repos/owner/repo') {
        return {'full_name': 'owner/repo', 'default_branch': 'main'};
      }
      if (path == '/search/repositories') {
        return {
          'total_count': 2,
          'items': [
            {'name': 'repo', 'full_name': 'owner/repo'},
            {'name': 'repo', 'full_name': 'other/repo'},
          ],
        };
      }
      return {};
    }
    if (path.endsWith('/git/trees')) {
      return {'sha': 'new-tree'};
    }
    if (path.endsWith('/git/commits')) {
      if (race) {
        head = 'someone-else';
      }
      return {
        'sha': 'new-commit',
        'html_url': 'https://github.com/owner/repo/commit/new-commit',
      };
    }
    if (path.contains('/git/refs/')) {
      require(body?['force'] == false, 'Force push is forbidden');
      if (head != 'base' && head != 'new-commit') {
        throw StateError('Non-fast-forward');
      }
      head = body!['sha'] as String;
      return {};
    }
    return {};
  }

  List<Map<String, dynamic>> get writes =>
      calls.where((e) => e['method'] != 'GET').toList();
}

AiService service(
  FakeGithub gh, {
  InMemoryKv? store,
  InMemoryVault? vault,
  AiProviderRequest? provider,
}) => AiService(
  store: store ?? InMemoryKv(),
  vault: vault ?? InMemoryVault(),
  github: gh.request,
  account: () async => gh.user,
  provider:
      provider ??
      (config, endpoint, key, body) async => {
        'data': [
          {'id': 'detected-model'},
        ],
      },
);
AiConversation chat() => AiConversation(
  id: 'chat',
  accountId: 'alice',
  repo: 'owner/repo',
  branch: 'main',
);
Future<AiProposal> proposal(AiService ai) => ai.prepareFiles(chat(), [
  {'path': 'run.sh', 'content': 'new'},
  {'path': 'old.dart', 'content': null},
], 'Update files');

Map<String, Future<void> Function()> aiSafetyCases() => {
  'API keys remain encrypted and isolated by provider URL': () async {
    final gh = FakeGithub(), kv = InMemoryKv(), vault = InMemoryVault();
    final ai = service(gh, store: kv, vault: vault);
    const config = AiSettings(enabled: true, baseUrl: 'https://example.com/v1');
    await ai.saveSettings(config, key: 'SECRET');
    require(!jsonEncode(kv.snapshot).contains('SECRET'), 'Key leaked to KV');
    require(await ai.hasKey(config: config), 'Expected saved key');
    require(
      !await ai.hasKey(
        config: const AiSettings(baseUrl: 'https://other.example/v1'),
      ),
      'Cross-provider key reuse',
    );
  },
  'Cancelled confirmation performs zero writes': () async {
    final gh = FakeGithub(), ai = service(FakeGithub());
    final target = service(gh);
    final p = await proposal(target);
    await target.executeProposal(p, (_) async => false);
    require(gh.writes.isEmpty, 'Write before confirmation');
    require(await ai.hasKey() == false, 'Unexpected key');
  },
  'Account switch during confirmation refuses all writes': () async {
    final gh = FakeGithub();
    final ai = service(gh);
    final p = await proposal(ai);
    await rejects(() async {
      await ai.executeProposal(p, (_) async {
        gh.user = 'bob';
        return true;
      });
    }, 'accountChanged');
    require(gh.writes.isEmpty, 'Write after switching account');
  },
  'Changed HEAD never overwrites a newer commit': () async {
    final gh = FakeGithub();
    final ai = service(gh);
    final p = await proposal(ai);
    gh.head = 'newer';
    await rejects(() async {
      await ai.executeProposal(p, (_) async => true);
    }, 'headChanged');
    require(
      !gh.writes.any((e) => e['path'].contains('/git/refs/')),
      'Updated changed HEAD',
    );
  },
  'Atomic file changes preserve executable mode and deletion': () async {
    final gh = FakeGithub();
    final ai = service(gh);
    final p = await proposal(ai);
    require(p.files.first.before == 'old', 'Missing real baseline');
    await ai.executeProposal(p, (_) async => true);
    final tree =
        gh.writes.singleWhere((e) => e['path'].endsWith('/git/trees'))['body']
            as Map;
    final entries = tree['tree'] as List;
    require(entries[0]['mode'] == '100755', 'Executable mode lost');
    require(
      entries[1].containsKey('sha') && entries[1]['sha'] == null,
      'Deletion not represented',
    );
    require(
      gh.writes.where((e) => e['path'].endsWith('/git/commits')).length == 1,
      'Non-atomic commit',
    );
    require(gh.head == 'new-commit', 'Commit not applied');
  },
  'Concurrent commit makes non-force ref update fail safely': () async {
    final gh = FakeGithub();
    final ai = service(gh);
    final p = await proposal(ai);
    gh.race = true;
    bool failed = false;
    try {
      await ai.executeProposal(p, (_) async => true);
    } catch (_) {
      failed = true;
    }
    require(
      failed && gh.head == 'someone-else',
      'Concurrent commit overwritten',
    );
    require(
      (await ai.audit()).any((e) => e['status'] == 'pending'),
      'Crash recovery journal missing',
    );
  },
  'Rollback creates a new commit with the original tree': () async {
    final gh = FakeGithub();
    final ai = service(gh);
    await ai.executeProposal(await proposal(ai), (_) async => true);
    final entry = (await ai.audit()).firstWhere(
      (e) => e['status'] == 'committed',
    );
    await ai.rollback(entry, (_) async => true);
    final writes = gh.writes
        .where((e) => e['path'].endsWith('/git/commits'))
        .toList();
    final body = writes.last['body'] as Map;
    require(body['tree'] == 'old-tree', 'Wrong rollback tree');
    require(
      (body['parents'] as List).single == 'new-commit',
      'History reset instead of revert',
    );
  },
  'Rollback refuses when later commits exist': () async {
    final gh = FakeGithub();
    final ai = service(gh);
    await ai.executeProposal(await proposal(ai), (_) async => true);
    final entry = (await ai.audit()).firstWhere(
      (e) => e['status'] == 'committed',
    );
    gh.head = 'later';
    final count = gh.writes.length;
    await rejects(() async {
      await ai.rollback(entry, (_) async => true);
    }, 'headChanged');
    require(gh.writes.length == count, 'Rollback wrote after conflict');
  },
  'Path traversal and duplicate files are rejected': () async {
    final gh = FakeGithub();
    final ai = service(gh);
    await rejects(() async {
      await ai.prepareFiles(chat(), [
        {'path': '../secrets', 'content': 'x'},
      ], 'msg');
    }, 'invalidPath');
    await rejects(() async {
      await ai.prepareFiles(chat(), [
        {'path': 'a', 'content': 'x'},
        {'path': 'a', 'content': 'y'},
      ], 'msg');
    }, 'invalidProposal');
    require(gh.writes.isEmpty, 'Invalid path wrote data');
  },
  'Credential files cannot be sent to the provider': () async {
    final gh = FakeGithub();
    final ai = service(gh);
    await rejects(() async {
      await ai.prepareFiles(chat(), [
        {'path': '.env', 'content': 'x'},
      ], 'msg');
    }, 'secretFile');
    require(gh.writes.isEmpty, 'Credential file written');
  },
  'Ambiguous repository short names are never guessed': () async {
    final ai = service(FakeGithub());
    await rejects(() async {
      await ai.switchRepo(chat(), 'repo');
    }, 'ambiguousRepo');
  },
  'Model auto-detection uses returned IDs only': () async {
    final ai = service(FakeGithub());
    await ai.saveSettings(const AiSettings(), key: 'k');
    final models = await ai.detectModels();
    require(models.single == 'detected-model', 'Hardcoded model');
  },
  'Truncated provider output never executes tool calls': () async {
    final gh = FakeGithub();
    final ai = service(
      gh,
      provider: (config, endpoint, key, body) async => endpoint == 'models'
          ? {
              'data': [
                {'id': 'real-model'},
              ],
            }
          : {
              'choices': [
                {
                  'finish_reason': 'length',
                  'message': {'role': 'assistant', 'tool_calls': []},
                },
              ],
            },
    );
    await ai.saveSettings(const AiSettings(enabled: true), key: 'k');
    await rejects(() async {
      await ai.send(chat(), 'do it', (_) async => true);
    }, 'responseTruncated');
    require(gh.writes.isEmpty, 'Truncated output wrote to GitHub');
  },
  'OpenAI provider uses configured host and bearer auth': () async {
    final provider = AiProvider((url, headers, body) async {
      require(url == 'https://custom.example/v1/models', 'Wrong host');
      require(headers['authorization'] == 'Bearer KEY', 'Wrong auth');
      require(!headers.containsKey('x-api-key'), 'Credentials mixed');
      return {
        'data': [
          {'id': 'custom-model'},
        ],
      };
    });
    await provider.request(
      const AiSettings(baseUrl: 'https://custom.example/v1'),
      'models',
      'KEY',
      null,
    );
  },
  'Claude model list pagination uses native authentication': () async {
    var page = 0;
    final provider = AiProvider((url, headers, body) async {
      require(
        headers['x-api-key'] == 'KEY' && !headers.containsKey('authorization'),
        'Wrong Claude auth',
      );
      page++;
      return page == 1
          ? {
              'data': [
                {'id': 'claude-a'},
              ],
              'has_more': true,
              'last_id': 'claude-a',
            }
          : {
              'data': [
                {'id': 'claude-b'},
              ],
              'has_more': false,
            };
    });
    final result = await provider.request(
      const AiSettings(
        kind: 'anthropic',
        baseUrl: 'https://api.anthropic.com/v1',
      ),
      'models',
      'KEY',
      null,
    );
    require(
      (result['data'] as List).length == 2 && page == 2,
      'Pagination lost models',
    );
  },
  'Gemini filters out models without generateContent': () async {
    final provider = AiProvider((url, headers, body) async {
      require(
        headers['x-goog-api-key'] == 'KEY' && !url.contains('KEY'),
        'Key in URL',
      );
      return {
        'models': [
          {
            'name': 'models/chat',
            'supportedGenerationMethods': ['generateContent'],
          },
          {
            'name': 'models/embed',
            'supportedGenerationMethods': ['embedContent'],
          },
        ],
      };
    });
    final result = await provider.request(
      const AiSettings(
        kind: 'gemini',
        baseUrl: 'https://generativelanguage.googleapis.com/v1beta',
      ),
      'models',
      'KEY',
      null,
    );
    require(
      (result['data'] as List).single['id'] == 'chat',
      'Embedding model offered',
    );
  },
  'Untrusted endpoint schemes and embedded credentials are rejected': () async {
    bool requested = false;
    final provider = AiProvider((url, headers, body) async {
      requested = true;
      return {};
    });
    for (final url in [
      'http://example.com',
      'https://user:pass@example.com',
      'https://example.com?key=k',
    ]) {
      await rejects(() async {
        await provider.request(AiSettings(baseUrl: url), 'models', 'KEY', null);
      }, 'invalidEndpoint');
    }
    require(!requested, 'Unsafe endpoint received secret');
  },
  'Star organization is isolated by current account': () async {
    final kv = InMemoryKv();
    var id = 'alice';
    final service = ProductivityService(
      store: kv,
      github: FakeGithub().request,
      account: () async => id,
    );
    await service.organizeStar('owner/repo', 'tools', ['Dart', 'Dart']);
    require(
      ((await service.starMetadata())['owner/repo']['tags'] as List).length ==
          1,
      'Tags not deduplicated',
    );
    id = 'bob';
    require((await service.starMetadata()).isEmpty, 'Account metadata leaked');
  },
};
