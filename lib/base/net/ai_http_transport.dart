/// AI 独立 HTTPS 通道：密钥不走 GitHub/镜像，不跟随重定向。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

class AiHttpTransport {
  Future<Map<String, dynamic>> send(
    String url,
    Map<String, String> headers,
    Map<String, Object?>? body, {
    void Function(String)? onText,
    bool Function()? isCancelled,
    void Function(void Function()?)? bindCancel,
  }) async {
    final uri = Uri.parse(url);
    if (uri.scheme != 'https' || uri.userInfo.isNotEmpty || uri.host.isEmpty) {
      throw const FormatException('invalidEndpoint');
    }
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 20);
    bindCancel?.call(() => client.close(force: true));
    try {
      return await (() async {
        if (isCancelled?.call() == true) {
          throw const FormatException('cancelled');
        }
        final request = await client.openUrl(
          body == null ? 'GET' : 'POST',
          uri,
        );
        request.followRedirects = false;
        request.persistentConnection = false;
        headers.forEach(request.headers.set);
        request.headers.contentType = ContentType.json;
        if (body != null) {
          request.add(utf8.encode(jsonEncode(body)));
        }
        final response = await request.close();
        if (response.statusCode < 200 || response.statusCode >= 300) {
          // 不回显服务端文本（其中可能含凭据或反射的请求体）。
          throw HttpException('AI HTTP ${response.statusCode}');
        }
        if (response.headers.contentType?.mimeType == 'text/event-stream') {
          final decoder = AiSseDecoder(onText: onText);
          final data = <String>[];
          var size = 0;
          void event() {
            if (data.isNotEmpty) {
              decoder.add(data.join('\n'));
              data.clear();
            }
          }

          await for (final line in response
              .transform(utf8.decoder)
              .transform(const LineSplitter())) {
            if (isCancelled?.call() == true) {
              throw const FormatException('cancelled');
            }
            size += line.length;
            if (size > 4000000) {
              throw const FormatException('responseTooLarge');
            }
            if (line.isEmpty) {
              event();
            } else if (line.startsWith('data:')) {
              data.add(line.substring(5).trimLeft());
            }
          }
          event();
          return decoder.result();
        }
        final bytes = <int>[];
        await for (final chunk in response) {
          if (isCancelled?.call() == true) {
            throw const FormatException('cancelled');
          }
          bytes.addAll(chunk);
          if (bytes.length > 4000000) {
            throw const FormatException('responseTooLarge');
          }
        }
        return Map<String, dynamic>.from(jsonDecode(utf8.decode(bytes)) as Map);
      })()
          .timeout(const Duration(seconds: 180));
    } finally {
      bindCancel?.call(null);
      client.close(force: true);
    }
  }
}

/// 三种协议共享 SSE 解码器；只有完整结束事件才允许编排工具。
class AiSseDecoder {
  AiSseDecoder({this.onText});
  final void Function(String)? onText;
  final _content = StringBuffer();
  final _calls = <int, Map<String, dynamic>>{};
  final _blocks = <int, Map<String, dynamic>>{};
  final _parts = <Map<String, dynamic>>[];
  Map<String, dynamic>? _usage;
  String _kind = 'openai', _finish = '';
  bool _done = false;
  void _text(String text) {
    _content.write(text);
    onText?.call(_content.toString());
  }

  void add(String raw) {
    if (raw == '[DONE]') {
      _done = true;
      return;
    }
    final value = jsonDecode(raw) as Map;
    if (value['error'] != null || value['type'] == 'error') {
      throw const FormatException('invalidResponse');
    }
    if (value['type'] is String) {
      _kind = 'anthropic';
      final type = value['type'];
      if (type == 'message_start') {
        _usage = Map<String, dynamic>.from(
            (value['message'] as Map)['usage'] as Map? ?? {});
      }
      if (type == 'content_block_start') {
        final block = Map<String, dynamic>.from(value['content_block'] as Map);
        _blocks[value['index'] as int] = block;
        if (block['type'] == 'text' &&
            (block['text'] as String? ?? '').isNotEmpty) {
          _text(block['text'] as String);
        }
      }
      if (type == 'content_block_delta') {
        final delta = value['delta'] as Map, index = value['index'] as int;
        final block = _blocks[index];
        if (block == null) {
          throw const FormatException('invalidResponse');
        }
        if (delta['type'] == 'text_delta') {
          final text = delta['text'] as String;
          block['text'] = '${block['text'] ?? ''}$text';
          _text(text);
        }
        if (delta['type'] == 'input_json_delta') {
          block['_json'] = '${block['_json'] ?? ''}${delta['partial_json']}';
        }
        if (delta['type'] == 'thinking_delta') {
          block['thinking'] = '${block['thinking'] ?? ''}${delta['thinking']}';
        }
        if (delta['type'] == 'signature_delta') {
          block['signature'] =
              '${block['signature'] ?? ''}${delta['signature']}';
        }
      }
      if (type == 'message_delta') {
        _finish = '${(value['delta'] as Map)['stop_reason'] ?? ''}';
        _usage = {
          ...?_usage,
          ...Map<String, dynamic>.from(value['usage'] as Map? ?? {})
        };
      }
      if (type == 'message_stop') {
        _done = true;
      }
      return;
    }
    if (value['candidates'] is List) {
      _kind = 'gemini';
      if (value['usageMetadata'] is Map) {
        _usage = Map<String, dynamic>.from(value['usageMetadata'] as Map);
      }
      for (final candidate
          in (value['candidates'] as List).take(1).whereType<Map>()) {
        for (final part
            in ((candidate['content'] as Map?)?['parts'] as List? ?? [])
                .whereType<Map>()) {
          _parts.add(Map<String, dynamic>.from(part));
          if (part['text'] is String && part['thought'] != true) {
            _text(part['text'] as String);
          }
        }
        if (candidate['finishReason'] is String) {
          _finish = candidate['finishReason'] as String;
          _done = true;
        }
      }
      return;
    }
    if (value['usage'] is Map) {
      _usage = Map<String, dynamic>.from(value['usage'] as Map);
    }
    final choices = value['choices'] as List? ?? [];
    if (choices.isEmpty) {
      return;
    }
    final choice = choices.first as Map;
    if (choice['finish_reason'] != null) {
      _finish = '${choice['finish_reason']}';
    }
    final delta = choice['delta'] as Map? ?? {};
    if (delta['content'] is String) {
      _text(delta['content'] as String);
    }
    for (final rawCall in delta['tool_calls'] as List? ?? []) {
      final c = rawCall as Map, index = c['index'] as int;
      final saved = _calls.putIfAbsent(
          index,
          () => {
                'id': '',
                'type': 'function',
                'function': <String, dynamic>{'name': '', 'arguments': ''}
              });
      if (c['id'] is String) {
        saved['id'] = c['id'];
      }
      final fn = c['function'] as Map? ?? {}, target = saved['function'] as Map;
      for (final field in ['name', 'arguments']) {
        if (fn[field] is String) {
          target[field] = '${target[field]}${fn[field]}';
        }
      }
    }
  }

  Map<String, dynamic> result() {
    if (!_done && _finish.isEmpty) {
      throw const FormatException('streamInterrupted');
    }
    if (_kind == 'anthropic') {
      if (!_done) {
        throw const FormatException('streamInterrupted');
      }
      for (final block in _blocks.values) {
        final raw = block.remove('_json');
        if (raw != null) {
          block['input'] = jsonDecode(raw as String);
        }
      }
      return {
        '_streamed': true,
        'content': _blocks.values.toList(),
        'stop_reason': _finish,
        if (_usage != null) 'usage': _usage
      };
    }
    if (_kind == 'gemini') {
      return {
        '_streamed': true,
        'candidates': [
          {
            'finishReason': _finish,
            'content': {'parts': _parts}
          }
        ],
        if (_usage != null) 'usageMetadata': _usage
      };
    }
    return {
      '_streamed': true,
      'choices': [
        {
          'finish_reason': _finish,
          'message': {
            'role': 'assistant',
            'content': _content.toString(),
            if (_calls.isNotEmpty) 'tool_calls': _calls.values.toList()
          }
        }
      ],
      if (_usage != null) 'usage': _usage
    };
  }
}
