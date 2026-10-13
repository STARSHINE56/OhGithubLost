import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ohgithublost/surface/pages/ai_context_picker.dart';

import 'ai_lifecycle_test.dart' as fixture;

class PickerAi extends fixture.DelayedAi {
  @override
  Future<List<Map<String, dynamic>>> contextRepositories({int page = 1}) async => [
    {'full_name': 'alice/repo'}, {'full_name': 'alice/other'}];
  @override
  Future<List<String>> contextBranches(String repo, {int page = 1}) async => ['main', 'feature/test'];
}

void main() {
  testWidgets('picker loads repositories then returns explicitly chosen branch', (tester) async {
    final surface = await fixture.bridge(PickerAi());
    AiContextChoice? selected;
    await tester.pumpWidget(MaterialApp(home: Builder(builder: (context) => Scaffold(
      body: TextButton(onPressed: () async {
        selected = await showDialog<AiContextChoice>(context: context,
          builder: (_) => AiContextPicker(surface: surface));
      }, child: const Text('Open'))))));
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('alice/repo'));
    await tester.pumpAndSettle();
    expect(find.text('feature/test'), findsOneWidget);
    await tester.tap(find.text('feature/test'));
    await tester.pumpAndSettle();
    expect(selected?.repo, 'alice/repo');
    expect(selected?.branch, 'feature/test');
    expect(tester.takeException(), isNull);
  });
}
