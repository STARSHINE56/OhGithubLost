/// Markdown 正文及单独代码块复制；复制不改变源消息，不执行代码。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';

import '../pages/ai_settings_page.dart';
import '../util/link_opener.dart';

class AiMessageBody extends StatelessWidget {
  const AiMessageBody({required this.text, super.key});
  final String text;
  @override
  Widget build(BuildContext context) {
    final blocks = RegExp(r'^```([^\n]*)\n([\s\S]*?)^```[ \t]*$', multiLine: true).allMatches(text).toList();
    final children = <Widget>[];
    var offset = 0;
    Widget markdown(String value) => MarkdownBody(data: value, selectable: true,
      onTapLink: (_, href, __) {
        if (href != null && ['https', 'http'].contains(Uri.tryParse(href)?.scheme)) {
          openLinkOrCopy(context, href);
        }
      });
    for (final block in blocks) {
      if (block.start > offset) children.add(markdown(text.substring(offset, block.start)));
      final code = block.group(2)!;
      children.add(Container(margin: const EdgeInsets.symmetric(vertical: 8),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(color: Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [Expanded(child: Text(block.group(1)!.trim())),
            IconButton(tooltip: aiText('copyCode'), icon: const Icon(Icons.copy, size: 18),
              onPressed: () async { await Clipboard.setData(ClipboardData(text: code));
                if (context.mounted) { ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(aiText('messageCopied')))); }
              })]),
          SingleChildScrollView(scrollDirection: Axis.horizontal,
            child: SelectableText(code, style: const TextStyle(fontFamily: 'monospace'))),
        ])));
      offset = block.end;
    }
    if (offset < text.length || children.isEmpty) children.add(markdown(text.substring(offset)));
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children);
  }
}
