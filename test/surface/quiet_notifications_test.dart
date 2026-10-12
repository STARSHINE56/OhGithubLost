import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ohgithublost/surface/app/error_surface.dart';
import 'package:ohgithublost/surface/pages/notifications_page.dart';

void main() {
  setUp(() {
    OgLNoticeCenter.instance.debugClear();
    OgLAppLog.instance.clear();
  });

  test('startup notices are retained in logs without a presentation queue', () {
    OgLNoticeCenter.instance.report(
      title: 'Startup warning',
      detail: 'Diagnostic',
    );
    expect(OgLNoticeCenter.instance.pending, isEmpty);
    expect(OgLNoticeCenter.instance.history.single.title, 'Startup warning');
    expect(OgLAppLog.instance.entries.single.message, contains('Diagnostic'));
  });

  test('explicit immediate errors still reach the presentation queue', () {
    OgLNoticeCenter.instance.report(
      title: 'Unexpected error',
      severity: OgLNoticeSeverity.critical,
      delivery: OgLNoticeDelivery.inAppOnly,
    );
    expect(OgLNoticeCenter.instance.pending.single.title, 'Unexpected error');
  });

  testWidgets('embedded logs have no nested app bar and can mark all read', (
    tester,
  ) async {
    OgLAppLog.instance.add('Startup', 'Diagnostic');
    await tester.pumpWidget(
      const MaterialApp(home: NotificationsPage(embedded: true)),
    );
    await tester.pumpAndSettle();
    expect(find.byType(AppBar), findsNothing);
    await tester.tap(find.byIcon(Icons.done_all));
    await tester.pumpAndSettle();
    expect(
      OgLAppLog.instance.isRead(OgLAppLog.instance.entries.single),
      isTrue,
    );
  });
}
