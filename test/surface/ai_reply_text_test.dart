/// 与离线入口共享实际反馈的展示回归。
library;

import 'package:flutter_test/flutter_test.dart';
import '../support/ai_reply_cases.dart';

void main() {
  for (final entry in aiReplyCases().entries) {
    test(entry.key, entry.value);
  }
}
