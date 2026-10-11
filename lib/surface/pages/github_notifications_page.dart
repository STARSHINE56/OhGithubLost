/// GitHub 通知与原有应用日志并存；分页与已读操作都有可见失败提示。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../surface_bridge.dart';
import '../types.dart';
import '../util/link_opener.dart';
import 'ai_settings_page.dart';
import 'issue_page.dart';
import 'login_page.dart';
import 'notifications_page.dart';
import 'pull_page.dart';

class GithubNotificationsPage extends StatefulWidget {
  const GithubNotificationsPage({required this.surface, super.key});
  final SurfaceBridge surface;
  @override
  State<GithubNotificationsPage> createState() =>
      _GithubNotificationsPageState();
}

class _GithubNotificationsPageState extends State<GithubNotificationsPage> {
  final List<Map<String, dynamic>> _items = [];
  bool _busy = false, _more = true, _all = false;
  int _page = 1;
  String? _error;
  bool _authorizationError = false;
  int _epoch = 0;
  @override
  void initState() {
    super.initState();
    widget.surface.domain.auth.addListener(_accountChanged);
    _load(reset: true);
  }

  @override
  void dispose() {
    widget.surface.domain.auth.removeListener(_accountChanged);
    _epoch++;
    super.dispose();
  }

  void _accountChanged() {
    if (!mounted) {
      return;
    }
    _epoch++;
    setState(() {
      _items.clear();
      _page = 1;
      _more = true;
      _busy = false;
      _error = null;
      _authorizationError = false;
    });
    unawaited(_load(reset: true));
  }

  void _setError(Object error) {
    _authorizationError = error is AiException &&
        ['notificationsTokenUnsupported', 'notificationsPermission']
            .contains(error.code);
    _error = aiError(error);
  }

  Future<void> _authorize() async {
    await Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (routeContext) => LoginPage(
            surface: widget.surface,
            onLoggedIn: () async {
              if (routeContext.mounted) {
                Navigator.of(routeContext).pop();
              }
            })));
    if (mounted) {
      await _load(reset: true);
    }
  }

  Future<void> _load({bool reset = false}) async {
    if (_busy) {
      return;
    }
    final epoch = ++_epoch;
    setState(() {
      _busy = true;
      _error = null;
      _authorizationError = false;
    });
    try {
      final next = reset ? 1 : _page;
      final items = await widget.surface.githubNotifications(
        page: next,
        all: _all,
      );
      if (mounted && epoch == _epoch) {
        setState(() {
          if (reset) {
            _items.clear();
          }
          _items.addAll(items);
          _page = next + 1;
          _more = items.length == 50;
        });
      }
    } catch (e) {
      if (mounted && epoch == _epoch) {
        setState(() => _setError(e));
      }
    } finally {
      if (mounted && epoch == _epoch) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _read(Map<String, dynamic> item) async {
    final epoch = _epoch;
    try {
      await widget.surface.markGithubNotificationRead('${item['id']}');
      if (mounted && epoch == _epoch) {
        setState(() {
          item['unread'] = false;
        });
      }
    } catch (e) {
      if (mounted && epoch == _epoch) {
        setState(() => _setError(e));
      }
    }
  }

  /// Issue/PR 在应用中查看；其他通知回到 GitHub 对应仓库页。
  Future<void> _open(Map<String, dynamic> item) async {
    final epoch = _epoch;
    final subject = item['subject'] as Map;
    final repo = (item['repository'] as Map)['full_name'] as String;
    try {
      if (subject['type'] == 'Issue' || subject['type'] == 'PullRequest') {
        final detail = await widget.surface.githubNotificationSubject(
          repo,
          subject['url'] as String,
        );
        if (!mounted || epoch != _epoch) {
          return;
        }
        final Widget page = subject['type'] == 'Issue'
            ? IssuePage(surface: widget.surface, fullName: repo, issue: detail)
            : PullPage(
                surface: widget.surface,
                fullName: repo,
                pull: detail,
                number: detail['number'] as int,
              );
        await Navigator.of(context)
            .push(MaterialPageRoute<void>(builder: (_) => page));
      } else {
        await openLinkOrCopy(
          context,
          'https://github.com/$repo${subject['type'] == 'Release' ? '/releases' : ''}',
        );
      }
    } catch (e) {
      if (mounted) {
        if (epoch == _epoch) {
          setState(() => _setError(e));
        }
      }
    }
  }

  Widget _githubTab() => RefreshIndicator(
      onRefresh: () => _load(reset: true),
      child: ListView.builder(
          physics: const AlwaysScrollableScrollPhysics(),
          itemCount: _items.length + 3,
          itemBuilder: (context, index) {
            if (index == 0) {
              return SwitchListTile(
                  title: Text(aiText('showRead')),
                  value: _all,
                  onChanged: _busy
                      ? null
                      : (v) {
                          setState(() => _all = v);
                          _load(reset: true);
                        });
            }
            if (index == 1) {
              return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (_busy) const LinearProgressIndicator(),
                    if (_error != null)
                      Padding(
                          padding: const EdgeInsets.all(16),
                          child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Text(_error!),
                                const SizedBox(height: 8),
                                Wrap(spacing: 8, runSpacing: 8, children: [
                                  if (_authorizationError)
                                    FilledButton.tonal(
                                        onPressed: _authorize,
                                        child: Text(
                                            aiText('notificationsAuthorize')))
                                  else
                                    TextButton(
                                        onPressed: () =>
                                            _load(reset: _items.isEmpty),
                                        child: Text(aiText('retry'))),
                                  TextButton(
                                      onPressed: () => openLinkOrCopy(context,
                                          'https://github.com/notifications'),
                                      child: Text(aiText('notificationsWeb')))
                                ])
                              ]))
                  ]);
            }
            final itemIndex = index - 2;
            if (itemIndex == _items.length) {
              if (_items.isEmpty && !_busy && _error == null) {
                return Padding(
                    padding: const EdgeInsets.all(32),
                    child: Text(aiText('noNotifications')));
              }
              return _more && !_busy && _error == null && _items.isNotEmpty
                  ? TextButton(
                      onPressed: _load, child: Text(aiText('loadMore')))
                  : const SizedBox.shrink();
            }
            final item = _items[itemIndex];
            final subject = item['subject'] as Map;
            final unread = item['unread'] == true;
            return ListTile(
                leading: Icon(unread
                    ? Icons.mark_email_unread_outlined
                    : Icons.drafts_outlined),
                title: Text('${subject['title']}'),
                subtitle: Text(
                    '${(item['repository'] as Map)['full_name']}\n${item['reason']} · ${item['updated_at']}'),
                onTap: () => _open(item),
                trailing: unread
                    ? IconButton(
                        tooltip: aiText('markRead'),
                        icon: const Icon(Icons.done),
                        onPressed: () => _read(item))
                    : null);
          }));

  @override
  Widget build(BuildContext context) => DefaultTabController(
      length: 2,
      child: Scaffold(
          appBar: AppBar(
              title: Text(aiText('notifications')),
              bottom: TabBar(tabs: [
                const Tab(text: 'GitHub'),
                Tab(text: aiText('appLogs'))
              ])),
          body:
              TabBarView(children: [_githubTab(), const NotificationsPage()])));
}
