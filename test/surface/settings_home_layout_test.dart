import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ohgithublost/surface/i18n/og_l_i18n.dart';
import 'package:ohgithublost/surface/pages/settings_page.dart';
import 'package:ohgithublost/surface/widgets/settings/settings_navigation_group.dart';

import 'ai_lifecycle_test.dart' as fixture;

void main() {
  testWidgets('settings home has three consistent groups without long AI privacy text', (tester) async {
    final fragments = <String, Map<String, String>>{};
    for (final file in Directory('assets/i18n/zh').listSync().whereType<File>()) {
      if (!file.path.endsWith('.json')) continue;
      final data = jsonDecode(file.readAsStringSync()) as Map;
      final name = file.uri.pathSegments.last.replaceAll('.json', '');
      fragments[name] = {for (final e in data.entries) '${e.key}': '${e.value}'};
    }
    OgLI18n.instance.debugInject('zh', fragments);
    final surface = await fixture.bridge(fixture.DelayedAi());
    await tester.binding.setSurfaceSize(const Size(390, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final capture = GlobalKey();
    await tester.pumpWidget(MaterialApp(home: RepaintBoundary(key: capture,
      child: SettingsPage(surface: surface))));
    await tester.pumpAndSettle();
    expect(find.byType(OgLSettingsNavigationGroup), findsNWidgets(3));
    expect(find.byType(OgLSettingsNavigationRow), findsNWidgets(7));
    expect(find.text(fragments['ai']!['privacy']!), findsNothing);
    final heights = tester.widgetList<OgLSettingsNavigationRow>(find.byType(OgLSettingsNavigationRow))
        .map((row) => tester.getSize(find.byWidget(row)).height).toSet();
    expect(heights.length, 1);
    expect(tester.takeException(), isNull);
    if (Platform.environment['OGL_SCREENSHOTS'] == '1') {
      final boundary = capture.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 2);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      await tester.runAsync(() async {
        final file = File('build/ui_shots/settings__grouped.png');
        await file.parent.create(recursive: true);
        await file.writeAsBytes(data!.buffer.asUint8List());
      });
      image.dispose();
    }
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
