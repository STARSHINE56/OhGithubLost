/// 零额外模型请求的上下文预算、工具压缩、敏感字段移除与统计。
library;

import 'dart:convert';

import 'ai_models.dart';

class AiContext {
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
              ? 6000
              : c.optimization == 'quality'
                  ? 64000
                  : 16000,
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
    final incoming = actual ? (usage!['prompt_tokens'] as num).toInt() : input;
    final outgoing = actual
        ? (usage!['completion_tokens'] as num).toInt()
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
