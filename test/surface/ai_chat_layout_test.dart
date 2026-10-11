/// 真实聊天页、全局焦点守卫、手势导航和字体缩放回归。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ohgithublost/base/net/net_bridge.dart';
import 'package:ohgithublost/base/net/net_transport.dart';
import 'package:ohgithublost/base/net/net_types.dart';
import 'package:ohgithublost/domain/ai/ai_models.dart';
import 'package:ohgithublost/domain/ai/ai_service.dart';
import 'package:ohgithublost/domain/domain_bridge.dart';
import 'package:ohgithublost/domain/gh/gh_api.dart';
import 'package:ohgithublost/domain/gh/gh_auth.dart';
import 'package:ohgithublost/domain/gh/gh_client.dart';
import 'package:ohgithublost/domain/ix/ix_download.dart';
import 'package:ohgithublost/domain/ix/ix_notify.dart';
import 'package:ohgithublost/domain/ix/ix_session.dart';
import 'package:ohgithublost/domain/ix/ix_task.dart';
import 'package:ohgithublost/domain/sys/sys_access.dart';
import 'package:ohgithublost/domain/sys/sys_info.dart';
import 'package:ohgithublost/kernel/contract/disk_store.dart';
import 'package:ohgithublost/surface/app/keyboard_guard.dart';
import 'package:ohgithublost/surface/i18n/og_l_i18n.dart';
import 'package:ohgithublost/surface/pages/ai_chat_page.dart';
import 'package:ohgithublost/surface/pages/ai_confirmation.dart';
import 'package:ohgithublost/surface/pages/ai_settings_page.dart';
import 'package:ohgithublost/surface/settings.dart';
import 'package:ohgithublost/surface/surface_bridge.dart';

/// 布局测试不订阅原生后台下载插件的单订阅全局流。
class _UnusedDownloadBackend implements IxDownloadBackend {
  @override
  Stream<IxDownloadEvent> get events => Stream<IxDownloadEvent>.empty();
  @override
  void dispose() {}
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('Downloads are not used in layout tests');
}

Future<SurfaceBridge> bridge(
    {AiProviderStreamRequest? streamProvider,
    AiProviderRequest? provider}) async {
  final store = InMemoryKv(), vault = InMemoryVault();
  final auth = GhAuthService(vault: vault, store: store);
  await auth.saveAccount(const GhAccount(id: 'alice', login: 'alice'),
      const GhToken('ghp_fake_test'));
  await auth.switchTo('alice');
  final client = GhClient(
      net: NetBridge(transport: ScriptedTransport([]), observer: NetObserver()),
      auth: auth);
  final ai = AiService(
      store: store,
      vault: vault,
      account: auth.activeAccountId,
      github: (_, path, body, query) async => {},
      provider: provider ?? (_, endpoint, key, body) async => {},
      streamProvider: streamProvider);
  final downloads = IxDownloadManager(backend: _UnusedDownloadBackend());
  addTearDown(downloads.dispose);
  final domain = DomainBridge(
      auth: auth,
      client: client,
      api: GhApi(client: client),
      session: IxSession(auth: auth, store: store),
      tasks: IxTaskRunner(),
      notifications: IxNotificationCenter(),
      downloads: downloads,
      sysInfo: SysInfoService(),
      sysAccess: SysAccessGuard(store: store),
      ai: ai);
  final settings =
      OgLSettingsController(persistence: OgLInMemorySettingsPersistence());
  await settings.load();
  return SurfaceBridge(settings: settings, domain: domain);
}

void main() {
  setUp(() {
    final raw =
        jsonDecode(File('assets/i18n/zh/ai.json').readAsStringSync()) as Map;
    OgLI18n.instance.debugInject('zh', {
      'ai': {for (final e in raw.entries) '${e.key}': '${e.value}'}
    });
  });
  for (final scale in [1.0, 1.6]) {
    testWidgets(
        'Chat input lifts with keyboard and keeps draft at font scale $scale',
        (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetViewInsets);
      final surface = await bridge();
      await tester.pumpWidget(MaterialApp(
          builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.linear(scale)),
              child: OgLKeyboardGuard(child: child!)),
          home: AiChatPage(surface: surface)));
      await tester.pumpAndSettle();
      final input = find.byKey(const ValueKey('ai-input'));
      await tester.tap(input);
      await tester.enterText(input, '中文草稿不会丢失');
      await tester.pump();
      final before = tester.getRect(input);
      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      await tester.pumpAndSettle();
      final after = tester.getRect(input);
      expect(after.bottom, lessThanOrEqualTo(544));
      expect(after.top, lessThan(before.top));
      expect(find.text('中文草稿不会丢失'), findsOneWidget);
      expect(tester.takeException(), isNull);
      tester.view.viewInsets = FakeViewPadding.zero;
      await tester.pumpAndSettle();
      expect(tester.getRect(input).bottom, greaterThan(after.bottom));
      expect(tester.takeException(), isNull);
    });
  }
  for (final automatic in [true, false]) {
    testWidgets(
        'Streaming respects user scroll and draft, auto-scroll=$automatic',
        (tester) async {
      final completion = Completer<Map<String, dynamic>>();
      void Function(String)? emit;
      final surface =
          await bridge(streamProvider: (config, key, body, onText, cancel) {
        emit = onText;
        return completion.future;
      });
      await surface.aiSaveSettings(
          AiSettings(
              enabled: true,
              model: 'manual-model',
              tools: false,
              autoScroll: automatic),
          key: 'test-model-key');
      final chat = await surface.aiNewChat();
      for (var i = 0; i < 30; i++) {
        chat.messages.add(AiMessage('user', '历史问题 $i'));
        chat.messages.add(AiMessage('assistant',
            '历史回复 $i\n${List.filled(12, '这是历史正文，用于验证长对话滚动与渲染。').join('\n')}'));
      }
      await surface.aiSaveChat(chat);
      await tester.pumpWidget(MaterialApp(home: AiChatPage(surface: surface)));
      await tester.pumpAndSettle();
      final input = find.byKey(const ValueKey('ai-input'));
      await tester.enterText(input, '继续分析');
      await tester.tap(find.byTooltip(aiText('send')));
      await tester.pump(const Duration(milliseconds: 100));
      expect(emit, isNotNull);
      final list = find.byKey(const ValueKey('ai-message-list'));
      final position = tester
          .state<ScrollableState>(find
              .descendant(of: list, matching: find.byType(Scrollable))
              .first)
          .position;
      final before = position.pixels;
      final chunk =
          List.filled(14, List.filled(8, '中文流式内容。').join()).join('\n');
      emit!(chunk);
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump();
      if (automatic) {
        expect(position.extentAfter, lessThan(1),
            reason:
                'Large chunks should follow the end before the user scrolls');
      } else {
        expect(position.pixels, closeTo(before, 1));
        expect(position.extentAfter, greaterThan(160));
      }
      await tester.drag(list, const Offset(0, 1200));
      await tester.pumpAndSettle();
      expect(position.extentAfter, greaterThan(160));
      final offset = position.pixels;
      final history = find.byWidgetPredicate(
          (widget) => widget is AiMarkdown && widget.text.startsWith('历史回复'));
      final previous = tester.widget<AiMarkdown>(history.first);
      await tester.enterText(input, '下一条草稿保留');
      emit!('$chunk\n后续内容');
      await tester.pump(const Duration(milliseconds: 100));
      expect(position.pixels, closeTo(offset, 1));
      expect(
          identical(tester.widget<AiMarkdown>(history.first), previous), isTrue,
          reason: 'Streaming must not rebuild old message widgets');
      completion.complete({
        'choices': [
          {
            'finish_reason': 'stop',
            'message': {'role': 'assistant', 'content': '$chunk\n后续内容'}
          }
        ],
        'usage': {'prompt_tokens': 100, 'completion_tokens': 100}
      });
      await tester.pumpAndSettle();
      expect(position.pixels, closeTo(offset, 1),
          reason: 'Completion must not force the reader to the bottom');
      expect(tester.widget<TextField>(input).controller!.text, '下一条草稿保留');
      expect(tester.takeException(), isNull);
    });
  }
  for (final explicitJson in [false, true]) {
    testWidgets(
        'Existing repository JSON renders readably and preserves original history, explicit JSON=$explicitJson',
        (tester) async {
      final surface = await bridge();
      final chat = await surface.aiNewChat();
      final raw = jsonEncode({
        'message': '以下是你的仓库：',
        'repositories': [
          {
            'full_name': 'STARSHINE56/OhGithubLost',
            'description': 'GitHub 客户端',
            'private': false
          },
          {
            'full_name': 'STARSHINE56/StarAssistant',
            'description': '星辰助手',
            'private': false
          }
        ],
        'total': 2
      });
      chat.messages.add(
          AiMessage('user', explicitJson ? '请用 JSON 格式返回仓库列表' : '列出我的全部仓库'));
      chat.messages.add(AiMessage('assistant', raw));
      await surface.aiSaveChat(chat);
      await tester.pumpWidget(MaterialApp(home: AiChatPage(surface: surface)));
      await tester.pumpAndSettle();
      final rendered = tester.widget<AiMarkdown>(find.byType(AiMarkdown)).text;
      if (explicitJson) {
        expect(rendered, startsWith('```json\n'));
        expect(rendered, contains('"repositories"'));
      } else {
        expect(
            rendered,
            contains(
                '[STARSHINE56/StarAssistant](https://github.com/STARSHINE56/StarAssistant) — 星辰助手'));
        expect(rendered, isNot(contains('"repositories"')));
      }
      expect(
          (await surface.aiConversations()).single.messages.last.content, raw);
      expect(tester.takeException(), isNull);
    });
  }
  testWidgets(
      'Settings account follows active authentication without a session snapshot',
      (tester) async {
    final surface = await bridge();
    await tester
        .pumpWidget(MaterialApp(home: AiSettingsPage(surface: surface)));
    await tester.pumpAndSettle();
    final account = find.text('alice');
    await tester.scrollUntilVisible(account, 200,
        scrollable: find.byType(Scrollable).first);
    expect(account, findsOneWidget);
    await surface.domain.auth.saveAccount(
        const GhAccount(id: 'bob', login: 'bob'),
        const GhToken('ghp_fake_bob'));
    await surface.domain.auth.switchTo('bob');
    await tester.pumpAndSettle();
    expect(find.text('bob'), findsOneWidget);
    expect(find.text('alice'), findsNothing);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
      'Changing service or model clears displayed detection for the old configuration',
      (tester) async {
    final surface = await bridge(
        provider: (config, endpoint, key, body) async => endpoint == 'models'
            ? {
                'data': [
                  {'id': 'old-model'}
                ]
              }
            : {
                'choices': [
                  {
                    'message': {'role': 'assistant', 'content': '{"ok":true}'}
                  }
                ]
              });
    const config = AiSettings(model: 'old-model');
    await surface.aiSaveSettings(config, key: 'test-model-key');
    await surface.aiDetectModels();
    await surface.aiDetectCapabilities(config);
    await tester
        .pumpWidget(MaterialApp(home: AiSettingsPage(surface: surface)));
    await tester.pumpAndSettle();
    final status = find.textContaining('${aiText('capabilities')}:');
    await tester.scrollUntilVisible(status, 200,
        scrollable: find.byType(Scrollable).first);
    expect(status, findsOneWidget);
    final model = find.widgetWithText(TextField, aiText('model'));
    await tester.scrollUntilVisible(model, -200,
        scrollable: find.byType(Scrollable).first);
    await tester.enterText(model, 'new-model');
    await tester.pump();
    expect(status, findsNothing);
    final url = find.widgetWithText(TextField, aiText('baseUrl'));
    await tester.ensureVisible(url);
    await tester.enterText(url, 'https://new-service.example/v1');
    await tester.pump(const Duration(milliseconds: 800));
    expect(find.text('old-model'), findsNothing);
    expect(tester.takeException(), isNull);
  });
  testWidgets('Desktop history sidebar and manual model settings fit',
      (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final surface = await bridge();
    await tester.pumpWidget(MaterialApp(home: AiChatPage(surface: surface)));
    await tester.pumpAndSettle();
    expect(find.text(aiText('history')), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester
        .pumpWidget(MaterialApp(home: AiSettingsPage(surface: surface)));
    await tester.pumpAndSettle();
    expect(find.text(aiText('manualModel')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets('Token settings need only a mode, without numeric budget entry',
      (tester) async {
    final surface = await bridge();
    await tester
        .pumpWidget(MaterialApp(home: AiSettingsPage(surface: surface)));
    await tester.pumpAndSettle();
    final hint = find.text(aiText('automaticBudgetHint'));
    await tester.scrollUntilVisible(hint, 200,
        scrollable: find.byType(Scrollable).first);
    expect(hint, findsOneWidget);
    for (final name in [
      'contextTokens',
      'taskBudget',
      'outputTokens',
      'inputPrice',
      'outputPrice'
    ]) {
      expect(find.widgetWithText(TextField, aiText(name)), findsNothing);
    }
    expect(tester.takeException(), isNull);
  });
  testWidgets(
      'Leaving settings immediately persists a pending manual model change',
      (tester) async {
    final surface = await bridge();
    await tester.pumpWidget(MaterialApp(
        home: Builder(
            builder: (context) => Scaffold(
                body: TextButton(
                    onPressed: () => Navigator.push(
                        context,
                        MaterialPageRoute<void>(
                            builder: (_) => AiSettingsPage(surface: surface))),
                    child: const Text('settings'))))));
    await tester.tap(find.text('settings'));
    await tester.pumpAndSettle();
    final model = find.widgetWithText(TextField, aiText('model'));
    await tester.ensureVisible(model);
    await tester.enterText(model, 'manual-model');
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect((await surface.aiSettings()).model, 'manual-model');
    expect(tester.takeException(), isNull);
  });
  testWidgets('API key is saved on immediate exit and reused on reopening',
      (tester) async {
    final surface = await bridge();
    await tester.pumpWidget(MaterialApp(
        home: Builder(
            builder: (context) => Scaffold(
                body: TextButton(
                    onPressed: () => Navigator.push(
                        context,
                        MaterialPageRoute<void>(
                            builder: (_) => AiSettingsPage(surface: surface))),
                    child: const Text('settings'))))));
    await tester.tap(find.text('settings'));
    await tester.pumpAndSettle();
    final key = find.widgetWithText(TextField, aiText('apiKey'));
    await tester.ensureVisible(key);
    await tester.enterText(key, 'test-persisted-model-key');
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(await surface.aiHasKey(), true);
    await tester.tap(find.text('settings'));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(key).controller!.text, isEmpty);
    expect(find.text(aiText('keySaved')), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(await surface.aiHasKey(), true);
    expect(tester.takeException(), isNull);
  });
  testWidgets('Key autosave keeps editing intact and isolates provider secrets',
      (tester) async {
    String? usedKey;
    final surface = await bridge(provider: (_, endpoint, key, body) async {
      usedKey = key;
      return {
        'choices': [
          {
            'message': {'role': 'assistant', 'content': 'ok'}
          }
        ]
      };
    });
    const config = AiSettings(enabled: true, model: 'manual', streaming: false);
    await surface.aiSaveSettings(config);
    await tester
        .pumpWidget(MaterialApp(home: AiSettingsPage(surface: surface)));
    await tester.pumpAndSettle();
    final key = find.widgetWithText(TextField, aiText('apiKey'));
    await tester.ensureVisible(key);
    await tester.enterText(key, 'test-first');
    await tester.pump(const Duration(milliseconds: 800));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(key).controller!.text, 'test-first');
    await tester.enterText(key, 'test-first-complete');
    await tester.pump(const Duration(milliseconds: 800));
    await tester.pumpAndSettle();
    final chat = await surface.domain.ai!.newConversation();
    await surface.domain.ai!.send(chat, 'hello', (_) async => false);
    expect(usedKey, 'test-first-complete');
    await tester.enterText(key, '');
    await tester.pump(const Duration(milliseconds: 800));
    await tester.pumpAndSettle();
    expect(await surface.aiHasKey(config: config), true);
    final url = find.widgetWithText(TextField, aiText('baseUrl'));
    await tester.ensureVisible(url);
    await tester.enterText(url, 'https://another-service.example/v1');
    await tester.pump(const Duration(milliseconds: 800));
    await tester.pumpAndSettle();
    expect(await surface.aiHasKey(), false);
    expect(await surface.aiHasKey(config: config), true);
    expect(tester.widget<TextField>(key).controller!.text, isEmpty);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
      'Backgrounding settings flushes a key before its debounce expires',
      (tester) async {
    final surface = await bridge();
    await tester
        .pumpWidget(MaterialApp(home: AiSettingsPage(surface: surface)));
    await tester.pumpAndSettle();
    final key = find.widgetWithText(TextField, aiText('apiKey'));
    await tester.ensureVisible(key);
    await tester.enterText(key, 'test-background-key');
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    await tester.pump();
    expect(await surface.aiHasKey(), true);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
  testWidgets(
      'Landscape keyboard constrains multiline input at large font scale',
      (tester) async {
    tester.view.physicalSize = const Size(844, 390);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetViewInsets);
    final surface = await bridge();
    await tester.pumpWidget(MaterialApp(
        builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(1.6)),
            child: OgLKeyboardGuard(child: child!)),
        home: AiChatPage(
            surface: surface, repo: 'alice/project', branch: 'dev')));
    await tester.pumpAndSettle();
    expect(find.text('alice/project · dev'), findsOneWidget);
    final input = find.byKey(const ValueKey('ai-input'));
    await tester.tap(input);
    await tester.enterText(input, List.filled(10, '中文草稿').join('\n'));
    tester.view.viewInsets = const FakeViewPadding(bottom: 200);
    await tester.pumpAndSettle();
    expect(tester.getRect(input).bottom, lessThanOrEqualTo(190));
    expect(tester.takeException(), isNull);
    final field = tester.widget<TextField>(input);
    expect(field.controller!.text.split('\n').length, 10);
  });
  testWidgets('Deleting files requires a second explicit confirmation',
      (tester) async {
    var accepted = false;
    await tester.pumpWidget(MaterialApp(
        home: Builder(
            builder: (context) => Scaffold(
                body: TextButton(
                    onPressed: () async {
                      accepted = await confirmAiProposal(
                          context,
                          AiProposal(
                              operation: 'commit_files',
                              accountId: 'alice',
                              repo: 'alice/repo',
                              branch: 'main',
                              payload: {},
                              files: const [
                                AiFileChange(
                                    path: 'old.dart',
                                    before: 'old',
                                    after: null)
                              ]));
                    },
                    child: const Text('preview'))))));
    await tester.tap(find.text('preview'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(aiText('confirm')));
    await tester.pumpAndSettle();
    expect(accepted, false);
    expect(find.text(aiText('confirmDeletion')), findsOneWidget);
    await tester.tap(find.text(aiText('cancel')));
    await tester.pumpAndSettle();
    expect(accepted, false);
    expect(tester.takeException(), isNull);
  });
  testWidgets('Chinese Markdown tables and code use the existing renderer',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
            body: SingleChildScrollView(
                child: AiMarkdown(
                    text:
                        '中文正文\n\n|列|值|\n|---|---|\n|中文|测试|\n\n```dart\nfinal value = "中文";\n```')))));
    await tester.pumpAndSettle();
    expect(find.textContaining('中文正文'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
