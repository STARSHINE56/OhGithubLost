/// SSE 增量行解析，支持 CRLF、多行 data、注释与结束标记。
library;

import 'dart:convert';

Stream<Map<String, dynamic>> decodeAiSse(Stream<List<int>> bytes) async* {
  final data = <String>[];
  await for (final line in bytes.transform(utf8.decoder).transform(const LineSplitter())) {
    if (line.isEmpty) {
      if (data.isNotEmpty) {
        final payload = data.join('\n');
        data.clear();
        if (payload == '[DONE]') return;
        final decoded = jsonDecode(payload);
        if (decoded is! Map) throw const FormatException('Invalid SSE event');
        yield Map<String, dynamic>.from(decoded);
      }
    } else if (line.startsWith('data:')) {
      var value = line.substring(5);
      if (value.startsWith(' ')) value = value.substring(1);
      data.add(value);
    }
  }
  if (data.isNotEmpty && data.join('\n') != '[DONE]') {
    final decoded = jsonDecode(data.join('\n'));
    if (decoded is! Map) throw const FormatException('Invalid SSE event');
    yield Map<String, dynamic>.from(decoded);
  }
}
