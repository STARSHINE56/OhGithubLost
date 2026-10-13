/// 保守字符预算，不伪装为模型 tokenizer 精确 Token 数。
library;

import 'ai_models.dart';

abstract final class AiContextBudget {
  static const inputChars = 48000;
  static List<Map<String, Object?>> history(List<AiMessage> messages,
      {int maxChars = inputChars}) {
    final result = <Map<String, Object?>>[];
    var used = 0;
    for (final message in messages.reversed) {
      if (message.notice || !['user', 'assistant'].contains(message.role)) continue;
      if (message.content.length > maxChars && result.isEmpty) {
        throw const AiException('contextTooLarge');
      }
      if (used + message.content.length > maxChars) break;
      result.insert(0, {'role': message.role, 'content': message.content});
      used += message.content.length;
    }
    return result;
  }
  static void check(List<Map<String, Object?>> messages) {
    final length = messages.fold<int>(0, (sum, m) => sum + '${m['content'] ?? ''}'.length);
    if (length > inputChars + 12000) throw const AiException('contextTooLarge');
  }
}
