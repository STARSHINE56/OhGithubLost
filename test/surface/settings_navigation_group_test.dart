import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ohgithublost/surface/widgets/settings/settings_navigation_group.dart';

void main() {
  for (final scale in <double>[1, 1.5, 2]) {
    testWidgets('settings entries keep equal height at text scale $scale', (tester) async {
      await tester.binding.setSurfaceSize(const Size(360, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      var taps = 0;
      await tester.pumpWidget(MaterialApp(home: MediaQuery(
        data: MediaQueryData(textScaler: TextScaler.linear(scale)),
        child: Scaffold(body: ListView(padding: const EdgeInsets.all(16), children: [
          OgLSettingsNavigationGroup(title: 'Group', children: [
            OgLSettingsNavigationRow(key: const ValueKey('one'), icon: Icons.palette_outlined,
              title: 'Display', onTap: () => taps++),
            OgLSettingsNavigationRow(key: const ValueKey('two'), icon: Icons.auto_awesome_outlined,
              title: 'AI', onTap: () => taps++),
          ]),
        ])),
      )));
      await tester.pumpAndSettle();
      expect(tester.getSize(find.byKey(const ValueKey('one'))).height,
          tester.getSize(find.byKey(const ValueKey('two'))).height);
      expect(tester.getSize(find.byKey(const ValueKey('one'))).height, greaterThanOrEqualTo(64));
      expect(find.byType(Card), findsOneWidget);
      await tester.tap(find.text('AI'));
      expect(taps, 1);
      expect(tester.takeException(), isNull);
    });
  }
}
