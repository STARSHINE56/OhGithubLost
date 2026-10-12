import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ohgithublost/surface/pages/settings_section_page.dart';
import 'package:ohgithublost/surface/settings.dart';

void main() {
  testWidgets('settings section rebuilds on setting changes and shared collapse state', (tester) async {
    final groups = ValueNotifier<Set<String>>({});
    final counter = ValueNotifier<int>(1);
    await tester.pumpWidget(MaterialApp(home: SettingsSectionPage(
      title: 'Settings', collapseState: groups, settingsChanges: counter,
      builders: [() => Text('value=${counter.value};open=${groups.value.contains('code')}')],
    )));
    expect(find.text('value=1;open=false'), findsOneWidget);
    counter.value = 2;
    await tester.pump();
    expect(find.text('value=2;open=false'), findsOneWidget);
    groups.value = {'code'};
    await tester.pump();
    expect(find.text('value=2;open=true'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    groups.dispose();
    counter.dispose();
  });

  test('download concurrency accepts upstream 16 and 32 without dropping smaller choices', () {
    expect(OgLSettings.downloadConnectionChoices, [1, 2, 4, 8, 16, 32]);
  });
}
