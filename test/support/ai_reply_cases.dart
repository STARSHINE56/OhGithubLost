// ignore_for_file: avoid_relative_lib_imports
/// 用户反馈的仓库 JSON 展示回归；仅使用展示层纯文本适配。
library;

import 'dart:convert';
import '../../lib/domain/ai/ai_context.dart';
import '../../lib/surface/util/ai_reply_text.dart';
import 'ai_safety_cases.dart' show require;

Map<String, Future<void> Function()> aiReplyCases() => {
      'Repository JSON is shown as eight readable Markdown links without metadata keys':
          () async {
        final names = [
          'OhGithubLost',
          'StarAssistant',
          'mirror-engine',
          'Docker.DouyinLiveRecorder-webui',
          'XingFanWu',
          'DLSS5-Swapper',
          'Deekseep',
          'fideo-live-record'
        ];
        final payload = {
          'message': '以下是你（STARSHINE56）名下的全部 8 个仓库，均为公开仓库：',
          'repositories': [
            for (final name in names)
              {
                'name': name,
                'full_name': 'STARSHINE56/$name',
                'description': name == 'StarAssistant'
                    ? '星辰助手'
                    : name == 'mirror-engine'
                        ? 'Android ?????? - ???'
                        : '仓库说明',
                'default_branch': 'main',
                'private': false,
                'url': 'https://github.com/STARSHINE56/$name'
              }
          ],
          'total': 8,
          'note': '列表已到末页（无更多仓库）。'
        };
        final text = jsonEncode(payload);
        final display = formatAiReply(text);
        require(
            RegExp(r'^\d+\. ', multiLine: true).allMatches(display).length == 8,
            'Repository rows lost');
        require(
            display.contains(
                '[STARSHINE56/StarAssistant](https://github.com/STARSHINE56/StarAssistant) — 星辰助手'),
            'Links or Chinese description lost');
        require(display.contains('Android ?????? - ???'),
            'Original server description invented');
        require(
            !display.contains('"repositories"') &&
                !display.contains('"default_branch"'),
            'Raw metadata leaked into normal display');
        require(jsonDecode(text)['total'] == 8, 'Original history modified');
      },
      'Explicit JSON requests retain complete structured data in a highlighted code block':
          () async {
        final original = {
          'message': 'ok',
          'repositories': [
            {'full_name': 'owner/private', 'private': true}
          ],
          'total': 1
        };
        final display = formatAiReply(jsonEncode(original), preserveJson: true);
        require(display.startsWith('```json\n') && display.endsWith('\n```'),
            'JSON not fenced for highlighter');
        final decoded = jsonDecode(display.substring(8, display.length - 4));
        require(
            decoded['repositories'][0]['private'] == true &&
                decoded['total'] == 1,
            'Explicit JSON fields omitted');
      },
      'Partial JSON and unrelated JSON are not destructively interpreted as repository data':
          () async {
        for (final text in [
          'ordinary 中文 Markdown',
          '{"repositories":[',
          '{"code":"value","other":123}',
          '{"repositories":[{"full_name":"../../invalid"}]}'
        ]) {
          require(formatAiReply(text) == text,
              'Incomplete or unrelated response altered');
        }
      },
      'Repository metadata cannot inject external images and link targets into normalized lists':
          () async {
        final display = formatAiReply(jsonEncode({
          'repositories': [
            {
              'full_name': 'owner/repo',
              'private': true,
              'url': 'https://external.example/',
              'description':
                  '![image](https://external.example/image) **instruction**'
            }
          ]
        }));
        require(display.contains('[owner/repo](https://github.com/owner/repo)'),
            'Canonical repository link missing');
        require(
            display.contains(r'\!\[image\]') &&
                display.contains(r'\*\*instruction\*\*'),
            'Metadata Markdown not escaped');
        require(display.contains('🔒'), 'Private status omitted');
      },
      'Response-format intent distinguishes JSON requests from JSON debugging and opt-out':
          () async {
        for (final text in [
          '请用 JSON 格式返回所有仓库',
          '返回原始 JSON',
          'Return valid JSON only'
        ]) {
          require(
              AiContext.requestsJson(text), 'Explicit format not recognized');
        }
        for (final text in [
          '列出我的所有仓库',
          '修复 JSON 解析错误，并输出分析',
          '不要用 JSON 格式输出',
          'Do not use JSON'
        ]) {
          require(
              !AiContext.requestsJson(text), 'Ordinary task forced into JSON');
        }
      },
    };
