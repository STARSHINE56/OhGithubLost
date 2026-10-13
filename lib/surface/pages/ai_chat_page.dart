/// AI 聊天：本地历史、仓库上下文、写入确认和真实构建产物按钮。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';


import '../surface_bridge.dart';
import '../types.dart';
import '../widgets/ai_message_body.dart';
import 'ai_confirmation.dart';
import 'ai_context_picker.dart';
import 'ai_settings_page.dart';
import 'download_manager_page.dart';

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
  AiConversation? _chat;
  List<AiConversation> _history = [];
  bool _loading = true, _sending = false;
  String? _error;
  AiMessage? _pendingMessage;
  String _streamText = '';
  final _toolEvents = <Map<String, String>>[];
  bool _toolAttempted = false;
  String? _retryText;
  int _messageWindow = 40;
  String _sendStatus = 'preparingRequest';
  int _loadGeneration = 0;
  bool _followLatest = true;
  String _historyFilter = '';
  final _historySearch = TextEditingController();

  List<AiMessage> get _visibleMessages => [
    ...?_chat?.messages,
    if (_pendingMessage != null) _pendingMessage!,
    if (_streamText.isNotEmpty) AiMessage('assistant', _streamText),
  ];

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_trackScroll);
    _input.addListener(_inputChanged);
    _load();
    widget.surface.aiBuildChanges.addListener(_reload);
    widget.surface.domain.auth.addListener(_accountChanged);
  }

  void _accountChanged() {
    if (_sending) widget.surface.aiCancelRequest();
    if (mounted) {
      Navigator.of(context).popUntil((route) => route.isFirst);
    }
  }

  @override
  void dispose() {
    if (_sending) widget.surface.aiCancelRequest();
    widget.surface.aiBuildChanges.removeListener(_reload);
    widget.surface.domain.auth.removeListener(_accountChanged);
    _input.removeListener(_inputChanged);
    _input.dispose();
    _historySearch.dispose();
    _scroll.removeListener(_trackScroll);
    _scroll.dispose();
    super.dispose();
  }

  void _reload() {
    if (!_sending) {
      unawaited(_load(keep: true));
    }
  }

  Future<void> _load({bool keep = false, bool fresh = false}) async {
    final generation = ++_loadGeneration;
    try {
      final list = await widget.surface.aiConversationSummaries();
      if (!mounted || generation != _loadGeneration) return;
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
      if (chat != null) chat = await widget.surface.aiLoadConversation(chat.id);
      chat ??= await widget.surface.aiNewChat(
        repo: widget.repo,
        branch: widget.branch,
      );
      if (mounted && generation == _loadGeneration) {
        setState(() {
          _history = list;
          _chat = chat;
          _loading = false;
        });
      }
      _bottom();
    } catch (e) {
      if (mounted && generation == _loadGeneration) {
        setState(() {
          _error = aiError(e);
          _loading = false;
        });
      }
    }
  }

  void _inputChanged() { if (mounted) setState(() {}); }

  void _trackScroll() {
    if (!_scroll.hasClients) return;
    final follow = _scroll.position.extentAfter < 100;
    if (follow != _followLatest && mounted) setState(() => _followLatest = follow);
  }

  void _bottom({bool force = false}) => WidgetsBinding.instance.addPostFrameCallback((_) {
    if (mounted && _scroll.hasClients && (force || _followLatest)) {
      _scroll.jumpTo(_scroll.position.maxScrollExtent);
    }
  });

  Future<void> _send({bool retry = false}) async {
    final text = _input.text.trim();
    if (_sending || _chat == null || text.isEmpty) {
      return;
    }
    final chat = _chat!;
    final previousUserCount = chat.messages.where((m) => m.role == 'user').length;
    _input.clear();
    setState(() {
      _sending = true;
      _error = null;
      _pendingMessage = retry ? null : AiMessage('user', text);
      _sendStatus = 'preparingRequest';
      _streamText = '';
      _toolEvents.clear();
      _toolAttempted = false;
      _retryText = null;
    });
    _followLatest = true;
    _bottom(force: true);
    try {
      final request = widget.surface.aiSend(
        chat,
        text,
        (proposal) async {
          if (!mounted || ModalRoute.of(context)?.isCurrent != true) {
            return false;
          }
          return confirmAiProposal(context, proposal);
        },
        onProgress: (state) {
          if (!mounted || !identical(_chat, chat)) return;
          setState(() {
            if (chat.messages.where((m) => m.role == 'user').length > previousUserCount) {
              _pendingMessage = null;
            }
            if (state == 'messagesUpdated' || state == 'requestingResponse' || state == 'executingTool') {
              _streamText = '';
            }
            if (state != 'messageAccepted' && state != 'messagesUpdated') {
              _sendStatus = state;
            }
          });
          _bottom();
        },
        retry: retry,
        onText: (text) {
          if (!mounted || !identical(_chat, chat)) return;
          setState(() => _streamText = text);
          _bottom();
        },
        onTool: (event) {
          if (!mounted || !identical(_chat, chat)) return;
          setState(() {
            _toolAttempted = true;
            if (event['status'] == 'running') { _toolEvents.add(Map.of(event)); }
            else if (_toolEvents.isNotEmpty) { _toolEvents.last = Map.of(event); }
          });
        },
      );
      await request;
      _history = await widget.surface.aiConversationSummaries();
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = aiError(e);
          // 有任何工具尝试就不提供一键重试，避免重复远端写入。
          _retryText = !_toolAttempted && e is AiException && e.code != 'requestStopped' ? text : null;
          if (_input.text.trim().isEmpty) _input.text = text;
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _sending = false;
          _pendingMessage = null;
          _streamText = '';
        });
        _bottom();
      }
    }
  }

  Future<void> _download(Map<String, dynamic> artifact) async {
    try {
      await widget.surface.downloadAiArtifact(artifact);
      if (mounted) {
        ogLShowDownloadQueued(context, widget.surface, aiText('downloadQueued'));
      }
    } catch (e) {
      if (mounted) {
        setState(() => _error = aiError(e));
      }
    }
  }

  Future<void> _selectContext() async {
    final chat = _chat;
    if (_sending || chat == null) return;
    final choice = await showDialog<AiContextChoice>(context: context,
      builder: (_) => AiContextPicker(surface: widget.surface));
    if (choice == null || !mounted || !identical(chat, _chat)) return;
    try {
      await widget.surface.aiSetContext(chat, choice.repo, choice.branch);
      if (mounted) setState(() {});
    } catch (e) {
      if (mounted) setState(() => _error = aiError(e));
    }
  }

  Future<void> _renameChat(AiConversation chat) async {
    final controller = TextEditingController(text: chat.title);
    final title = await showDialog<String>(context: context,
      builder: (dialog) => AlertDialog(title: Text(aiText('renameChat')),
        content: TextField(controller: controller, maxLength: 120,
          decoration: InputDecoration(hintText: aiText('chatTitleHint'))),
        actions: [TextButton(onPressed: () => Navigator.pop(dialog), child: Text(aiText('cancel'))),
          FilledButton(onPressed: () => Navigator.pop(dialog, controller.text), child: Text(aiText('save')))]));
    controller.dispose();
    if (title == null || !mounted) return;
    try {
      await widget.surface.aiRenameChat(chat, title);
      if (mounted) setState(() {});
    } catch (e) {
      if (mounted) setState(() => _error = aiError(e));
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

  @override
  Widget build(BuildContext context) {
    final allMessages = _visibleMessages;
    final start = (allMessages.length - _messageWindow).clamp(0, allMessages.length);
    final visibleMessages = allMessages.sublist(start);
    final history = _history.where((chat) =>
      ('${chat.title} ${chat.repo} ${chat.messages.isEmpty ? '' : chat.messages.first.content}')
        .toLowerCase().contains(_historyFilter.toLowerCase())).toList();
    return Scaffold(
    resizeToAvoidBottomInset: true,
    appBar: AppBar(
      title: Text(aiText('title')),
      actions: [
        IconButton(
          tooltip: aiText('newChat'),
          icon: const Icon(Icons.add_comment_outlined),
          onPressed: _sending ? null : () => _load(fresh: true),
        ),
        IconButton(
          tooltip: aiText('audit'),
          icon: const Icon(Icons.receipt_long_outlined),
          onPressed: _sending ? null : _logs,
        ),
        IconButton(
          tooltip: aiText('settings'),
          icon: const Icon(Icons.tune),
          onPressed: () => Navigator.push(
            context,
            MaterialPageRoute<void>(
              builder: (_) => AiSettingsPage(surface: widget.surface),
            ),
          ),
        ),
      ],
    ),
    drawer: Drawer(
      child: SafeArea(
        child: Column(
          children: [
            ListTile(leading: const Icon(Icons.history), title: Text(aiText('history'))),
            Padding(padding: const EdgeInsets.symmetric(horizontal: 16),
              child: TextField(controller: _historySearch,
                decoration: InputDecoration(hintText: aiText('searchHistory'),
                  prefixIcon: const Icon(Icons.search), border: const OutlineInputBorder()),
                onChanged: (text) => setState(() => _historyFilter = text))),
            const SizedBox(height: 12),
            Expanded(
              child: ListView.builder(
                itemCount: history.length,
                itemBuilder: (_, index) {
                  final chat = history[index];
                  return ListTile(
                    selected: chat.id == _chat?.id,
                    title: Text(
                      chat.title.isNotEmpty ? chat.title : chat.messages.isEmpty
                          ? aiText('newChat')
                          : chat.messages.first.content,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      chat.repo.isEmpty ? aiText('noRepo') : chat.repo,
                    ),
                    onTap: _sending
                        ? null
                        : () async {
                            Navigator.pop(context);
                            final generation = ++_loadGeneration;
                            setState(() => _loading = true);
                            try {
                              final loaded = await widget.surface.aiLoadConversation(chat.id);
                              if (!mounted || generation != _loadGeneration) return;
                              setState(() { _chat = loaded; _loading = false; _error = null;
                                _toolEvents.clear(); _streamText = ''; _messageWindow = 40; });
                              _bottom(force: true);
                            } catch (e) {
                              if (mounted) setState(() { _loading = false; _error = aiError(e); });
                            }
                          },
                    onLongPress: _sending ? null : () => _renameChat(chat),
                    trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                      IconButton(tooltip: aiText('renameChat'), icon: const Icon(Icons.edit_outlined),
                        onPressed: _sending ? null : () => _renameChat(chat)),
                      IconButton(
                      tooltip: aiText('deleteChat'),
                      icon: const Icon(Icons.delete_outline),
                      onPressed: _sending
                          ? null
                          : () async {
                              final accepted = await showDialog<bool>(context: context,
                                builder: (dialog) => AlertDialog(title: Text(aiText('deleteChat')),
                                  content: Text(aiText('deleteChatWarning')),
                                  actions: [TextButton(onPressed: () => Navigator.pop(dialog, false),
                                    child: Text(aiText('cancel'))),
                                    FilledButton(onPressed: () => Navigator.pop(dialog, true),
                                      child: Text(aiText('deleteChat')))]));
                              if (accepted != true || !context.mounted) return;
                              await widget.surface.aiDeleteChat(chat.id);
                              if (context.mounted) {
                                Navigator.pop(context);
                                await _load(fresh: chat.id == _chat?.id);
                              }
                            },
                    ),
                    ]),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    ),
    body: SafeArea(
      child: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 920),
          child: Column(
            children: [
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 10,
                ),
                color: Theme.of(context).colorScheme.surfaceContainer,
                child: Row(children: [const Icon(Icons.folder_outlined, size: 18),
                  const SizedBox(width: 10),
                  Expanded(child: Text(_chat?.repo.isNotEmpty == true
                    ? '${_chat!.repo} · ${_chat!.branch}' : aiText('accountContext'),
                    maxLines: 1, overflow: TextOverflow.ellipsis)),
                  if (_sending) const Icon(Icons.lock_outline, size: 16)
                  else IconButton(tooltip: aiText('selectRepository'),
                    icon: const Icon(Icons.account_tree_outlined, size: 20),
                    onPressed: _loading ? null : _selectContext),
                ]),
              ),
              if (start > 0) TextButton(onPressed: () => setState(() {
                _messageWindow += 40; _followLatest = false;
              }), child: Text(aiText('loadEarlierMessages'))),
              Expanded(
                child: _loading
                    ? const Center(child: CircularProgressIndicator())
                    : visibleMessages.isEmpty
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Text(
                            aiText('welcome'),
                            textAlign: TextAlign.center,
                          ),
                        ),
                      )
                    : ListView.builder(
                        controller: _scroll,
                        padding: const EdgeInsets.all(16),
                        itemCount: visibleMessages.length,
                        itemBuilder: (context, index) {
                          final message = visibleMessages[index];
                          final user = message.role == 'user';
                          return Align(
                            alignment: user
                                ? Alignment.centerRight
                                : Alignment.centerLeft,
                            child: Container(
                              constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width.clamp(280, 760) * (user ? .80 : .94)),
                              child: Card(
                              elevation: 0,
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                              color: user
                                  ? Theme.of(context)
                                        .colorScheme
                                        .primaryContainer
                                  : null,
                              margin: const EdgeInsets.only(bottom: 16),
                              child: Padding(
                                padding: const EdgeInsets.all(16),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(mainAxisSize: MainAxisSize.min, children: [
                                      Icon(user ? Icons.person_outline : Icons.auto_awesome_outlined, size: 16),
                                      const SizedBox(width: 8),
                                      Text(aiText(user ? 'you' : 'title'), style: Theme.of(context).textTheme.labelMedium),
                                      const SizedBox(width: 12),
                                      IconButton(tooltip: aiText('copyMessage'), visualDensity: VisualDensity.compact,
                                        icon: const Icon(Icons.copy_outlined, size: 16),
                                        onPressed: () async {
                                          await Clipboard.setData(ClipboardData(text: message.notice ? aiText(message.content) : message.content));
                                          if (context.mounted) {
                                            ScaffoldMessenger.of(context).showSnackBar(
                                              SnackBar(content: Text(aiText('messageCopied'))));
                                          }
                                        }),
                                    ]),
                                    const SizedBox(height: 8),
                                    AiMessageBody(text: message.notice ? aiText(message.content) : message.content),
                                    for (final artifact in message.artifacts)
                                      OutlinedButton.icon(
                                        icon: const Icon(Icons.download),
                                        onPressed: () => _download(artifact),
                                        label: Text(
                                          '${aiText('downloadArtifact')}: ${artifact['name']}.zip',
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                            ),
                            ),
                          );
                        },
                      ),
              ),
              if (!_followLatest && visibleMessages.isNotEmpty)
                Padding(padding: const EdgeInsets.only(bottom: 8),
                  child: FilledButton.tonalIcon(onPressed: () => _bottom(force: true),
                    icon: const Icon(Icons.arrow_downward, size: 18), label: Text(aiText('latestMessages')))),
              if (_toolEvents.isNotEmpty)
                Padding(padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
                  child: Card(elevation: 0, margin: EdgeInsets.zero,
                    clipBehavior: Clip.antiAlias,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                    child: ExpansionTile(
                  leading: const Icon(Icons.build_circle_outlined, size: 20),
                  title: Text(aiText('toolActivity'), style: Theme.of(context).textTheme.titleSmall),
                  trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                    Text('${_toolEvents.length}', style: Theme.of(context).textTheme.labelMedium),
                    const SizedBox(width: 8), const Icon(Icons.expand_more, size: 20)]),
                  children: [SizedBox(height: MediaQuery.sizeOf(context).height * .20,
                    child: ListView(children: [for (final event in _toolEvents)
                    ListTile(dense: true,
                      leading: Icon(event['status'] == 'completed' ? Icons.check_circle_outline : event['status'] == 'failed' ? Icons.error_outline : Icons.pending_outlined),
                      title: Text(event['name'] ?? ''),
                      subtitle: Text('${event['repo'] ?? ''} · ${aiText('tool_${event['status']}')}'))]))]))),
              if (_sending)
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 8, 16, 0),
                  child: Row(
                    children: [
                      const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                      const SizedBox(width: 12),
                      Expanded(child: Text(aiText(_sendStatus),
                        key: const ValueKey('ai-send-status'), maxLines: 2)),
                      IconButton(tooltip: aiText('stopRequest'), icon: const Icon(Icons.stop_circle_outlined),
                        onPressed: widget.surface.aiCanCancel ? widget.surface.aiCancelRequest : null),
                    ],
                  ),
                ),
              if (_retryText != null && !_sending)
                TextButton.icon(icon: const Icon(Icons.refresh), label: Text(aiText('retryResponse')),
                  onPressed: () { _input.text = _retryText!; _send(retry: true); }),
              if (_error != null)
                ListTile(
                  leading: const Icon(Icons.error_outline),
                  title: Text(_error!, maxLines: 3, overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.error)),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 20),
                  trailing: IconButton(
                    tooltip: aiText('settings'),
                    icon: const Icon(Icons.tune),
                    onPressed: () => Navigator.push(
                      context,
                      MaterialPageRoute<void>(
                        builder: (_) => AiSettingsPage(surface: widget.surface),
                      ),
                    ),
                  ),
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Expanded(
                      child: CallbackShortcuts(
                        bindings: {
                          const SingleActivator(
                            LogicalKeyboardKey.enter,
                            control: true,
                          ): () =>
                              unawaited(_send()),
                        },
                        child: TextField(
                          controller: _input,
                          minLines: 1,
                          maxLines: 6,
                          decoration: InputDecoration(
                            hintText: aiText(widget.surface.isDesktop ? 'inputHint' : (_sending ? 'draftHint' : 'mobileInputHint')),
                            filled: true,
                            border: OutlineInputBorder(borderRadius: BorderRadius.circular(18)),
                            contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                          ),
                          enabled: !_loading,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    SizedBox(width: 52, height: 52,
                      child: IconButton.filled(
                      style: IconButton.styleFrom(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16))),
                      tooltip: aiText('send'),
                      onPressed: _sending || _loading || _chat == null || _input.text.trim().isEmpty ? null : _send,
                      icon: const Icon(Icons.arrow_upward),
                    )),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
  }
}
