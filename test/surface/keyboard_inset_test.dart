import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ohgithublost/surface/app/keyboard_guard.dart';
import 'package:ohgithublost/surface/pages/ai_chat_page.dart';
import 'package:ohgithublost/surface/types.dart';

import 'ai_lifecycle_test.dart' as fixture;

void main() {
  testWidgets('actual AI composer stays visible in nested scaffold when keyboard opens', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetViewInsets);
    final surface = await fixture.bridge(fixture.DelayedAi());
    await surface.domain.auth.saveAccount(const GhAccount(id: 'alice', login: 'alice'), const GhToken('ghp_test_only'));
    await surface.domain.auth.switchTo('alice');
    await tester.pumpWidget(MaterialApp(builder: (_, child) => OgLKeyboardGuard(child: child!),
      home: Scaffold(body: AiChatPage(surface: surface),
        bottomNavigationBar: const SizedBox(height: 80))));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(TextField));
    await tester.pump();
    tester.view.viewInsets = FakeViewPadding(bottom: 300);
    await tester.pumpAndSettle();
    expect(tester.getRect(find.byType(TextField)).bottom, lessThanOrEqualTo(544));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('focused text input retains keyboard inset and stays above keyboard', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetViewInsets);
    double? inset;
    await tester.pumpWidget(MaterialApp(builder: (_, child) => OgLKeyboardGuard(child: child!),
      home: Builder(builder: (context) {
        // Scaffold 消耗 inset 后会传 0 给 body；采样必须在 Scaffold 之上。
        inset = MediaQuery.viewInsetsOf(context).bottom;
        return const Scaffold(body: Column(children: [Expanded(child: SizedBox()),
          Padding(padding: EdgeInsets.all(16), child: TextField(key: ValueKey('input')))]));
      })));
    await tester.tap(find.byType(TextField));
    await tester.pump();
    tester.view.viewInsets = FakeViewPadding(bottom: 300);
    await tester.pumpAndSettle();
    expect(inset, 300);
    final rect = tester.getRect(find.byKey(const ValueKey('input')));
    expect(rect.bottom, lessThanOrEqualTo(844 - 300));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets('keyboard ghost inset without text focus is still ignored', (tester) async {
    tester.view.viewInsets = FakeViewPadding(bottom: 300);
    addTearDown(tester.view.resetViewInsets);
    double? inset;
    await tester.pumpWidget(MaterialApp(builder: (_, child) => OgLKeyboardGuard(child: child!),
      home: Builder(builder: (context) {
        inset = MediaQuery.viewInsetsOf(context).bottom;
        return const SizedBox();
      })));
    await tester.pump();
    expect(inset, 0);
  });
}
