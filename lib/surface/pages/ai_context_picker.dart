/// 仓库/分支选择：账号绑定、分页加载、错误可见，不修改远端。
library;

import 'package:flutter/material.dart';

import '../surface_bridge.dart';
import 'ai_settings_page.dart';

class AiContextChoice {
  const AiContextChoice(this.repo, this.branch);
  final String repo;
  final String branch;
}

class AiContextPicker extends StatefulWidget {
  const AiContextPicker({required this.surface, super.key});
  final SurfaceBridge surface;
  @override
  State<AiContextPicker> createState() => _AiContextPickerState();
}

class _AiContextPickerState extends State<AiContextPicker> {
  final _repos = <Map<String, dynamic>>[];
  final _branches = <String>[];
  String? _repo, _error;
  String _filter = '';
  bool _busy = false, _more = true;
  int _page = 1;

  @override
  void initState() { super.initState(); _load(); }

  Future<void> _load() async {
    if (_busy) return;
    setState(() { _busy = true; _error = null; });
    try {
      final repo = _repo;
      if (repo == null) {
        final result = await widget.surface.aiContextRepositories(page: _page);
        if (!mounted) return;
        setState(() { _repos.addAll(result); _more = result.length == 100; _page++; });
      } else {
        final result = await widget.surface.aiContextBranches(repo, page: _page);
        if (!mounted) return;
        setState(() { _branches.addAll(result); _more = result.length == 100; _page++; });
      }
    } catch (e) {
      if (mounted) setState(() => _error = aiError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _selectRepo(String repo) {
    setState(() { _repo = repo; _filter = ''; _branches.clear(); _page = 1; _more = true; });
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final names = _repo == null
        ? _repos.map((e) => '${e['full_name']}').toList()
        : _branches;
    final visible = names.where((e) => e.toLowerCase().contains(_filter.toLowerCase())).toList();
    return AlertDialog(
      title: Text(aiText(_repo == null ? 'selectRepository' : 'selectBranch')),
      content: SizedBox(width: 520, height: MediaQuery.sizeOf(context).height * .55,
        child: Column(children: [
          if (_repo != null) Text(_repo!, maxLines: 1, overflow: TextOverflow.ellipsis),
          TextField(key: ValueKey(_repo), decoration: InputDecoration(
            hintText: aiText('filterLoaded'), prefixIcon: const Icon(Icons.search)),
            onChanged: (v) => setState(() => _filter = v)),
          if (_busy) const LinearProgressIndicator(),
          if (_error != null) Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          Expanded(child: ListView.builder(itemCount: visible.length,
            itemBuilder: (_, i) => ListTile(title: Text(visible[i]),
              leading: Icon(_repo == null ? Icons.folder_outlined : Icons.account_tree_outlined),
              onTap: _busy ? null : () {
                if (_repo == null) { _selectRepo(visible[i]); }
                else { Navigator.pop(context, AiContextChoice(_repo!, visible[i])); }
              }))),
          if (!_busy && (_more || _error != null)) TextButton.icon(
            onPressed: _load, icon: Icon(_error != null ? Icons.refresh : Icons.expand_more),
            label: Text(aiText(_error != null ? 'retryLoad' : 'loadMore'))),
        ])),
      actions: [
        if (_repo == null) TextButton(onPressed: _busy ? null : () => Navigator.pop(context, const AiContextChoice('', '')),
          child: Text(aiText('accountContext'))),
        TextButton(onPressed: () => Navigator.pop(context), child: Text(aiText('cancel'))),
      ],
    );
  }
}
