/// AI 独立传输：不经 GitHub 镜像，不允许携带密钥的请求重定向。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../kernel/contract/ai_stream.dart';
import 'ai_sse_decoder.dart';

/// 每次请求独立关闭连接；错误只含状态码，禁止响应体和密钥进入日志。
class AiHttpTransport {
  Future<void> stream(String url, Map<String, String> headers,
      Map<String, Object?> body, AiCancellation cancellation,
      void Function(Map<String, dynamic>) onEvent) async {
    final uri = Uri.parse(url);
    if (uri.scheme != 'https' || uri.userInfo.isNotEmpty || uri.host.isEmpty) {
      throw const FormatException('HTTPS API endpoint required');
    }
    cancellation.check();
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 20);
    void abort() => client.close(force: true);
    cancellation.add(abort);
    try {
      await (() async {
        final request = await client.postUrl(uri);
        request.followRedirects = false;
        request.persistentConnection = false;
        headers.forEach(request.headers.set);
        request.headers.contentType = ContentType.json;
        request.headers.set('accept', 'text/event-stream');
        request.add(utf8.encode(jsonEncode(body)));
        final response = await request.close();
        if (response.statusCode < 200 || response.statusCode >= 300) {
          throw AiTransportFailure('aiHttpFailure', statusCode: response.statusCode);
        }
        var size = 0;
        final bounded = response.map((chunk) {
          size += chunk.length;
          cancellation.check();
          if (size > 4000000) throw const AiTransportFailure('aiResponseTooLarge');
          return chunk;
        });
        if (response.headers.contentType?.mimeType == 'application/json') {
          final raw = await bounded.transform(utf8.decoder).join();
          onEvent(Map<String, dynamic>.from(jsonDecode(raw) as Map));
        } else {
          await for (final event in decodeAiSse(bounded).timeout(const Duration(seconds: 60))) {
            cancellation.check();
            onEvent(event);
          }
        }
      })().timeout(const Duration(seconds: 180));
      cancellation.check();
    } catch (error) {
      if (cancellation.isCancelled) throw const AiRequestCancelled();
      if (error is TimeoutException) throw const AiTransportFailure('aiTimeout');
      if (error is HandshakeException) throw const AiTransportFailure('aiTlsFailure');
      if (error is SocketException) throw const AiTransportFailure('aiNetworkFailure');
      if (error is FormatException) throw const AiTransportFailure('aiMalformedResponse');
      rethrow;
    } finally {
      cancellation.remove(abort);
      client.close(force: true);
    }
  }

  Future<Map<String, dynamic>> send(
    String url,
    Map<String, String> headers,
    Map<String, Object?>? body, {
    AiCancellation? cancellation,
  }) async {
    final uri = Uri.parse(url);
    if (uri.scheme != 'https' || uri.userInfo.isNotEmpty || uri.host.isEmpty) {
      throw const FormatException('HTTPS API endpoint required');
    }
    cancellation?.check();
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 20);
    void abort() => client.close(force: true);
    cancellation?.add(abort);
    try {
      return await (() async {
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
          throw AiTransportFailure('aiHttpFailure', statusCode: response.statusCode);
        }
        final bytes = <int>[];
        await for (final chunk in response) {
          bytes.addAll(chunk);
          if (bytes.length > 4000000) {
            throw const AiTransportFailure('aiResponseTooLarge');
          }
        }
        return Map<String, dynamic>.from(jsonDecode(utf8.decode(bytes)) as Map);
      })().timeout(const Duration(seconds: 180));
    } catch (error) {
      if (cancellation?.isCancelled == true) throw const AiRequestCancelled();
      if (error is TimeoutException) throw const AiTransportFailure('aiTimeout');
      if (error is HandshakeException) throw const AiTransportFailure('aiTlsFailure');
      if (error is SocketException) throw const AiTransportFailure('aiNetworkFailure');
      if (error is FormatException) throw const AiTransportFailure('aiMalformedResponse');
      rethrow;
    } finally {
      cancellation?.remove(abort);
      client.close(force: true);
    }
  }
}
