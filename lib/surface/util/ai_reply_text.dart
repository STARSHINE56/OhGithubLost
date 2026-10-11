/// 仅规范展示；保留原始历史与工具 JSON，不增加模型请求。
library;

import 'dart:convert';

String formatAiReply(String content, {bool preserveJson = false}) {
  var raw = content.trim();
  if (raw.startsWith('```json\n') && raw.endsWith('```')) {
    raw = raw.substring(8, raw.length - 3).trim();
  }
  if (!(raw.startsWith('{') && raw.endsWith('}')) &&
      !(raw.startsWith('[') && raw.endsWith(']'))) {
    return content;
  }
  Object? value;
  try {
    value = jsonDecode(raw);
  } on FormatException {
    return content;
  }
  if (preserveJson) {
    return '```json\n${const JsonEncoder.withIndent('  ').convert(value)}\n```';
  }
  final root = value is Map ? value : null;
  final rows = value is List
      ? value
      : root?['repositories'] ?? root?['repos'] ?? root?['items'];
  if (rows is! List || (rows.isEmpty && root?['message'] is! String)) {
    return content;
  }
  final names = <String>[];
  for (final row in rows) {
    if (row is! Map ||
        row['full_name'] is! String ||
        !RegExp(r'^[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9_.-]+$')
            .hasMatch(row['full_name'] as String) ||
        ['.', '..'].contains((row['full_name'] as String).split('/').last)) {
      return content;
    }
    names.add(row['full_name'] as String);
  }
  String escape(String text) =>
      text.replaceAll(RegExp(r'[\r\n]+'), ' ').replaceAllMapped(
          RegExp(r'[\\`*_{}\[\]<>#+.!|]'), (match) => '\\${match[0]}');
  final output = <String>[];
  if (root?['message'] is String &&
      (root!['message'] as String).trim().isNotEmpty) {
    output.add(escape(root['message'] as String));
  }
  final list = <String>[];
  for (var i = 0; i < names.length; i++) {
    final row = rows[i] as Map, name = names[i];
    final parts = name.split('/');
    final url =
        'https://github.com/${Uri.encodeComponent(parts[0])}/${Uri.encodeComponent(parts[1])}';
    final description = row['description'] is String
        ? escape(row['description'] as String).trim()
        : '';
    list.add(
        '${i + 1}. ${row['private'] == true ? '🔒 ' : ''}[${escape(name)}]($url)${description.isEmpty ? '' : ' — $description'}');
  }
  if (list.isNotEmpty) {
    output.add(list.join('\n'));
  }
  if (root?['note'] is String && (root!['note'] as String).trim().isNotEmpty) {
    output.add(escape(root['note'] as String));
  }
  return output.join('\n\n');
}
