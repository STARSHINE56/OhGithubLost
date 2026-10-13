/// 沿用既有三协议请求/响应转换，聚合完整工具参数后才允许业务执行。
library;

import 'dart:convert';

import '../../kernel/contract/ai_stream.dart';
import 'ai_models.dart';
import 'ai_provider.dart';

class AiStreamProvider {
  AiStreamProvider(this.http, this.stream);
  final AiHttpSend http;
  final AiEventStream stream;

  Future<Map<String, dynamic>> request(AiSettings settings, String endpoint,
      String key, Map<String, Object?> body, AiCancellation cancellation,
      void Function(String text) onText) async {
    final provider = AiProvider((url, headers, payload) async {
      if (payload == null) return http(url, headers, payload);
      final merger = AiStreamMerger(settings.kind, onText);
      final target = settings.kind == 'gemini'
          ? url.replaceFirst(':generateContent', ':streamGenerateContent?alt=sse') : url;
      await stream(target, headers, {...payload,
        if (settings.kind != 'gemini') 'stream': true}, cancellation, merger.add);
      cancellation.check();
      try {
        return merger.finish();
      } on FormatException {
        // 工具 arguments 不合法也是响应格式问题，不是用户密钥错误。
        throw const AiException('aiMalformedResponse');
      }
    });
    return provider.request(settings, endpoint, key, body);
  }
}

/// 只增量发布正文；工具参数、Gemini thoughtSignature 等必须聚合后回传。
class AiStreamMerger {
  AiStreamMerger(this.kind, this.onText);
  final String kind;
  final void Function(String) onText;
  final _text = StringBuffer();
  final _calls = <int, Map<String, dynamic>>{};
  final _blocks = <int, Map<String, dynamic>>{};
  final _arguments = <int, StringBuffer>{};
  final _parts = <Map<String, dynamic>>[];
  String? _finish;
  bool _ended = false;
  Map<String, dynamic>? _json;

  void _append(String value) { _text.write(value); onText(_text.toString()); }

  void add(Map<String, dynamic> event) {
    if (event['error'] != null || event['type'] == 'error') throw const AiException('invalidResponse');
    if (kind == 'openai') {
      final choices = event['choices'] as List? ?? [];
      if (choices.isEmpty) return;
      final choice = choices.first as Map;
      if (choice['message'] is Map) { _json = event; _ended = true; return; }
      final delta = choice['delta'] as Map? ?? {};
      if (delta['content'] is String) _append(delta['content'] as String);
      for (final value in delta['tool_calls'] as List? ?? []) {
        final call = value as Map;
        final index = call['index'] as int? ?? 0;
        final saved = _calls.putIfAbsent(index, () => {'id': '', 'type': 'function', 'function': {'name': '', 'arguments': ''}});
        if (call['id'] is String) saved['id'] = '${saved['id']}${call['id']}';
        final fn = saved['function'] as Map;
        final update = call['function'] as Map? ?? {};
        for (final key in ['name', 'arguments']) {
          if (update[key] is String) fn[key] = '${fn[key]}${update[key]}';
        }
      }
      if (choice['finish_reason'] != null) { _finish = '${choice['finish_reason']}'; _ended = true; }
    } else if (kind == 'anthropic') {
      if (event['content'] is List) { _json = event; _ended = true; return; }
      final type = event['type'];
      final index = event['index'] as int? ?? 0;
      if (type == 'content_block_start') {
        final block = Map<String, dynamic>.from(event['content_block'] as Map);
        _blocks[index] = block;
        if (block['type'] == 'text' && block['text'] is String && (block['text'] as String).isNotEmpty) _append(block['text'] as String);
      } else if (type == 'content_block_delta') {
        final delta = event['delta'] as Map;
        final block = _blocks[index];
        if (block == null) throw const AiException('invalidResponse');
        if (delta['type'] == 'text_delta') {
          final text = delta['text'] as String;
          block['text'] = '${block['text'] ?? ''}$text'; _append(text);
        } else if (delta['type'] == 'input_json_delta') {
          _arguments.putIfAbsent(index, StringBuffer.new).write(delta['partial_json']);
        } else if (delta['type'] == 'thinking_delta') {
          block['thinking'] = '${block['thinking'] ?? ''}${delta['thinking']}';
        } else if (delta['type'] == 'signature_delta') {
          block['signature'] = '${block['signature'] ?? ''}${delta['signature']}';
        }
      } else if (type == 'message_delta') {
        _finish = (event['delta'] as Map)['stop_reason'] as String?;
      } else if (type == 'message_stop') { _ended = true; }
    } else {
      final candidates = event['candidates'] as List? ?? [];
      if (candidates.isEmpty) return;
      final candidate = candidates.first as Map;
      for (final item in (candidate['content'] as Map?)?['parts'] as List? ?? []) {
        final part = Map<String, dynamic>.from(item as Map);
        _parts.add(part);
        if (part['text'] is String && part['thought'] != true) _append(part['text'] as String);
      }
      if (candidate['finishReason'] != null) { _finish = '${candidate['finishReason']}'; _ended = true; }
    }
  }

  Map<String, dynamic> finish() {
    if (_json != null) return _json!;
    // 网络中断不能把残缺 tool arguments 当完整请求执行。
    if (!_ended) throw const AiException('responseTruncated');
    if (kind == 'openai') {
      final keys = _calls.keys.toList()..sort();
      for (final key in keys) {
        final fn = _calls[key]!['function'] as Map;
        if (fn['name'] == '' || _calls[key]!['id'] == '' || jsonDecode(fn['arguments'] as String) is! Map) throw const AiException('invalidResponse');
      }
      return {'choices': [{'finish_reason': _finish,
        'message': {'role': 'assistant', 'content': _text.toString(), 'tool_calls': keys.map((k) => _calls[k]).toList()}}]};
    }
    if (kind == 'anthropic') {
      final keys = _blocks.keys.toList()..sort();
      for (final key in _arguments.keys) { _blocks[key]!['input'] = jsonDecode(_arguments[key].toString()); }
      return {'content': keys.map((k) => _blocks[k]).toList(), 'stop_reason': _finish};
    }
    return {'candidates': [{'content': {'parts': _parts}, 'finishReason': _finish}]};
  }
}
