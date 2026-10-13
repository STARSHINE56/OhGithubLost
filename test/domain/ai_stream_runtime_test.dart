import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ohgithublost/base/net/ai_sse_decoder.dart';
import 'package:ohgithublost/domain/ai/ai_context_budget.dart';
import 'package:ohgithublost/domain/ai/ai_models.dart';
import 'package:ohgithublost/domain/ai/ai_service.dart';
import 'package:ohgithublost/domain/ai/ai_stream_provider.dart';
import 'package:ohgithublost/kernel/contract/disk_store.dart';

void main() {
  test('SSE handles byte-split UTF8, CRLF, comments and done', () async {
    final raw = utf8.encode(': heartbeat\r\ndata: {"text":"你好"}\r\n\r\ndata: [DONE]\n\n');
    final events = await decodeAiSse(Stream.fromIterable(raw.map((v) => [v]))).toList();
    expect(events.single['text'], '你好');
  });
  test('OpenAI fragments aggregate tool arguments only after completion', () {
    final text = <String>[];
    final merger = AiStreamMerger('openai', text.add);
    merger.add({'choices': [{'delta': {'content': 'Hi', 'tool_calls': [{'index': 0, 'id': 'call', 'function': {'name': 'read', 'arguments': '{"path":'}}]}}]});
    merger.add({'choices': [{'delta': {'content': '!', 'tool_calls': [{'index': 0, 'function': {'arguments': '"a"}'}}]}, 'finish_reason': 'tool_calls'}]});
    final reply = ((merger.finish()['choices'] as List).single as Map)['message'] as Map;
    expect(reply['content'], 'Hi!');
    expect(text, ['Hi', 'Hi!']);
    expect(((reply['tool_calls'] as List).single as Map)['function']['arguments'], '{"path":"a"}');
    final interrupted = AiStreamMerger('openai', (_) {});
    interrupted.add({'choices': [{'delta': {'content': 'partial'}}]});
    expect(interrupted.finish, throwsA(isA<AiException>()));
  });
  test('Anthropic JSON fragments and Gemini signatures are preserved', () {
    final anthropic = AiStreamMerger('anthropic', (_) {});
    anthropic.add({'type': 'content_block_start', 'index': 0, 'content_block': {'type': 'tool_use', 'id': 'call', 'name': 'read', 'input': {}}});
    anthropic.add({'type': 'content_block_delta', 'index': 0, 'delta': {'type': 'input_json_delta', 'partial_json': '{"path":"a"}'}});
    anthropic.add({'type': 'message_delta', 'delta': {'stop_reason': 'tool_use'}});
    anthropic.add({'type': 'message_stop'});
    expect((anthropic.finish()['content'] as List).single['input']['path'], 'a');
    final gemini = AiStreamMerger('gemini', (_) {});
    gemini.add({'candidates': [{'content': {'parts': [{'functionCall': {'name': 'read', 'args': {}}, 'thoughtSignature': 'signature'}]}, 'finishReason': 'STOP'}]});
    expect((gemini.finish()['candidates'] as List).single['content']['parts'][0]['thoughtSignature'], 'signature');
  });
  test('context budget bounds long history and rejects oversized newest user input', () {
    final history = List.generate(20, (_) => AiMessage('user', 'x' * 10000));
    expect(AiContextBudget.history(history).length, 4);
    expect(() => AiContextBudget.history([AiMessage('user', 'x' * 50000)]), throwsA(isA<AiException>()));
  });
  test('cancelling model stream prevents tool execution and cleans busy state', () async {
    final started = Completer<void>();
    var writes = 0;
    final ai = AiService(store: InMemoryKv(), vault: InMemoryVault(),
      github: (_, __, ___, ____) async { writes++; return {}; },
      provider: (_, __, ___, ____) async => {'data': [{'id': 'model'}]},
      streamProvider: (_, __, ___, ____, cancel, onText) async {
        onText('partial'); started.complete();
        final stopped = Completer<void>();
        cancel.add(() => stopped.complete());
        await stopped.future; cancel.check();
        return {};
      }, account: () async => 'alice');
    await ai.saveSettings(const AiSettings(enabled: true), key: 'AI');
    final chat = await ai.newConversation();
    final operation = ai.send(chat, 'hello', (_) async => true);
    final assertion = expectLater(operation, throwsA(isA<AiException>()));
    await started.future;
    expect(ai.canCancel, isTrue);
    ai.cancelRequest();
    await assertion;
    expect(writes, 0);
    expect(ai.canCancel, isFalse);
    expect(chat.messages.length, 1);
  });
}
