// ignore_for_file: avoid_relative_lib_imports
/// 与 Flutter CI 共用的纯 Dart 账号、预算、缓存和模型能力回归。
library;

import 'dart:async';
import 'dart:convert';
import '../../lib/domain/ai/ai_context.dart';
import '../../lib/domain/ai/ai_models.dart';
import '../../lib/domain/ai/ai_service.dart';
import '../../lib/kernel/contract/disk_store.dart';
import 'ai_safety_cases.dart' show require, rejects;

Map<String, Future<void> Function()> aiUpgradeCases() => {
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
