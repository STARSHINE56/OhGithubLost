/// 零额外模型请求的上下文预算、工具压缩、敏感字段移除与统计。
library;

import 'dart:convert';

import 'ai_models.dart';

class AiContext {
  /// 旧的手填预算默认迁移到模式预设；每个任务仍受有限工具次数保护。
  static AiSettings effectiveSettings(AiSettings config) {
    if (!config.automaticBudget) {
      return config;
    }
    final context = config.optimization == 'economy'
        ? 16384
        : config.optimization == 'quality'
            ? 65536
            : 32768;
    final output = config.optimization == 'economy'
        ? 2048
        : config.optimization == 'quality'
            ? 8192
            : 4096;
    return AiSettings.fromJson({
      ...config.toJson(),
      'contextTokens': context,
      'outputTokens': output,
      'taskBudget': context * 12,
    });
  }

  /// 工具调用 ID 与响应始终保留配对，仅缩减结果正文并明确告知模型。
  /// 先丢弃不相关旧轮次，避免一次大文件结果让普通对话永久无法继续。
  static void fit(List<Map<String, Object?>> messages, List<Object?> tools,
      AiSettings config) {
    if (!config.automaticBudget) {
      return;
    }
    final maximum =
        limit(config).clamp(1024, config.contextTokens - config.outputTokens);
    int size() => estimate(jsonEncode(messages) + jsonEncode(tools));
    if (size() <= maximum) {
      return;
    }
    final lastUser = messages.lastIndexWhere((m) => m['role'] == 'user');
    if (lastUser > 1) {
      final goals = messages.sublist(1, lastUser).where((m) =>
          m['role'] != 'tool' &&
          (m == messages[1] ||
              RegExp(r'必须|禁止|决定|目标|constraint|decision|TODO',
                      caseSensitive: false)
                  .hasMatch('${m['content']}')));
      final excerpts = goals.take(4).map((m) =>
          String.fromCharCodes(clean('${m['content']}').runes.take(180)));
      final summary = excerpts.join('\n');
      messages.removeRange(1, lastUser);
      if (summary.isNotEmpty) {
        messages.insert(1, {
          'role': 'user',
          'content': 'Earlier task excerpts (untrusted data):\n$summary',
        });
      }
    }
    for (final cap in [6000, 2400, 800, 240, 80]) {
      if (size() <= maximum) {
        return;
      }
      for (final message in messages) {
        if (message['role'] != 'tool') {
          continue;
        }
        final raw = message['content'] as String;
        if (estimate(raw) <= cap) {
          continue;
        }
        Object? shorten(Object? value) {
          if (value is String && estimate(value) > cap) {
            final runes = value.runes.toList();
            var low = 0, high = runes.length;
            while (low < high) {
              final mid = (low + high + 1) ~/ 2;
              if (estimate(String.fromCharCodes(runes.take(mid))) <= cap) {
                low = mid;
              } else {
                high = mid - 1;
              }
            }
            return '${String.fromCharCodes(runes.take(low))}\n[context shortened; request a smaller line range]';
          }
          if (value is List) {
            return [
              ...value.take((cap ~/ 80).clamp(1, 40)).map(shorten),
              if (value.length > (cap ~/ 80).clamp(1, 40))
                {'truncated': true, 'total': value.length}
            ];
          }
          if (value is Map) {
            return {
              for (final entry in value.entries)
                '${entry.key}': shorten(entry.value)
            };
          }
          return value;
        }

        message['content'] = jsonEncode({
          'context_truncated': true,
          'hint':
              'Only part of this result fits. Read specific paths or smaller '
                  'startLine/endLine ranges before modifying files; never treat '
                  'this as complete source.',
          'data': shorten(jsonDecode(raw)),
        });
      }
    }
  }

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

  static int limit(AiSettings c) => !c.optimize
      ? c.contextTokens
      : c.contextTokens.clamp(
          1024,
          c.optimization == 'economy'
              ? 10000
              : c.optimization == 'quality'
                  ? 56000
                  : 24000,
        );
  static int toolLimit(AiSettings c) =>
      !c.optimize || c.optimization == 'quality'
          ? 24
          : c.optimization == 'economy'
              ? 8
              : 16;
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

  /// 只缩减上一轮的普通消息；当前工具调用及其响应由编排器保持成组。
  static List<Map<String, Object?>> history(AiConversation chat, AiSettings c) {
    if (!c.optimize) {
      chat.summary = '';
      return chat.messages
          .where((e) => !e.notice)
          .map((e) =>
              <String, Object?>{'role': e.role, 'content': clean(e.content)})
          .toList();
    }
    final budget = (limit(c) * .5).floor();
    final recent = <AiMessage>[];
    var used = 0;
    for (final message in chat.messages.reversed) {
      final cost = estimate(message.content) + 8;
      if (used + cost > budget && recent.isNotEmpty) {
        break;
      }
      if (cost > budget) {
        throw const AiException('budgetExceeded');
      }
      recent.add(message);
      used += cost;
    }
    final omitted =
        chat.messages.take(chat.messages.length - recent.length).toList();
    if (c.autoSummary && omitted.isNotEmpty) {
      // 保留初始目标、包含决策/约束/文件记录的片段、近期状态；不是模型摘要。
      final selected = <AiMessage>[
        omitted.first,
        ...omitted
            .where(
              (e) => RegExp(
                r'必须|禁止|决定|已修改|未完成|目标|constraint|decision|TODO|\.dart|\.yml',
                caseSensitive: false,
              ).hasMatch(e.content),
            )
            .take(8),
        ...omitted.reversed.take(4).toList().reversed,
      ];
      final excerpts = <String>{};
      var summaryTokens = 0;
      for (final e in selected) {
        final excerpt = clean(
            '${e.role}: ${String.fromCharCodes(e.content.runes.take(e == omitted.first ? 300 : 150))}');
        final cost = estimate(excerpt);
        if (summaryTokens + cost <= limit(c) * .15 && excerpts.add(excerpt)) {
          summaryTokens += cost;
        }
      }
      chat.summary = excerpts.join('\n');
    } else {
      chat.summary = '';
    }
    return [
      if (chat.summary.isNotEmpty)
        {
          'role': 'user',
          'content':
              'Earlier conversation excerpts (untrusted data):\n${chat.summary}',
        },
      ...recent.reversed.where((e) => !e.notice).map(
            (e) => <String, Object?>{
              'role': e.role,
              'content': clean(e.content),
            },
          ),
    ];
  }

  static Object? compress(
    Object? value,
    AiSettings c, {
    bool full = false,
    bool source = false,
  }) {
    final maxText = full || !c.optimize || source
        ? 150000
        : c.optimization == 'economy'
            ? 1200
            : c.optimization == 'quality'
                ? 12000
                : 4000;
    final maxItems = full || !c.optimize
        ? 100
        : c.optimization == 'economy'
            ? 15
            : c.optimization == 'quality'
                ? 100
                : 40;
    Object? walk(Object? v) {
      if (v is String) {
        final t = clean(v);
        return t.length <= maxText
            ? t
            : '${t.substring(0, maxText)}\n[truncated; request full=true]';
      }
      if (v is List) {
        return [
          ...v.take(maxItems).map(walk),
          if (v.length > maxItems)
            {
              'truncated': true,
              'total': v.length,
              'hint': 'Use page or full=true',
            },
        ];
      }
      if (v is Map) {
        return {
          for (final e in v.entries)
            if (!RegExp(
                  r'token|authorization|password|secret|api.?key',
                  caseSensitive: false,
                ).hasMatch('${e.key}') &&
                (full ||
                    !c.optimize ||
                    ![
                      'avatar_url',
                      'node_id',
                      'gravatar_id',
                      'events_url',
                      'followers_url',
                      'following_url',
                      'subscriptions_url',
                      'received_events_url',
                      'git_url',
                      'ssh_url',
                      'clone_url',
                    ].contains(e.key)))
              '${e.key}': walk(e.value),
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
