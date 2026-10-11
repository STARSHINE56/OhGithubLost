/// 真实聊天页、全局焦点守卫、手势导航和字体缩放回归。
library;

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

Future<SurfaceBridge> bridge() async {
  final store = InMemoryKv(), vault = InMemoryVault();
  final auth = GhAuthService(vault: vault, store: store);
  await auth.saveAccount(const GhAccount(id: 'alice', login: 'alice'),
      const GhToken('ghp_fake_test'));
  final client = GhClient(
      net: NetBridge(transport: ScriptedTransport([]), observer: NetObserver()),
      auth: auth);
  final ai = AiService(
      store: store,
      vault: vault,
      account: auth.activeAccountId,
      github: (_, path, body, query) async => {},
      provider: (_, endpoint, key, body) async => {});
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
