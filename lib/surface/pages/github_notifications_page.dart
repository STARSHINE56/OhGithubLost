/// GitHub 通知与原有应用日志并存；分页与已读操作都有可见失败提示。
library;

import 'package:flutter/material.dart';

import '../surface_bridge.dart';
import '../util/link_opener.dart';
import 'ai_settings_page.dart';
import 'notifications_page.dart';

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

  /// GitHub subject.url 是 API 地址；只把验证后的 Issue/PR 路径转成网页地址。
  String _url(Map<String, dynamic> item) {
    final subject = item['subject'] as Map;
    final uri = Uri.tryParse(subject['url'] as String? ?? '');
    if (uri?.host == 'api.github.com' && uri!.path.startsWith('/repos/')) {
      final path = uri.path
          .substring('/repos'.length)
          .replaceFirst('/pulls/', '/pull/');
      return 'https://github.com$path';
    }
    return (item['repository'] as Map)['html_url'] as String;
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
                      return ListTile(
                        leading: Icon(
                          unread
                              ? Icons.mark_email_unread_outlined
                              : Icons.drafts_outlined,
                        ),
                        title: Text('${subject['title']}'),
                        subtitle: Text(
                          '${(item['repository'] as Map)['full_name']}\n${item['reason']} · ${item['updated_at']}',
                        ),
                        onTap: () => openLinkOrCopy(context, _url(item)),
                        trailing: unread
                            ? IconButton(
                                tooltip: aiText('markRead'),
                                icon: const Icon(Icons.done),
                                onPressed: () => _read(item),
                              )
                            : null,
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
