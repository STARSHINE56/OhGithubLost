import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ohgithublost/surface/app/keyboard_guard.dart';

void main() {
  testWidgets('focused text input retains keyboard inset and stays above keyboard', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetViewInsets);
    double? inset;
    await tester.pumpWidget(MaterialApp(builder: (_, child) => OgLKeyboardGuard(child: child!),
      home: Scaffold(body: Builder(builder: (context) {
        inset = MediaQuery.viewInsetsOf(context).bottom;
        return const Column(children: [Expanded(child: SizedBox()),
          Padding(padding: EdgeInsets.all(16), child: TextField(key: ValueKey('input')))]);
      }))));
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
