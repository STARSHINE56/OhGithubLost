// ignore_for_file: avoid_relative_lib_imports
/// 与 Flutter CI 共用的纯 Dart 账号、预算、缓存和模型能力回归。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import '../../lib/domain/ai/ai_context.dart';
import '../../lib/domain/ai/ai_models.dart';
import '../../lib/domain/ai/ai_service.dart';
import '../../lib/kernel/contract/disk_store.dart';
import 'ai_safety_cases.dart' show require, rejects;

Map<String, Future<void> Function()> aiUpgradeCases() => {
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
        final first =
            await ai.readTool(chat, 'read_file', {'path': 'file.dart'}) as Map;
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
        require(chat.summary.contains('禁止改变包名'), 'Lost constraint');
        require(messages.last['content'].toString().contains('99'),
            'Lost newest turn');
        require(AiContext.estimate(jsonEncode(messages)) < 6000,
            'Context exceeded budget');
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
      'Budget stops requests before incurring additional provider usage':
          () async {
        var calls = 0;
        final ai = AiService(
            store: InMemoryKv(),
            vault: InMemoryVault(),
            account: () async => 'alice',
            github: (_, path, body, query) async => {},
            provider: (_, endpoint, key, body) async {
              calls++;
              return {};
            });
        await ai.saveSettings(
            const AiSettings(enabled: true, model: 'manual', taskBudget: 1024),
            key: 'KEY');
        final chat = await ai.newConversation();
        await rejects(
            () => ai.send(chat, 'hello', (_) async => false), 'budgetExceeded');
        require(calls == 0, 'Request exceeded budget');
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
