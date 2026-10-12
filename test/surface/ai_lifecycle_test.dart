import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ohgithublost/base/net/net_bridge.dart';
import 'package:ohgithublost/base/net/net_transport.dart';
import 'package:ohgithublost/domain/ai/ai_service.dart';
import 'package:ohgithublost/domain/domain_bridge.dart';
import 'package:ohgithublost/domain/gh/gh_api.dart';
import 'package:ohgithublost/domain/gh/gh_auth.dart';
import 'package:ohgithublost/domain/gh/gh_client.dart';
import 'package:ohgithublost/domain/ix/ix_notify.dart';
import 'package:ohgithublost/domain/ix/ix_session.dart';
import 'package:ohgithublost/domain/ix/ix_task.dart';
import 'package:ohgithublost/domain/sys/sys_access.dart';
import 'package:ohgithublost/domain/sys/sys_info.dart';
import 'package:ohgithublost/kernel/contract/disk_store.dart';
import 'package:ohgithublost/surface/pages/ai_settings_page.dart';
import 'package:ohgithublost/surface/settings.dart';
import 'package:ohgithublost/surface/surface_bridge.dart';
import 'package:ohgithublost/surface/types.dart';

class DelayedAi extends AiService {
  DelayedAi() : super(store: InMemoryKv(), vault: InMemoryVault(),
    github: (_, __, ___, ____) async => {},
    provider: (_, __, ___, ____) async => {}, account: () async => 'alice');
  final saved = Completer<void>();
  @override
  Future<void> saveSettings(AiSettings value, {String? key, bool clearKey = false}) => saved.future;
}

Future<SurfaceBridge> bridge(DelayedAi ai) async {
  final kv = InMemoryKv();
  final auth = GhAuthService(vault: InMemoryVault(), store: kv);
  final client = GhClient(net: NetBridge(transport: ScriptedTransport([]),
    observer: NetObserver()), auth: auth);
  final settings = OgLSettingsController(persistence: OgLInMemorySettingsPersistence());
  await settings.load();
  return SurfaceBridge(settings: settings, domain: DomainBridge(
    auth: auth, client: client, api: GhApi(client: client),
    session: IxSession(auth: auth, store: kv), tasks: IxTaskRunner(),
    notifications: IxNotificationCenter(), sysInfo: SysInfoService(),
    sysAccess: SysAccessGuard(store: kv), ai: ai));
}

void main() {
  testWidgets('saving settings then closing page never uses disposed controllers', (tester) async {
    final ai = DelayedAi();
    final surface = await bridge(ai);
    await tester.pumpWidget(MaterialApp(home: AiSettingsPage(surface: surface)));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byIcon(Icons.save_outlined));
    await tester.tap(find.byIcon(Icons.save_outlined));
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
    ai.saved.complete();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
