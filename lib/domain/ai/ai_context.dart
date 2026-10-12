/// 聊天消息、敏感字段移除与服务商 usage 统计。
library;

import 'dart:convert';

import 'ai_models.dart';

class AiContext {
  /// JSON 能力是可用参数，普通聊天不应因此被强制成 JSON。
  static bool requestsJson(String task) {
    if (RegExp(
            r'''(?:不要|不用|别|避免|无需|禁止)\s*(?:以|用|输出|返回)?\s*(?:纯|原始)?\s*JSON\b|\b(?:do not|don't|no|avoid|without)\s+(?:(?:use|return|output|respond|in|as)\s+)*JSON\b''',
            caseSensitive: false)
        .hasMatch(task)) {
      return false;
    }
    return RegExp(
            r'(?:以|用|按(?:照)?)\s*(?:纯|原始|有效|标准)?\s*JSON(?:\s*(?:格式|形式|来?(?:输出|回答|回复|返回|列出))|\s*$)|(?:输出|返回|回答|回复)\s*(?:为|成)?\s*(?:纯|原始|有效|一个)?\s*JSON\b|\b(?:return|output|respond|reply|format|provide)\s+(?:(?:only|a|valid|raw|in|as)\s+)*JSON\b|\bas\s+(?:(?:valid|raw)\s+)?JSON\b|\bJSON\s+only\b',
            caseSensitive: false)
        .hasMatch(task);
  }

  static int estimate(String value) {
    var latin = 0, other = 0;
    for (final rune in value.runes) {
      if (rune <= 127) {
        latin++;
      } else {
        other++;
      }
    }
    return (latin / 4).ceil() + other;
  }

  static String clean(String text) => text
      .replaceAll(
        RegExp(r'(?:github_pat_|gh[pousr]_)[A-Za-z0-9_]+'),
        '[REDACTED]',
      )
      .replaceAll(RegExp(r'\bsk-[A-Za-z0-9_-]{8,}'), '[REDACTED]')
      .replaceAll(
        RegExp(r'Bearer\s+[^\s"\x27]+', caseSensitive: false),
        'Bearer [REDACTED]',
      );

  /// 保留全部普通聊天消息，不进行自动摘要或 Token 裁剪。
  static List<Map<String, Object?>> history(AiConversation chat, AiSettings c) {
    chat.summary = '';
    return chat.messages
        .where((e) => !e.notice)
        .map((e) =>
            <String, Object?>{'role': e.role, 'content': clean(e.content)})
        .toList();
  }

  /// 仅移除敏感字段；保留完整正文、数组和普通字段。
  static Object? compress(Object? value, AiSettings c,
      {bool full = false, bool source = false}) {
    Object? walk(Object? v) {
      if (v is String) return clean(v);
      if (v is List) return v.map(walk).toList();
      if (v is Map) {
        return {
          for (final entry in v.entries)
            if (!RegExp(r'token|authorization|password|secret|api.?key',
                    caseSensitive: false)
                .hasMatch('${entry.key}'))
              '${entry.key}': walk(entry.value)
        };
      }
      return v;
    }

    return walk(value);
  }

  static void usage(
    AiConversation chat,
    Map<String, dynamic> response,
    int input,
    AiSettings config,
  ) {
    final usage = response['usage'] as Map?;
    final actual = usage?['prompt_tokens'] is num &&
        usage?['completion_tokens'] is num &&
        (usage!['prompt_tokens'] as num) >= 0 &&
        (usage['completion_tokens'] as num) >= 0;
    final incoming = actual ? (usage['prompt_tokens'] as num).toInt() : input;
    final outgoing = actual
        ? (usage['completion_tokens'] as num).toInt()
        : estimate(jsonEncode(response['choices']));
    final cached =
        (usage?['prompt_tokens_details'] as Map?)?['cached_tokens'] as num? ??
            0;
    final u = chat.usage;
    u['lastInput'] = incoming;
    u['lastOutput'] = outgoing;
    u['lastCached'] = cached;
    u['lastEstimated'] = !actual;
    u['input'] = (u['input'] as num? ?? 0) + incoming;
    u['output'] = (u['output'] as num? ?? 0) + outgoing;
    u['cached'] = (u['cached'] as num? ?? 0) + cached;
    u['estimated'] = u['estimated'] == true || !actual;
    u['cost'] = (u['cost'] as num? ?? 0) +
        (incoming * config.inputPrice + outgoing * config.outputPrice) /
            1000000;
  }
}
