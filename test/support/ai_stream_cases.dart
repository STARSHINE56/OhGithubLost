// ignore_for_file: avoid_relative_lib_imports
/// 原生 SSE 的分片、工具参数、终止信号与 usage 回归。
library;

import 'dart:convert';
import '../../lib/base/net/ai_http_transport.dart';
import '../../lib/domain/ai/ai_models.dart';
import '../../lib/domain/ai/ai_provider.dart';
import 'ai_safety_cases.dart' show require;

Map<String, Future<void> Function()> aiStreamCases() => {
      'Missing native usage fields never become actual zero-token billing':
          () async {
        final provider = AiProvider((url, headers, body) async => {
              'candidates': [
                {
                  'content': {
                    'parts': [
                      {'text': 'ok'}
                    ]
                  },
                  'finishReason': 'STOP'
                }
              ],
              'usageMetadata': {'promptTokenCount': 20}
            });
        final response = await provider.request(
            const AiSettings(kind: 'gemini', baseUrl: 'https://example.com'),
            'chat/completions',
            'KEY', {
          'model': 'custom',
          'messages': [
            {'role': 'user', 'content': 'hello'}
          ],
          'max_tokens': 100
        });
        require(response['usage']['completion_tokens'] == null,
            'Missing usage became an actual zero');
        final decoder = AiSseDecoder();
        decoder.add(
            '{"candidates":[{"content":{"parts":[{"text":"ok"}]},"finishReason":"STOP"}]}');
        decoder.add(
            '{"usageMetadata":{"promptTokenCount":20,"candidatesTokenCount":5}}');
        require(decoder.result()['usageMetadata']['candidatesTokenCount'] == 5,
            'Trailing Gemini usage lost');
      },
      'OpenAI fragmented tools and final usage survive SSE': () async {
        final text = <String>[];
        final decoder = AiSseDecoder(onText: text.add);
        decoder.add(jsonEncode({
          'choices': [
            {
              'delta': {
                'content': '中文',
                'tool_calls': [
                  {
                    'index': 0,
                    'id': 'one',
                    'function': {'name': 'read_file', 'arguments': '{"path":'}
                  },
                  {
                    'index': 1,
                    'id': 'two',
                    'function': {'name': 'current_user', 'arguments': '{'}
                  }
                ]
              }
            }
          ]
        }));
        decoder.add(jsonEncode({
          'choices': [
            {
              'delta': {
                'content': '回复',
                'tool_calls': [
                  {
                    'index': 0,
                    'function': {'arguments': '"main.dart"}'}
                  },
                  {
                    'index': 1,
                    'function': {'arguments': '}'}
                  }
                ]
              },
              'finish_reason': 'tool_calls'
            }
          ]
        }));
        decoder.add(jsonEncode({
          'choices': [],
          'usage': {'prompt_tokens': 20, 'completion_tokens': 8}
        }));
        decoder.add('[DONE]');
        final result = decoder.result();
        final message = (result['choices'] as List).first['message'] as Map;
        require(text.last == '中文回复', 'Streamed Chinese text lost');
        final calls = message['tool_calls'] as List;
        require(
            calls.length == 2 && calls.first['id'] == 'one', 'Tool IDs lost');
        require(
            jsonDecode(calls.first['function']['arguments'])['path'] ==
                'main.dart',
            'Tool arguments not assembled');
        require(result['usage']['prompt_tokens'] == 20, 'Trailing usage lost');
      },
      'Incomplete streams cannot dispatch tools': () async {
        final decoder = AiSseDecoder();
        decoder.add(
            '{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"x","function":{"name":"propose_files","arguments":"{}"}}]}}]}');
        try {
          decoder.result();
        } on FormatException catch (e) {
          require(e.message == 'streamInterrupted', 'Wrong interruption error');
          return;
        }
        throw StateError('Unfinished tool stream accepted');
      },
      'Malformed SSE events are rejected': () async {
        for (final raw in ['not json', '{"error":{"message":"private"}}']) {
          var rejected = false;
          try {
            AiSseDecoder().add(raw);
          } catch (_) {
            rejected = true;
          }
          require(rejected, 'Bad SSE event accepted');
        }
      },
      'Anthropic native streaming retains signatures, tools and cached usage':
          () async {
        final text = <String>[];
        final decoder = AiSseDecoder(onText: text.add);
        for (final event in [
          {
            'type': 'message_start',
            'message': {
              'usage': {
                'input_tokens': 10,
                'cache_read_input_tokens': 3,
                'cache_creation_input_tokens': 2
              }
            }
          },
          {
            'type': 'content_block_start',
            'index': 0,
            'content_block': {
              'type': 'thinking',
              'thinking': '',
              'signature': ''
            }
          },
          {
            'type': 'content_block_delta',
            'index': 0,
            'delta': {'type': 'signature_delta', 'signature': 'sig'}
          },
          {
            'type': 'content_block_start',
            'index': 1,
            'content_block': {'type': 'text', 'text': ''}
          },
          {
            'type': 'content_block_delta',
            'index': 1,
            'delta': {'type': 'text_delta', 'text': '中文'}
          },
          {
            'type': 'content_block_start',
            'index': 2,
            'content_block': {
              'type': 'tool_use',
              'id': 'call',
              'name': 'current_user',
              'input': {}
            }
          },
          {
            'type': 'content_block_delta',
            'index': 2,
            'delta': {'type': 'input_json_delta', 'partial_json': '{}'}
          },
          {
            'type': 'message_delta',
            'delta': {'stop_reason': 'tool_use'},
            'usage': {'output_tokens': 4}
          },
          {'type': 'message_stop'}
        ]) {
          decoder.add(jsonEncode(event));
        }
        Map<String, Object?>? sent;
        final provider = AiProvider((url, headers, body) async {
          sent = body;
          return decoder.result();
        });
        final response = await provider.request(
            const AiSettings(
                kind: 'anthropic', baseUrl: 'https://example.com/v1'),
            'chat/completions',
            'test-key',
            {
              'model': 'custom',
              'messages': [
                {'role': 'user', 'content': 'test'}
              ],
              'stream': true,
              'max_tokens': 100
            });
        require(sent?['stream'] == true && !sent!.containsKey('tools'),
            'Unsupported empty tools were sent');
        require(response['_streamed'] == true && text.single == '中文',
            'Native stream not normalized');
        final message = response['choices'][0]['message'];
        require(message['_provider_parts'][0]['signature'] == 'sig',
            'Thinking signature lost');
        require(
            message['tool_calls'][0]['id'] == 'call', 'Native tool ID lost');
        require(response['usage']['prompt_tokens'] == 15,
            'Cached input omitted from totals');
      },
      'Anthropic requires a message_stop event': () async {
        final decoder = AiSseDecoder();
        decoder
            .add('{"type":"message_delta","delta":{"stop_reason":"tool_use"}}');
        try {
          decoder.result();
        } on FormatException {
          return;
        }
        throw StateError('Missing terminal event accepted');
      },
      'Gemini native streaming retains function signatures and reasoning usage':
          () async {
        final decoder = AiSseDecoder();
        decoder.add(jsonEncode({
          'candidates': [
            {
              'content': {
                'parts': [
                  {'text': '中文'}
                ]
              }
            }
          ]
        }));
        decoder.add(jsonEncode({
          'candidates': [
            {
              'content': {
                'parts': [
                  {
                    'functionCall': {'name': 'current_user', 'args': {}},
                    'thoughtSignature': 'sig'
                  }
                ]
              },
              'finishReason': 'STOP'
            }
          ],
          'usageMetadata': {
            'promptTokenCount': 10,
            'candidatesTokenCount': 5,
            'thoughtsTokenCount': 2,
            'cachedContentTokenCount': 3
          }
        }));
        var calledUrl = '';
        final provider = AiProvider((url, headers, body) async {
          calledUrl = url;
          return decoder.result();
        });
        final result = await provider.request(
            const AiSettings(
                kind: 'gemini', baseUrl: 'https://example.com/v1beta'),
            'chat/completions',
            'test-key',
            {
              'model': 'custom',
              'messages': [
                {'role': 'user', 'content': 'test'}
              ],
              'stream': true,
              'max_tokens': 100
            });
        require(calledUrl.endsWith(':streamGenerateContent?alt=sse'),
            'Gemini stream endpoint not selected');
        require(
            result['choices'][0]['message']['_provider_parts'][1]
                    ['thoughtSignature'] ==
                'sig',
            'Function signature lost');
        require(
            result['usage']['completion_tokens'] == 7 &&
                result['_streamed'] == true,
            'Reasoning usage not normalized');
      },
    };
