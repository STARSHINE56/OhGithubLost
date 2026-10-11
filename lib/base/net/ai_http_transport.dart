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
        if (body?['stream'] == true &&
            response.headers.contentType?.mimeType == 'text/event-stream') {
          final content = StringBuffer();
          final calls = <int, Map<String, dynamic>>{};
          Map<String, dynamic>? usage;
          String finish = '';
          var size = 0;
          var completed = false;
          final data = <String>[];
          void event() {
            if (data.isEmpty) {
              return;
            }
            final raw = data.join('\n');
            data.clear();
            if (raw == '[DONE]') {
              completed = true;
              return;
            }
            final value = jsonDecode(raw) as Map;
            if (value['error'] != null) {
              throw const FormatException('invalidResponse');
            }
            if (value['usage'] is Map) {
              usage = Map<String, dynamic>.from(value['usage'] as Map);
            }
            final choices = value['choices'] as List? ?? [];
            if (choices.isEmpty) {
              return;
            }
            final choice = choices.first as Map;
            if (choice['finish_reason'] != null) {
              finish = '${choice['finish_reason']}';
            }
            final delta = choice['delta'] as Map? ?? {};
            final text = delta['content'];
            if (text is String) {
              content.write(text);
              onText?.call(content.toString());
            }
            for (final rawCall in delta['tool_calls'] as List? ?? []) {
              final c = rawCall as Map;
              final index = c['index'] as int;
              final saved = calls.putIfAbsent(
                index,
                () => {
                  'id': '',
                  'type': 'function',
                  'function': <String, dynamic>{'name': '', 'arguments': ''},
                },
              );
              if (c['id'] is String) {
                saved['id'] = c['id'];
              }
              final f = c['function'] as Map? ?? {},
                  target = saved['function'] as Map;
              for (final field in ['name', 'arguments']) {
                if (f[field] is String) {
                  target[field] = '${target[field]}${f[field]}';
                }
              }
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
          if (!completed && finish.isEmpty) {
            throw const FormatException('streamInterrupted');
          }
          return {
            '_streamed': true,
            'choices': [
              {
                'finish_reason': finish,
                'message': {
                  'role': 'assistant',
                  'content': content.toString(),
                  if (calls.isNotEmpty) 'tool_calls': calls.values.toList(),
                },
              },
            ],
            if (usage != null) 'usage': usage,
          };
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
