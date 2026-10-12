/// GitHub 通知与原有应用日志并存；分页与已读操作都有可见失败提示。
library;

import 'package:flutter/material.dart';

import '../surface_bridge.dart';
import '../util/link_opener.dart';
import 'ai_settings_page.dart';
import 'issue_page.dart';
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
  @override
  void initState() {
    super.initState();
    _load(reset: true);
  }

  Future<void> _load({bool reset = false}) async {
    if (_busy) {
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final next = reset ? 1 : _page;
      final items = await widget.surface.githubNotifications(
        page: next,
        all: _all,
      );
      if (mounted) {
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
      if (mounted) {
        setState(() => _error = aiError(e));
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _read(Map<String, dynamic> item) async {
    try {
      await widget.surface.markGithubNotificationRead('${item['id']}');
      if (mounted) {
        setState(() {
          item['unread'] = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _error = aiError(e));
      }
    }
  }

  /// Issue/PR 在应用中查看；其他通知回到 GitHub 对应仓库页。
  Future<void> _open(Map<String, dynamic> item) async {
    final subject = item['subject'] as Map;
    final repo = (item['repository'] as Map)['full_name'] as String;
    try {
      if (subject['type'] == 'Issue' || subject['type'] == 'PullRequest') {
        final detail = await widget.surface.githubNotificationSubject(
          repo,
          subject['url'] as String,
        );
        if (!mounted) {
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
        setState(() => _error = aiError(e));
      }
    }
  }

  @override
  Widget build(BuildContext context) => DefaultTabController(
    length: 2,
    child: Scaffold(
      appBar: AppBar(
        title: Text(aiText('notifications')),
        bottom: TabBar(
          tabs: [
            const Tab(text: 'GitHub'),
            Tab(text: aiText('appLogs')),
          ],
        ),
      ),
      body: TabBarView(
        children: [
          Column(
            children: [
              SwitchListTile(
                title: Text(aiText('showRead')),
                value: _all,
                onChanged: _busy
                    ? null
                    : (v) {
                        setState(() => _all = v);
                        _load(reset: true);
                      },
              ),
              if (_busy) const LinearProgressIndicator(),
              if (_error != null)
                ListTile(
                  title: Text(_error!),
                  trailing: TextButton(
                    onPressed: () => _load(reset: _items.isEmpty),
                    child: Text(aiText('retry')),
                  ),
                ),
              Expanded(
                child: RefreshIndicator(
                  onRefresh: () => _load(reset: true),
                  child: ListView.builder(
                    physics: const AlwaysScrollableScrollPhysics(),
                    itemCount: _items.length + 1,
                    itemBuilder: (context, index) {
                      if (index == _items.length) {
                        if (_items.isEmpty && !_busy) {
                          return Padding(
                            padding: const EdgeInsets.all(32),
                            child: Text(aiText('noNotifications')),
                          );
                        }
                        return _more && !_busy
                            ? TextButton(
                                onPressed: _load,
                                child: Text(aiText('loadMore')),
                              )
                            : const SizedBox.shrink();
                      }
                      final item = _items[index];
                      final subject = item['subject'] as Map;
                      final unread = item['unread'] == true;
                      return Card(
                        elevation: 1,
                        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                        child: InkWell(
                          onTap: () => _open(item),
                          borderRadius: BorderRadius.circular(12),
                          child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: Row(
                              children: [
                                Icon(
                                  unread
                                      ? Icons.mark_email_unread_outlined
                                      : Icons.drafts_outlined,
                                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                                  size: 20,
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        '${subject['title']}',
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(fontWeight: FontWeight.w500),
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        '${(item['repository'] as Map)['full_name']}',
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          fontSize: 12,
                                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                                        ),
                                      ),
                                      Text(
                                        '${item['reason']} · ${item['updated_at']}',
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          fontSize: 12,
                                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                if (unread)
                                  IconButton(
                                    tooltip: aiText('markRead'),
                                    icon: const Icon(Icons.done),
                                    onPressed: () => _read(item),
                                  ),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
            ],
          ),
          const NotificationsPage(),
        ],
      ),
    ),
  );
}
