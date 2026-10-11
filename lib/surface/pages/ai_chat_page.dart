/// AI 聊天：本地历史、仓库上下文、写入确认和真实构建产物按钮。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';

import '../surface_bridge.dart';
import '../types.dart';
import '../util/link_opener.dart';
import '../widgets/code_editor_field.dart';
import 'ai_confirmation.dart';
import 'ai_settings_page.dart';

class AiChatPage extends StatefulWidget {
  const AiChatPage({
    required this.surface,
    this.repo = '',
    this.branch = '',
    super.key,
  });
  final SurfaceBridge surface;
  final String repo;
  final String branch;
  @override
  State<AiChatPage> createState() => _AiChatPageState();
}

class _AiChatPageState extends State<AiChatPage> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  final _focus = FocusNode();
  final _stream = ValueNotifier<String>('');
  final _scaffold = GlobalKey<ScaffoldState>();
  AiSettings _settings = const AiSettings();
  AiCancellation? _cancel;
  Timer? _streamTimer;
  String _pending = '', _search = '';
  bool _userShown = false;

  AiConversation? _chat;
  List<AiConversation> _history = [];
  bool _loading = true, _sending = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
    widget.surface.aiBuildChanges.addListener(_reload);
    widget.surface.domain.auth.addListener(_accountChanged);
  }

  void _accountChanged() {
    if (mounted) {
      _cancel?.cancel();
      _input.clear();
      setState(() {
        _chat = null;
        _history = [];
        _loading = true;
      });
      unawaited(_load(fresh: true));
    }
  }

  @override
  void dispose() {
    widget.surface.aiBuildChanges.removeListener(_reload);
    widget.surface.domain.auth.removeListener(_accountChanged);
    _cancel?.cancel();
    _streamTimer?.cancel();
    _stream.dispose();
    _focus.dispose();
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _reload() {
    if (!_sending) {
      unawaited(_load(keep: true));
    }
  }

  Future<void> _load({bool keep = false, bool fresh = false}) async {
    try {
      final settings = await widget.surface.aiSettings();
      final list = await widget.surface.aiConversations();
      AiConversation? chat;
      if (keep) {
        chat = list.where((e) => e.id == _chat?.id).firstOrNull;
      }
      if (chat == null && !fresh) {
        chat = list
            .where(
              (e) =>
                  widget.repo.isEmpty ||
                  (e.repo == widget.repo &&
                      (widget.branch.isEmpty || e.branch == widget.branch)),
            )
            .firstOrNull;
      }
      chat ??= await widget.surface.aiNewChat(
        repo: widget.repo,
        branch: widget.branch,
      );
      if (mounted) {
        setState(() {
          _settings = settings;
          _history = list;
          _chat = chat;
          _loading = false;
        });
      }
      _bottom();
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = aiError(e);
          _loading = false;
        });
      }
    }
  }

  void _bottom({bool force = true}) =>
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll.hasClients &&
            (force ||
                (_settings.autoScroll && _scroll.position.extentAfter < 160))) {
          _scroll.jumpTo(_scroll.position.maxScrollExtent);
        }
      });

  Future<void> _send([String? preset]) async {
    final text = preset ?? _input.text.trim();
    if (_sending || _chat == null || text.isEmpty) {
      return;
    }
    _input.clear();
    _focus.requestFocus();
    _cancel = AiCancellation();
    _stream.value = '';
    _userShown = false;
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      final request = widget.surface.aiSend(
        _chat!,
        text,
        (proposal) => mounted
            ? confirmAiProposal(context, proposal)
            : Future.value(false),
        cancellation: _cancel,
        onText: (value) {
          if (!mounted) {
            return;
          }
          if (!_userShown) {
            _userShown = true;
            setState(() {});
            _bottom();
          }
          _pending = value;
          _streamTimer ??= Timer(const Duration(milliseconds: 70), () {
            _streamTimer = null;
            if (mounted) {
              _stream.value = _pending;
              _bottom(force: false);
            }
          });
        },
      );
      setState(() {});
      _bottom();
      await request;
      _history = await widget.surface.aiConversations();
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = aiError(e);
          if (_input.text.isEmpty &&
              _chat?.messages.lastOrNull?.role != 'user') {
            _input.text = text;
          }
        });
      }
    } finally {
      if (mounted) {
        _streamTimer?.cancel();
        _streamTimer = null;
        _stream.value = '';
        setState(() => _sending = false);
        _bottom();
      }
    }
  }

  Future<void> _download(Map<String, dynamic> artifact) async {
    try {
      await widget.surface.downloadAiArtifact(artifact);
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(aiText('downloadQueued'))));
      }
    } catch (e) {
      if (mounted) {
        setState(() => _error = aiError(e));
      }
    }
  }

  Future<void> _logs() async {
    try {
      final entries = await widget.surface.aiAudit();
      if (!mounted) {
        return;
      }
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        builder: (sheet) => SafeArea(
          child: SizedBox(
            height: MediaQuery.sizeOf(sheet).height * .75,
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    aiText('audit'),
                    style: Theme.of(sheet).textTheme.titleLarge,
                  ),
                ),
                Expanded(
                  child: ListView.builder(
                    itemCount: entries.length,
                    itemBuilder: (_, index) {
                      final e = entries[index];
                      final reversible =
                          e['restoreTree'] is String || e['before'] is Map;
                      return ListTile(
                        title: Text('${e['operation']} · ${e['status']}'),
                        subtitle: Text(
                          '${e['repo']}\n${e['at']}\n${e['commit'] ?? ''}',
                        ),
                        trailing: reversible
                            ? TextButton(
                                child: Text(aiText('rollback')),
                                onPressed: () async {
                                  Navigator.pop(sheet);
                                  try {
                                    await widget.surface.aiRollback(
                                      e,
                                      (p) => confirmAiProposal(context, p),
                                    );
                                    if (mounted) {
                                      ScaffoldMessenger.of(context)
                                          .showSnackBar(
                                        SnackBar(
                                          content: Text(
                                            aiText('operationFinished'),
                                          ),
                                        ),
                                      );
                                    }
                                  } catch (error) {
                                    if (mounted) {
                                      setState(() => _error = aiError(error));
                                    }
                                  }
                                },
                              )
                            : null,
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    } catch (e) {
      if (mounted) {
        setState(() => _error = aiError(e));
      }
    }
  }

  Future<String?> _textDialog(String title, String initial) async {
    final controller = TextEditingController(text: initial);
    final result = await showDialog<String>(
        context: context,
        builder: (dialog) => AlertDialog(
                title: Text(title),
                content: TextField(
                    controller: controller,
                    autofocus: true,
                    minLines: 1,
                    maxLines: 5),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(dialog),
                      child: Text(aiText('cancel'))),
                  FilledButton(
                      onPressed: () => Navigator.pop(dialog, controller.text),
                      child: Text(aiText('save')))
                ]));
    // 弹窗退出动画结束之后，输入控件才会解绑 controller。
    const debounceDispose = Duration(milliseconds: 250);
    await Future<void>.delayed(debounceDispose);
    controller.dispose();
    return result;
  }

  Future<bool> _confirm(String title) async =>
      await showDialog<bool>(
          context: context,
          builder: (dialog) => AlertDialog(title: Text(title), actions: [
                TextButton(
                    onPressed: () => Navigator.pop(dialog, false),
                    child: Text(aiText('cancel'))),
                FilledButton(
                    onPressed: () => Navigator.pop(dialog, true),
                    child: Text(aiText('confirm')))
              ])) ??
      false;

  Future<void> _historyAction(AiConversation chat, String action) async {
    try {
      if (action == 'rename') {
        final title = await _textDialog(aiText('rename'), chat.displayTitle);
        if (title != null) {
          await widget.surface.aiRenameChat(chat, title);
        }
      }
      if (action == 'delete' && await _confirm(aiText('deleteChat'))) {
        await widget.surface.aiDeleteChat(chat.id);
      }
      await _load(
          keep: true, fresh: action == 'delete' && chat.id == _chat?.id);
    } catch (e) {
      if (mounted) {
        setState(() => _error = aiError(e));
      }
    }
  }

  Future<void> _edit(int index, {bool regenerate = false}) async {
    if (_sending || _chat == null) {
      return;
    }
    final chat = _chat!;
    var user = index;
    while (user >= 0 && chat.messages[user].role != 'user') {
      user--;
    }
    if (user < 0) {
      return;
    }
    final text = regenerate
        ? chat.messages[user].content
        : await _textDialog(aiText('editMessage'), chat.messages[user].content);
    if (text == null || text.trim().isEmpty) {
      return;
    }
    chat.messages.removeRange(user, chat.messages.length);
    await widget.surface.aiSaveChat(chat);
    if (mounted) {
      await _send(text);
    }
  }

  Future<void> _configure() async {
    await Navigator.push(
        context,
        MaterialPageRoute<void>(
            builder: (_) => AiSettingsPage(surface: widget.surface)));
    if (mounted) {
      final value = await widget.surface.aiSettings();
      if (mounted) {
        setState(() => _settings = value);
      }
    }
  }

  Future<void> _models() async {
    final input = await _textDialog(aiText('model'), _settings.model);
    if (input == null || input.trim().isEmpty) {
      return;
    }
    final value =
        AiSettings.fromJson({..._settings.toJson(), 'model': input.trim()});
    try {
      await widget.surface.aiSaveSettings(value);
      if (mounted) {
        setState(() => _settings = value);
      }
    } catch (e) {
      if (mounted) {
        setState(() => _error = aiError(e));
      }
    }
  }

  Future<void> _repository() async {
    if (_chat == null) {
      return;
    }
    try {
      final data = await widget.surface
          .aiReadTool(_chat!, 'list_my_repositories', {}) as Map;
      if (!mounted) {
        return;
      }
      final selected = await showModalBottomSheet<String>(
          context: context,
          isScrollControlled: true,
          builder: (sheet) => SafeArea(
              child: SizedBox(
                  height: MediaQuery.sizeOf(sheet).height * .7,
                  child: Column(children: [
                    ListTile(
                        title: Text(aiText('repository')),
                        trailing: TextButton(
                            onPressed: () => Navigator.pop(sheet, ''),
                            child: Text(aiText('manualRepo')))),
                    Expanded(
                        child: ListView(children: [
                      for (final item in data['items'] as List)
                        ListTile(
                            title: Text('${(item as Map)['full_name']}'),
                            leading: Icon(item['private'] == true
                                ? Icons.lock_outline
                                : Icons.folder_outlined),
                            onTap: () => Navigator.pop(
                                sheet, item['full_name'] as String))
                    ]))
                  ]))));
      if (selected == null) {
        return;
      }
      final target = selected.isEmpty
          ? await _textDialog(aiText('manualRepo'), _chat!.repo)
          : selected;
      if (target != null && target.isNotEmpty) {
        await widget.surface.aiSwitchRepo(_chat!, target);
        if (mounted) {
          setState(() {});
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() => _error = aiError(e));
      }
    }
  }

  Future<void> _toolMode() async {
    final mode = await showModalBottomSheet<String>(
        context: context,
        builder: (sheet) => SafeArea(
                child: Column(mainAxisSize: MainAxisSize.min, children: [
              for (final mode in ['all', 'read', 'chat'])
                ListTile(
                    title: Text(aiText('mode_$mode')),
                    selected: _settings.toolMode == mode,
                    onTap: () => Navigator.pop(sheet, mode))
            ])));
    if (mode != null) {
      final value =
          AiSettings.fromJson({..._settings.toJson(), 'toolMode': mode});
      await widget.surface.aiSaveSettings(value);
      if (mounted) {
        setState(() => _settings = value);
      }
    }
  }

  Widget _sidebar(bool desktop) {
    final history = _history
        .where((e) => '${e.displayTitle} ${e.repo}'
            .toLowerCase()
            .contains(_search.toLowerCase()))
        .toList();
    return SafeArea(
        child: Column(children: [
      ListTile(
          title: Text(aiText('history')),
          trailing: IconButton(
              tooltip: aiText('newChat'),
              icon: const Icon(Icons.edit_square),
              onPressed: _sending ? null : () => _load(fresh: true))),
      Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: TextField(
              decoration: InputDecoration(
                  hintText: aiText('searchHistory'),
                  prefixIcon: const Icon(Icons.search)),
              onChanged: (v) => setState(() => _search = v))),
      Expanded(
          child: ListView.builder(
              itemCount: history.length,
              itemBuilder: (context, index) {
                final chat = history[index];
                return ListTile(
                    selected: chat.id == _chat?.id,
                    title: Text(
                        chat.displayTitle.isEmpty
                            ? aiText('newChat')
                            : chat.displayTitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis),
                    subtitle: Text(
                        chat.repo.isEmpty
                            ? aiText('accountContext')
                            : chat.repo,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis),
                    onTap: _sending
                        ? null
                        : () {
                            setState(() {
                              _chat = chat;
                              _error = null;
                            });
                            if (!desktop) {
                              Navigator.pop(context);
                            }
                            _bottom();
                          },
                    trailing: PopupMenuButton<String>(
                        enabled: !_sending,
                        onSelected: (v) => _historyAction(chat, v),
                        itemBuilder: (_) => [
                              PopupMenuItem(
                                  value: 'rename',
                                  child: Text(aiText('rename'))),
                              PopupMenuItem(
                                  value: 'delete',
                                  child: Text(aiText('deleteChat')))
                            ]));
              })),
      ListTile(
          leading: const Icon(Icons.tune),
          title: Text(aiText('settings')),
          onTap: _configure),
      ListTile(
          leading: const Icon(Icons.history),
          title: Text(aiText('audit')),
          onTap: _sending ? null : _logs),
      ListTile(
          leading: const Icon(Icons.delete_sweep_outlined),
          title: Text(aiText('clearHistory')),
          onTap: _sending
              ? null
              : () async {
                  if (await _confirm(aiText('clearHistory'))) {
                    await widget.surface.aiClearChats();
                    await _load(fresh: true);
                  }
                }),
    ]));
  }

  Widget _welcome() => Center(
      child: SingleChildScrollView(
          child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.auto_awesome_outlined,
                    size: 40, color: Theme.of(context).colorScheme.primary),
                const SizedBox(height: 20),
                Text(aiText('welcome'),
                    style: Theme.of(context).textTheme.headlineSmall,
                    textAlign: TextAlign.center),
                const SizedBox(height: 24),
                Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    alignment: WrapAlignment.center,
                    children: [
                      for (final key in [
                        'quickRepos',
                        'quickAnalyze',
                        'quickCode',
                        'quickFix',
                        'quickActions',
                        'quickIssues'
                      ])
                        ActionChip(
                            label: Text(aiText(key)),
                            onPressed: () => _send(aiText('${key}Task')))
                    ]),
              ]))));

  Widget _message(AiMessage message, int index) {
    final user = message.role == 'user', scheme = Theme.of(context).colorScheme;
    final text = message.notice ? aiText(message.content) : message.content;
    return Align(
        key: ValueKey('${message.at.microsecondsSinceEpoch}:$index'),
        alignment: user ? Alignment.centerRight : Alignment.centerLeft,
        child: Container(
            constraints: BoxConstraints(maxWidth: user ? 640 : 840),
            margin: const EdgeInsets.only(bottom: 20),
            padding: const EdgeInsets.all(14),
            decoration: user
                ? BoxDecoration(
                    color: scheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(22))
                : null,
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              user
                  ? SelectableText(text,
                      style:
                          TextStyle(fontSize: _settings.fontSize, height: 1.5))
                  : AiMarkdown(text: text, fontSize: _settings.fontSize),
              for (final artifact in message.artifacts)
                OutlinedButton.icon(
                    icon: const Icon(Icons.download),
                    onPressed: () => _download(artifact),
                    label: Text(
                        '${aiText('downloadArtifact')}: ${artifact['name']}.zip')),
              Row(mainAxisSize: MainAxisSize.min, children: [
                IconButton(
                    visualDensity: VisualDensity.compact,
                    tooltip: aiText('copy'),
                    icon: const Icon(Icons.copy_outlined, size: 18),
                    onPressed: () =>
                        Clipboard.setData(ClipboardData(text: text))),
                if (!message.notice)
                  IconButton(
                      visualDensity: VisualDensity.compact,
                      tooltip: aiText(user ? 'editMessage' : 'regenerate'),
                      icon: Icon(user ? Icons.edit_outlined : Icons.refresh,
                          size: 18),
                      onPressed: _sending
                          ? null
                          : () => _edit(index, regenerate: !user)),
              ]),
            ])));
  }

  @override
  Widget build(BuildContext context) {
    final desktop = MediaQuery.sizeOf(context).width >= 1000;
    return Scaffold(
        key: _scaffold,
        resizeToAvoidBottomInset: true,
        appBar: AppBar(
            centerTitle: true,
            leading: IconButton(
                tooltip: aiText('menu'),
                icon: const Icon(Icons.menu),
                onPressed: () => _scaffold.currentState?.openDrawer()),
            title: TextButton(
                onPressed: _sending ? null : _models,
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Flexible(
                      child: Text(
                          _settings.model.isEmpty
                              ? aiText('title')
                              : _settings.model,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis)),
                  const Icon(Icons.expand_more, size: 18)
                ])),
            actions: [
              IconButton(
                  tooltip: aiText('newChat'),
                  icon: const Icon(Icons.edit_square),
                  onPressed: _sending ? null : () => _load(fresh: true))
            ]),
        drawer: Drawer(child: _sidebar(false)),
        body: Row(
          children: [
            if (desktop) SizedBox(width: 280, child: _sidebar(true)),
            Expanded(
                child: SafeArea(
                    top: false,
                    child: Align(
                        alignment: Alignment.topCenter,
                        child: ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 900),
                            child: Column(children: [
                              if (_chat?.repo.isNotEmpty == true)
                                ListTile(
                                    dense: true,
                                    leading: const Icon(Icons.folder_outlined,
                                        size: 18),
                                    title: Text(
                                        '${_chat!.repo} · ${_chat!.branch}',
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis),
                                    onTap: _sending ? null : _repository),
                              Expanded(
                                  child: _loading
                                      ? const Center(
                                          child: CircularProgressIndicator())
                                      : _chat?.messages.isEmpty != false
                                          ? _welcome()
                                          : ListView.builder(
                                              controller: _scroll,
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                      horizontal: 16,
                                                      vertical: 12),
                                              keyboardDismissBehavior:
                                                  ScrollViewKeyboardDismissBehavior
                                                      .onDrag,
                                              itemCount:
                                                  _chat!.messages.length +
                                                      (_sending ? 1 : 0),
                                              itemBuilder: (context, index) {
                                                if (index ==
                                                    _chat!.messages.length) {
                                                  return ValueListenableBuilder<
                                                          String>(
                                                      valueListenable: _stream,
                                                      builder: (_, text, _) => Padding(
                                                          padding:
                                                              const EdgeInsets
                                                                  .all(14),
                                                          child: text.isEmpty
                                                              ? Text(aiText(
                                                                  'working'))
                                                              : AiMarkdown(
                                                                  text: text,
                                                                  fontSize:
                                                                      _settings
                                                                          .fontSize)));
                                                }
                                                return _message(
                                                    _chat!.messages[index],
                                                    index);
                                              })),
                              if (_error != null)
                                Padding(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 16),
                                    child: Row(children: [
                                      Expanded(
                                          child: Text(_error!,
                                              maxLines: 3,
                                              overflow: TextOverflow.ellipsis,
                                              style: TextStyle(
                                                  color: Theme.of(context)
                                                      .colorScheme
                                                      .error))),
                                      TextButton(
                                          onPressed: _configure,
                                          child: Text(aiText('settings')))
                                    ])),
                              if (_chat?.usage.isNotEmpty == true)
                                Padding(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 16),
                                    child: Text(
                                        '${aiText(_chat!.usage['lastEstimated'] == true ? 'estimated' : 'usage')}: ${_chat!.usage['lastInput']} / ${_chat!.usage['lastOutput']} · ${aiText('total')}: ${_chat!.usage['input']} / ${_chat!.usage['output']}',
                                        style: Theme.of(context)
                                            .textTheme
                                            .labelSmall,
                                        maxLines: 2)),
                              Padding(
                                  padding:
                                      const EdgeInsets.fromLTRB(12, 8, 12, 10),
                                  child: Container(
                                      decoration: BoxDecoration(
                                          color: Theme.of(context)
                                              .colorScheme
                                              .surfaceContainer,
                                          borderRadius:
                                              BorderRadius.circular(28)),
                                      padding: const EdgeInsets.fromLTRB(
                                          14, 8, 8, 8),
                                      child: Column(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            CallbackShortcuts(
                                                bindings: {
                                                  const SingleActivator(
                                                      LogicalKeyboardKey.enter,
                                                      control:
                                                          true): () =>
                                                      unawaited(_send())
                                                },
                                                child: TextField(
                                                    key: const ValueKey(
                                                        'ai-input'),
                                                    controller: _input,
                                                    focusNode: _focus,
                                                    minLines: 1,
                                                    maxLines: 6,
                                                    scrollPadding:
                                                        const EdgeInsets.all(
                                                            20),
                                                    style: TextStyle(
                                                        fontSize:
                                                            _settings.fontSize,
                                                        height: 1.5),
                                                    decoration: InputDecoration(
                                                        hintText:
                                                            aiText('inputHint'),
                                                        border:
                                                            InputBorder.none),
                                                    enabled: !_loading)),
                                            Row(children: [
                                              IconButton(
                                                  tooltip: aiText('context'),
                                                  icon: const Icon(Icons.add),
                                                  onPressed: _sending
                                                      ? null
                                                      : _repository),
                                              IconButton(
                                                  tooltip: aiText('repository'),
                                                  icon: const Icon(
                                                      Icons.folder_outlined),
                                                  onPressed: _sending
                                                      ? null
                                                      : _repository),
                                              IconButton(
                                                  tooltip: aiText('toolMode'),
                                                  icon: const Icon(
                                                      Icons.build_outlined),
                                                  onPressed: _sending
                                                      ? null
                                                      : _toolMode),
                                              const Spacer(),
                                              IconButton.filled(
                                                  tooltip: aiText(_sending
                                                      ? 'stop'
                                                      : 'send'),
                                                  onPressed: _loading
                                                      ? null
                                                      : _sending
                                                          ? () =>
                                                              _cancel?.cancel()
                                                          : _send,
                                                  icon: Icon(_sending
                                                      ? Icons.stop
                                                      : Icons.arrow_upward))
                                            ]),
                                          ]))),
                            ])))))
          ],
        ));
  }
}

/// 复用项目代码查看器：高亮、复制和横向滚动；正文继承系统字体回退。
class AiMarkdown extends StatelessWidget {
  const AiMarkdown({required this.text, this.fontSize = 16, super.key});
  final String text;
  final double fontSize;
  @override
  Widget build(BuildContext context) {
    final blocks = RegExp(r'^```([^\n]*)\n([\s\S]*?)^```\s*$', multiLine: true)
        .allMatches(text);
    final children = <Widget>[];
    var offset = 0;
    Widget prose(String data) => MarkdownBody(
        data: data,
        selectable: true,
        styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context)).copyWith(
            p: TextStyle(fontSize: fontSize, height: 1.6),
            listBullet: TextStyle(fontSize: fontSize, height: 1.6),
            code: TextStyle(fontSize: fontSize * .85, height: 1.5)),
        onTapLink: (label, href, title) {
          if (href != null &&
              ['http', 'https'].contains(Uri.tryParse(href)?.scheme)) {
            unawaited(openLinkOrCopy(context, href));
          }
        });
    for (final block in blocks) {
      if (block.start > offset) {
        children.add(prose(text.substring(offset, block.start)));
      }
      final code = block.group(2)!, language = block.group(1)!.trim();
      children.add(Container(
          margin: const EdgeInsets.symmetric(vertical: 8),
          decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainer,
              borderRadius: BorderRadius.circular(12)),
          child: Column(children: [
            Row(children: [
              const SizedBox(width: 12),
              Expanded(
                  child: Text(language,
                      maxLines: 1, overflow: TextOverflow.ellipsis)),
              IconButton(
                  tooltip: aiText('copy'),
                  icon: const Icon(Icons.copy, size: 18),
                  onPressed: () => Clipboard.setData(ClipboardData(text: code)))
            ]),
            SizedBox(
                height: (code.split('\n').length * fontSize * 1.5 + 24)
                    .clamp(70, 360)
                    .toDouble(),
                child: OgLCodeViewer(
                    code: code,
                    language: language,
                    fontSize: fontSize * .85,
                    showLineNumbers: false))
          ])));
      offset = block.end;
    }
    if (offset < text.length) {
      children.add(prose(text.substring(offset)));
    }
    return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch, children: children);
  }
}
