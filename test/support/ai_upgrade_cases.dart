// ignore_for_file: avoid_relative_lib_imports
/// 与 Flutter CI 共用的纯 Dart 账号、预算、缓存和模型能力回归。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import '../../lib/domain/ai/ai_context.dart';
import '../../lib/domain/ai/ai_models.dart';
import '../../lib/domain/ai/ai_provider.dart';
import '../../lib/domain/ai/ai_service.dart';
import '../../lib/domain/productivity/productivity_service.dart';
import '../../lib/kernel/contract/disk_store.dart';
import 'ai_safety_cases.dart' show require, rejects;

Map<String, Future<void> Function()> aiUpgradeCases() => {
      'Unavailable notification authorization blocks requests without faking an empty inbox':
          () async {
        var requests = 0;
        final service = ProductivityService(
            store: InMemoryKv(),
            account: () async => 'alice',
            notificationAccess: (_) async {
              throw const AiException('notificationsTokenUnsupported');
            },
            github: (_, path, body, query) async {
              requests++;
              return [];
            });
        await rejects(() async {
          await service.notifications();
        }, 'notificationsTokenUnsupported');
        await rejects(
            () => service.markRead('123'), 'notificationsTokenUnsupported');
        require(requests == 0, 'Unsupported notifications still hit the API');
      },
      'Notification pagination and read operations bind to the selected account':
          () async {
        var account = 'alice';
        final requests = <String>[];
        final service = ProductivityService(
            store: InMemoryKv(),
            account: () async => account,
            github: (_, path, body, query) async {
              throw StateError('Unbound request');
            },
            scopedGithub: (id, method, path, body, query) async {
              requests.add('$id:$method:$path');
              if (method == 'GET') {
                require(
                    query['page'] == '2' &&
                        query['all'] == 'true' &&
                        query['per_page'] == '50',
                    'Pagination flags lost');
                return [
                  {'id': '123', 'owner': id}
                ];
              }
              return {};
            });
        require(
            (await service.notifications(page: 2, all: true)).single['owner'] ==
                'alice',
            'Wrong account');
        await service.markRead('123');
        account = 'bob';
        require(
            (await service.notifications(page: 2, all: true)).single['owner'] ==
                'bob',
            'Account switch was ignored');
        require(
            requests.join('|') ==
                'alice:GET:/notifications|alice:PATCH:/notifications/threads/123|bob:GET:/notifications',
            'Scoped API requests changed');
      },
      'Account changes during permission checks or notification responses are rejected':
          () async {
        var account = 'alice', requests = 0;
        final before = ProductivityService(
            store: InMemoryKv(),
            account: () async => account,
            notificationAccess: (_) async {
              account = 'bob';
            },
            github: (_, path, body, query) async {
              requests++;
              return [];
            });
        await rejects(() async {
          await before.notifications();
        }, 'accountChanged');
        require(requests == 0, 'A switched account used the wrong credential');
        account = 'alice';
        final after = ProductivityService(
            store: InMemoryKv(),
            account: () async => account,
            github: (_, path, body, query) async {
              account = 'bob';
              return [
                {'private': 'alice'}
              ];
            });
        await rejects(() async {
          await after.notifications();
        }, 'accountChanged');
      },
      'Provider output defaults omit unused limits and keep required Messages parameters':
          () async {
        for (final kind in ['openai', 'anthropic', 'gemini']) {
          final provider = AiProvider((url, headers, body) async {
            if (kind == 'openai') {
              require(
                  !body!.containsKey('max_tokens') &&
                      !body.containsKey('max_completion_tokens'),
                  'Null or forced OpenAI output limit');
              return {
                'choices': [
                  {
                    'message': {'role': 'assistant', 'content': 'ok'}
                  }
                ]
              };
            }
            if (kind == 'anthropic') {
              require(body!['max_tokens'] == 4096,
                  'Messages required parameter missing');
              return {
                'content': [
                  {'type': 'text', 'text': 'ok'}
                ],
                'stop_reason': 'end_turn'
              };
            }
            require(
                !(body!['generationConfig'] as Map)
                    .containsKey('maxOutputTokens'),
                'Forced Gemini output limit');
            return {
              'candidates': [
                {
                  'content': {
                    'parts': [
                      {'text': 'ok'}
                    ]
                  },
                  'finishReason': 'STOP'
                }
              ]
            };
          });
          await provider.request(
              AiSettings(kind: kind, baseUrl: 'https://service.example/v1'),
              'chat/completions',
              'KEY', {
            'model': 'manual',
            'messages': [
              {'role': 'user', 'content': 'hello'}
            ]
          });
        }
      },
      'Model can update a repository description through the confirmed GitHub tool':
          () async {
        var requests = 0, writes = 0, description = '????';
        final ai = AiService(
            store: InMemoryKv(),
            vault: InMemoryVault(),
            account: () async => 'alice',
            github: (method, path, body, query) async {
              require(path == '/repos/alice/repo', 'Wrong API path');
              if (method == 'PATCH') {
                writes++;
                description = body!['description'] as String;
              }
              return {
                'full_name': 'alice/repo',
                'default_branch': 'main',
                'description': description
              };
            },
            provider: (_, endpoint, key, body) async {
              if (++requests == 1) {
                return {
                  'choices': [
                    {
                      'message': {
                        'role': 'assistant',
                        'content': '',
                        'tool_calls': [
                          {
                            'id': 'metadata',
                            'type': 'function',
                            'function': {
                              'name': 'update_repository',
                              'arguments': '{"description":"正常介绍"}'
                            }
                          }
                        ]
                      }
                    }
                  ]
                };
              }
              require(jsonEncode(body).contains('正常介绍'),
                  'Actual mutation result was not returned to model');
              return {
                'choices': [
                  {
                    'message': {'role': 'assistant', 'content': 'done'}
                  }
                ]
              };
            });
        await ai.saveSettings(const AiSettings(enabled: true, model: 'manual'),
            key: 'KEY');
        final chat =
            await ai.newConversation(repo: 'alice/repo', branch: 'main');
        await ai.send(chat, '改为正常介绍', (p) async {
          require(
              p.operation == 'update_repository' &&
                  p.files.single.before == '????' &&
                  p.files.single.after == '正常介绍',
              'Missing metadata diff');
          return true;
        });
        require(writes == 1 && requests == 2 && description == '正常介绍',
            'Metadata tool was unavailable or failed');
      },
      'Tasks can exceed previous model-round and tool-call quotas': () async {
        var requests = 0, calls = 0;
        final ai = AiService(
            store: InMemoryKv(),
            vault: InMemoryVault(),
            account: () async => 'alice',
            github: (_, path, body, query) async {
              calls++;
              return {'login': 'alice'};
            },
            provider: (_, endpoint, key, body) async {
              requests++;
              return {
                'choices': [
                  {
                    'message': requests <= 20
                        ? {
                            'role': 'assistant',
                            'content': '',
                            'tool_calls': [
                              for (var i = 0; i < 2; i++)
                                {
                                  'id': '$requests-$i',
                                  'type': 'function',
                                  'function': {
                                    'name': 'current_user',
                                    'arguments': '{}'
                                  }
                                }
                            ]
                          }
                        : {'role': 'assistant', 'content': 'done'}
                  }
                ]
              };
            });
        await ai.saveSettings(
            const AiSettings(
                enabled: true,
                model: 'manual',
                taskBudget: 1024,
                contextTokens: 1024),
            key: 'KEY');
        final chat = await ai.newConversation();
        await ai.send(chat, '查看账号', (_) async => false);
        // GitHub GET 允许复用相同账号缓存；模型工具结果仍完整配对。
        require(
            requests == 21 &&
                calls >= 1 &&
                chat.messages.last.content == 'done',
            'Old quota still aborts a long task');
      },
      'Repository descriptions show a diff and write only after confirmation':
          () async {
        var description = 'Android ?????? - ???', writes = 0;
        final ai = AiService(
            store: InMemoryKv(),
            vault: InMemoryVault(),
            account: () async => 'alice',
            github: (method, path, body, query) async {
              require(path == '/repos/alice/repo', 'Wrong repository target');
              if (method == 'PATCH') {
                writes++;
                description = body!['description'] as String;
              }
              return {
                'description': description,
                'full_name': 'alice/repo',
                'default_branch': 'main'
              };
            },
            provider: (_, endpoint, key, body) async => {});
        final chat =
            await ai.newConversation(repo: 'alice/repo', branch: 'main');
        Future<Object?> update(AiConfirmation confirm) => ai.executeProposal(
            AiProposal(
                operation: 'update_repository',
                accountId: 'alice',
                repo: chat.repo,
                branch: chat.branch,
                payload: {
                  'description': '正常介绍'
                },
                files: [
                  AiFileChange(
                      path: 'description', before: description, after: '正常介绍')
                ]),
            confirm);
        await update((p) async {
          require(
              p.files.single.before == description &&
                  p.files.single.after == '正常介绍',
              'Preview missing');
          return false;
        });
        require(writes == 0, 'Rejected preview mutated repository');
        await update((p) async => true);
        require(writes == 1 && description == '正常介绍',
            'Confirmed metadata update failed');
        await rejects(
            () => update((p) async {
                  description = 'Changed elsewhere';
                  return true;
                }),
            'conflict');
        require(writes == 1, 'Stale preview overwrote another change');
        require(
            !jsonEncode(AiService.availableTools(
                    const AiSettings(toolMode: 'read')))
                .contains('update_repository'),
            'Read-only permission was bypassed');
      },
      'Unrestricted long tool tasks can still be cancelled': () async {
        var requests = 0;
        final cancellation = AiCancellation();
        final ai = AiService(
            store: InMemoryKv(),
            vault: InMemoryVault(),
            account: () async => 'alice',
            github: (_, path, body, query) async => {'login': 'alice'},
            provider: (_, endpoint, key, body) async {
              if (++requests == 15) cancellation.cancel();
              return {
                'choices': [
                  {
                    'message': {
                      'role': 'assistant',
                      'content': '',
                      'tool_calls': [
                        {
                          'id': '$requests',
                          'type': 'function',
                          'function': {
                            'name': 'current_user',
                            'arguments': '{}'
                          }
                        }
                      ]
                    }
                  }
                ]
              };
            });
        await ai.saveSettings(const AiSettings(enabled: true, model: 'manual'),
            key: 'KEY');
        final chat = await ai.newConversation();
        await rejects(
            () => ai.send(chat, '查看账号', (_) async => false,
                cancellation: cancellation),
            'cancelled');
        require(
            requests == 15, 'Cancellation failed or old round quota remained');
      },
      'Saved optimization and tiny budgets cannot restrict normal chat':
          () async {
        var calls = 0;
        final ai = AiService(
            store: InMemoryKv(),
            vault: InMemoryVault(),
            account: () async => 'alice',
            github: (_, path, body, query) async => {},
            provider: (config, endpoint, key, body) async {
              calls++;
              require(
                  !config.optimize &&
                      !config.automaticBudget &&
                      !body!.containsKey('max_tokens'),
                  'Removed optimization still limits chat');
              return {
                'choices': [
                  {
                    'message': {'role': 'assistant', 'content': 'ok'}
                  }
                ]
              };
            });
        final old = AiSettings.fromJson({
          'enabled': true,
          'model': 'manual',
          'taskBudget': 1024,
          'contextTokens': 1024,
          'outputTokens': 128,
          'optimize': true,
          'automaticBudget': true,
          'autoSummary': true
        });
        await ai.saveSettings(old, key: 'KEY');
        final chat = await ai.newConversation();
        chat.usage['input'] = 90000;
        await ai.send(chat, '读取当前仓库', (_) async => false);
        require(calls == 1, 'Historic usage blocked an ordinary request');
      },
      'Tool data is not token-truncated while secrets are removed': () async {
        final content = List.filled(200000, '源码').join();
        final data = AiContext.compress({
          'content': content,
          'files': List.generate(160, (i) => i),
          'authorization': 'private'
        }, const AiSettings()) as Map;
        require(
            data['content'] == content && (data['files'] as List).length == 160,
            'Full tool data was token-truncated');
        require(
            !data.containsKey('authorization'), 'Secret protection removed');
      },
      'Restarted AI service loads its secure key without exposing it in settings or history':
          () async {
        final store = InMemoryKv(), vault = InMemoryVault();
        const secret = 'test-persistent-ai-secret';
        String? usedKey;
        AiService create() => AiService(
            store: store,
            vault: vault,
            account: () async => 'alice',
            github: (_, path, body, query) async => {},
            provider: (_, endpoint, key, body) async {
              usedKey = key;
              require(!jsonEncode(body).contains(secret),
                  'API key leaked into model message payload');
              return {
                'choices': [
                  {
                    'message': {'role': 'assistant', 'content': 'ok'}
                  }
                ]
              };
            });
        const config = AiSettings(enabled: true, model: 'manual');
        final before = create();
        await before.saveSettings(config, key: secret);
        final after = create();
        require(await after.hasKey(), 'Restart lost the secure key');
        await after.saveSettings(await after.settings(), key: '');
        final chat = await after.newConversation();
        await after.send(chat, 'hello', (_) async => false);
        require(usedKey == secret, 'Chat did not reuse the stored credential');
        require(!jsonEncode(store.snapshot).contains(secret),
            'Credential leaked into ordinary settings');
        require(!(await vault.readSecret('ai.chats.alice'))!.contains(secret),
            'Credential leaked into chat history');
        await after.saveSettings(config, clearKey: true);
        require(!await create().hasKey(), 'Explicit deletion did not persist');
      },
      'JSON-capable models are not forced into JSON for ordinary repository queries':
          () async {
        final parameters = <bool>[];
        final ai = AiService(
            store: InMemoryKv(),
            vault: InMemoryVault(),
            account: () async => 'alice',
            github: (_, path, body, query) async => {},
            provider: (config, endpoint, key, body) async {
              parameters.add(config.structured);
              return {
                'choices': [
                  {
                    'message': {'role': 'assistant', 'content': 'ok'}
                  }
                ]
              };
            });
        await ai.saveSettings(
            const AiSettings(enabled: true, model: 'manual', structured: true),
            key: 'test-model-key');
        final chat = await ai.newConversation();
        await ai.send(chat, '列出我的所有仓库', (_) async => false);
        await ai.send(chat, '请用 JSON 格式返回仓库列表', (_) async => false);
        require(parameters.length == 2 && !parameters.first && parameters.last,
            'Global JSON capability forced all responses or ignored explicit format');
      },
      'Changing configured model credentials invalidates detection caches and preserves history':
          () async {
        final ai = AiService(
            store: InMemoryKv(),
            vault: InMemoryVault(),
            account: () async => 'alice',
            github: (_, path, body, query) async => {},
            provider: (config, endpoint, key, body) async =>
                endpoint == 'models'
                    ? {
                        'data': [
                          {'id': 'custom'}
                        ]
                      }
                    : {
                        'choices': [
                          {
                            'message': {
                              'role': 'assistant',
                              'content': '{"ok":true}'
                            }
                          }
                        ]
                      });
        const config = AiSettings(model: 'custom');
        await ai.saveSettings(config, key: 'old-model-key');
        await ai.newConversation();
        await ai.detectModels();
        await ai.detectCapabilities(config);
        await ai.saveSettings(config, key: 'old-model-key');
        require(
            (await ai.cachedModels(config)).isNotEmpty &&
                (await ai.capabilities(config)).isNotEmpty,
            'Unchanged key discarded useful cache');
        await ai.saveSettings(config, key: 'new-model-key');
        require(
            (await ai.cachedModels(config)).isEmpty &&
                (await ai.capabilities(config)).isEmpty,
            'Changed credentials reused stale detection');
        require((await ai.conversations()).length == 1,
            'Credential change deleted chat data');
      },
      'Production GitHub request path receives the conversation account binding':
          () async {
        final ai = AiService(
            store: InMemoryKv(),
            vault: InMemoryVault(),
            account: () async => 'alice',
            provider: (_, endpoint, key, body) async => {},
            github: (_, path, body, query) async =>
                throw StateError('Unbound request used'),
            scopedGithub: (id, method, path, body, query) async {
              require(id == 'alice', 'Wrong account binding');
              return {'login': 'alice'};
            });
        final user = await ai
            .readTool(await ai.newConversation(), 'current_user', {}) as Map;
        require(user['login'] == 'alice', 'Scoped request lost');
      },
      'File ranges use immutable SHA and preserve total line counts': () async {
        final content = List.generate(1000, (i) => '源码行 ${i + 1}').join('\n');
        var reads = 0;
        final ai = AiService(
            store: InMemoryKv(),
            vault: InMemoryVault(),
            account: () async => 'alice',
            provider: (_, endpoint, key, body) async => {},
            github: (method, path, body, query) async {
              if (path.contains('/git/ref/')) {
                return {
                  'object': {'sha': '0123456789012345678901234567890123456789'}
                };
              }
              require(
                  query['ref'] == '0123456789012345678901234567890123456789',
                  'Mutable branch read');
              reads++;
              return {
                'type': 'file',
                'encoding': 'base64',
                'size': utf8.encode(content).length,
                'sha': 'blob',
                'content': base64Encode(utf8.encode(content))
              };
            });
        await ai.saveSettings(const AiSettings(optimization: 'economy'));
        final chat =
            await ai.newConversation(repo: 'alice/repo', branch: 'main');
        final first = await ai.readTool(
            chat, 'read_file', {'path': 'file.dart', 'end_line': 80}) as Map;
        require(
            first['end_line'] == 80 &&
                first['total_lines'] == 1000 &&
                first['complete'] == false,
            'Source range not explicit');
        final second = await ai.readTool(chat, 'read_file',
            {'path': 'file.dart', 'start_line': 81, 'end_line': 100}) as Map;
        require(
            '${second['content']}'.startsWith('源码行 81'), 'Wrong continuation');
        require(reads == 1, 'Unchanged file content not cached');
        final full = await ai.readTool(
            chat, 'read_file', {'path': 'file.dart', 'full': true}) as Map;
        require(full['content'] == content && full['complete'] == true,
            'Full source not available');
      },
      'Provider retries only once for transient errors': () async {
        var attempts = 0;
        final ai = AiService(
            store: InMemoryKv(),
            vault: InMemoryVault(),
            account: () async => 'alice',
            github: (_, path, body, query) async => {},
            provider: (_, endpoint, key, body) async {
              attempts++;
              throw const HttpException('AI HTTP 503');
            });
        await ai.saveSettings(const AiSettings(enabled: true, model: 'manual'),
            key: 'KEY');
        final chat = await ai.newConversation();
        await rejects(() => ai.send(chat, 'hello', (_) async => false),
            'serverUnavailable');
        require(attempts == 2, 'Unbounded retries');
      },
      'Explicit model discovery is cached and structured support is probed independently':
          () async {
        var discoveries = 0, jsonProbes = 0;
        final ai = AiService(
            store: InMemoryKv(),
            vault: InMemoryVault(),
            account: () async => 'alice',
            github: (_, path, body, query) async => {},
            provider: (config, endpoint, key, body) async {
              if (endpoint == 'models') {
                discoveries++;
                return {
                  'data': [
                    {'id': 'custom-model'}
                  ]
                };
              }
              if (config.structured) {
                jsonProbes++;
              }
              return {
                'choices': [
                  {
                    'message': {
                      'role': 'assistant',
                      'content': '{"ok":true}',
                      if ((body!['tools'] as List? ?? []).any(
                          (e) => (e as Map)['function']['name'] == 'ogl_probe'))
                        'tool_calls': [
                          {
                            'id': 'probe',
                            'function': {'name': 'ogl_probe', 'arguments': '{}'}
                          }
                        ]
                    }
                  }
                ]
              };
            });
        const config =
            AiSettings(enabled: true, model: 'custom-model', structured: true);
        await ai.saveSettings(config, key: 'KEY');
        await ai.detectModels();
        require((await ai.cachedModels(config)).single == 'custom-model',
            'Model list not persisted');
        final caps = await ai.detectCapabilities(config);
        require(
            caps['text'] == true &&
                caps['tools'] == true &&
                caps['structured'] == true,
            'Incorrect capability detection');
        require(jsonProbes == 1 && discoveries == 1,
            'Repeated discovery or structured parameters on ordinary probes');
        await ai.send(await ai.newConversation(), 'hello', (_) async => false);
        require(discoveries == 1, 'Chat rediscovered models');
      },
      'Disabled automatic optimization preserves full ordinary history':
          () async {
        final chat = AiConversation(id: '1', accountId: 'alice');
        chat.messages
            .addAll(List.generate(100, (i) => AiMessage('user', 'message $i')));
        require(
            AiContext.history(chat, const AiSettings(optimize: false)).length ==
                100,
            'Optimization ignored the disabled setting');
      },
      'Account tools work without a repository and use current authorization':
          () async {
        var account = 'alice', requests = 0;
        final ai = AiService(
            store: InMemoryKv(),
            vault: InMemoryVault(),
            account: () async => account,
            provider: (_, endpoint, key, body) async => {},
            github: (method, path, body, query) async {
              requests++;
              if (path == '/user') {
                return {'id': account, 'login': account};
              }
              if (path == '/user/repos') {
                return [
                  {
                    'name': 'StarAssistant',
                    'full_name': '$account/StarAssistant',
                    'private': true
                  }
                ];
              }
              return {
                'full_name': '$account/StarAssistant',
                'default_branch': 'main'
              };
            });
        var chat = await ai.newConversation();
        require(
            (await ai.readTool(chat, 'current_user', {}) as Map)['login'] ==
                'alice',
            'Current user');
        final repos =
            await ai.readTool(chat, 'list_my_repositories', {}) as Map;
        require((repos['items'] as List).single['private'] == true,
            'Private repository omitted');
        await ai.switchRepo(chat, 'StarAssistant');
        require(
            chat.repo == 'alice/StarAssistant', 'Short name did not resolve');
        final before = requests;
        await ai.readTool(chat, 'repository_info', {});
        await ai.readTool(chat, 'repository_info', {});
        require(requests == before + 1, 'Repeated metadata read missed cache');
        account = 'bob';
        chat = await ai.newConversation();
        final user = await ai.readTool(chat, 'current_user', {}) as Map;
        require(user['login'] == 'bob', 'Private cache crossed accounts');
        require((await ai.conversations()).every((e) => e.accountId == 'bob'),
            'History crossed accounts');
      },
      'Manual model works without a models endpoint and usage is actual':
          () async {
        var calls = 0;
        final ai = AiService(
            store: InMemoryKv(),
            vault: InMemoryVault(),
            account: () async => 'alice',
            github: (_, path, body, query) async => {},
            provider: (_, endpoint, key, body) async {
              require(endpoint != 'models', 'Unexpected model discovery');
              calls++;
              return {
                'usage': {
                  'prompt_tokens': 20,
                  'completion_tokens': 7,
                  'prompt_tokens_details': {'cached_tokens': 5}
                },
                'choices': [
                  {
                    'message': {'role': 'assistant', 'content': 'ok'}
                  }
                ]
              };
            });
        await ai.saveSettings(
            const AiSettings(
                enabled: true,
                model: 'anything',
                inputPrice: 1,
                outputPrice: 2),
            key: 'KEY');
        final chat = await ai.newConversation();
        await ai.send(chat, 'hello', (_) async => false);
        require(calls == 1, 'Repeated provider call');
        require(
            chat.usage['lastEstimated'] == false, 'Actual usage mislabeled');
        require(
            chat.usage['input'] == 20 &&
                chat.usage['output'] == 7 &&
                chat.usage['cached'] == 5,
            'Incorrect usage');
        await ai.clearConversations();
        require((await ai.usageStats())['input'] == 20,
            'Deleting history deleted cumulative usage');
      },
      'Context keeps goals and recent messages without extra provider calls':
          () async {
        final chat = AiConversation(id: '1', accountId: 'alice');
        chat.messages.add(AiMessage('user', '目标：修复键盘遮挡。禁止改变包名。'));
        for (var i = 0; i < 100; i++) {
          chat.messages.add(AiMessage(i.isEven ? 'user' : 'assistant',
              'message $i ${List.filled(200, 'x').join()}'));
        }
        final messages = AiContext.history(chat,
            const AiSettings(optimization: 'economy', contextTokens: 6000));
        require(messages.first['content'].toString().contains('禁止改变包名'),
            'Lost constraint');
        require(messages.last['content'].toString().contains('99'),
            'Lost newest turn');
        require(messages.length == chat.messages.length && chat.summary.isEmpty,
            'Full history was summarized or truncated');
      },
      'Secret redaction and source preservation are independent of economy mode':
          () async {
        final compressed = AiContext.compress({
          'token': 'private',
          'body': 'github_pat_PRIVATE sk-secretvalue',
          'files': List.generate(100, (i) => {'path': '$i.dart'})
        }, const AiSettings(optimization: 'economy')) as Map;
        require(!compressed.containsKey('token'), 'Token field leaked');
        require(!jsonEncode(compressed).contains('github_pat_'), 'PAT leaked');
        final code = List.filled(1000, '源码').join();
        require(
            AiContext.compress(code, const AiSettings(optimization: 'economy'),
                    source: true) ==
                code,
            'Source silently truncated');
      },
      'Cancellation prevents subsequent tools and writes': () async {
        final cancel = AiCancellation();
        var writes = 0;
        final ai = AiService(
            store: InMemoryKv(),
            vault: InMemoryVault(),
            account: () async => 'alice',
            github: (method, path, body, query) async {
              if (method != 'GET') {
                writes++;
              }
              return {};
            },
            provider: (_, endpoint, key, body) async {
              cancel.cancel();
              return {
                'choices': [
                  {
                    'message': {
                      'tool_calls': [
                        {
                          'id': 'write',
                          'function': {
                            'name': 'propose_files',
                            'arguments': '{}'
                          }
                        }
                      ]
                    }
                  }
                ]
              };
            });
        await ai.saveSettings(const AiSettings(enabled: true, model: 'manual'),
            key: 'KEY');
        await rejects(
            () => ai.send(
                AiConversation(
                    id: '1',
                    accountId: 'alice',
                    repo: 'owner/repo',
                    branch: 'main'),
                '修复 bug',
                (_) async => true,
                cancellation: cancel),
            'cancelled');
        require(writes == 0, 'Write after cancellation');
      },
      'Legacy fixed budgets no longer block provider requests': () async {
        var calls = 0;
        final ai = AiService(
            store: InMemoryKv(),
            vault: InMemoryVault(),
            account: () async => 'alice',
            github: (_, path, body, query) async => {},
            provider: (_, endpoint, key, body) async {
              calls++;
              return {
                'choices': [
                  {
                    'message': {'role': 'assistant', 'content': 'ok'}
                  }
                ]
              };
            });
        await ai.saveSettings(
            const AiSettings(
                enabled: true,
                model: 'manual',
                taskBudget: 1024,
                automaticBudget: false),
            key: 'KEY');
        final chat = await ai.newConversation();
        await ai.send(chat, 'hello', (_) async => false);
        require(calls == 1, 'Legacy budget prevented request');
      },
      'Capability detection fails safely and manual overrides remain available':
          () async {
        var probes = 0;
        final ai = AiService(
            store: InMemoryKv(),
            vault: InMemoryVault(),
            account: () async => 'alice',
            github: (_, path, body, query) async => {},
            provider: (_, endpoint, key, body) async {
              probes++;
              throw const AiException('incompatibleApi');
            });
        const config = AiSettings(enabled: true, model: 'manual');
        await ai.saveSettings(config, key: 'KEY');
        final caps = await ai.detectCapabilities(config);
        require(caps['text'] == false, 'Failed probe marked supported');
        require((await ai.settings()).enabled, 'Probe disabled text chat');
        require(probes == 1, 'Unnecessary probes after text failure');
        require(
            (await ai.capabilities(config))['textError'] == 'incompatibleApi',
            'Probe error not cached');
      },
      'Read-only mode and plain chat expose no write tools': () async {
        final tools =
            AiService.availableTools(const AiSettings(toolMode: 'read'));
        require(!jsonEncode(tools).contains('propose_files'),
            'Write tool in read-only mode');
        require(
            AiService.availableTools(const AiSettings(toolMode: 'chat'))
                .isEmpty,
            'Chat included tools');
      },
      'Legacy conversation fields survive migration without dropping history':
          () async {
        final vault = InMemoryVault();
        final entries = List.generate(
            60,
            (i) => AiConversation(id: '$i', accountId: 'alice').toJson()
              ..remove('summary')
              ..remove('title')
              ..remove('usage'));
        await vault.writeSecret('ai.chats.alice', jsonEncode(entries));
        final ai = AiService(
            store: InMemoryKv(),
            vault: vault,
            account: () async => 'alice',
            github: (_, path, body, query) async => {},
            provider: (_, endpoint, key, body) async => {});
        await ai.newConversation();
        require((await ai.conversations()).length == 61, 'Legacy chats lost');
        await vault.writeSecret('ai.chats.alice', 'damaged original');
        await rejects(() => ai.conversations(), 'historyCorrupt');
        require(await vault.readSecret('ai.chats.alice') == 'damaged original',
            'Corrupt history overwritten');
      },
    };
