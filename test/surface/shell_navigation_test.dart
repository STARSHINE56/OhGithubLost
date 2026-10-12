import 'package:flutter_test/flutter_test.dart';
import 'package:ohgithublost/surface/app/client_shell.dart';

void main() {
  test('AI-enabled navigation retains all four destinations', () {
    expect(ogLVisibleShellTabs(hasAi: true), OgLShellTab.values);
  });

  test('without AI the third destination is profile, not AI', () {
    final tabs = ogLVisibleShellTabs(hasAi: false);
    expect(tabs, <OgLShellTab>[
      OgLShellTab.home,
      OgLShellTab.search,
      OgLShellTab.profile,
    ]);
    expect(tabs[2], OgLShellTab.profile);
    expect(tabs.indexOf(OgLShellTab.profile), 2);
    expect(tabs, isNot(contains(OgLShellTab.ai)));
  });

  test('every visible destination round-trips through its navigation index', () {
    for (final hasAi in <bool>[false, true]) {
      final tabs = ogLVisibleShellTabs(hasAi: hasAi);
      expect(tabs.toSet().length, tabs.length);
      for (final tab in tabs) {
        final index = tabs.indexOf(tab);
        expect(index, inInclusiveRange(0, tabs.length - 1));
        expect(tabs[index], tab);
      }
    }
  });
}
