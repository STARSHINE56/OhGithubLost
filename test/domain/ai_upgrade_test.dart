/// 云端与离线使用相同回归用例。
library;

import 'package:flutter_test/flutter_test.dart';
import '../support/ai_upgrade_cases.dart';
import '../support/ai_stream_cases.dart';

void main() {
  for (final entry in {...aiUpgradeCases(), ...aiStreamCases()}.entries) {
    test(entry.key, entry.value);
  }
}
