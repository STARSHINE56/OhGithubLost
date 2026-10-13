/// 扩展 GitHub 能力白名单；模型不构造任意 URL，不接触 Token。
library;

import 'ai_models.dart';

class AiGithubPlan {
  const AiGithubPlan(this.method, this.path, {this.body, this.query = const {}});
  final String method;
  final String path;
  final Map<String, Object?>? body;
  final Map<String, String> query;
}

abstract final class AiGithubTools {
  static const reads = <String>[
    'current_user', 'my_repositories', 'starred_repositories', 'search_repositories',
    'notifications', 'my_gists', 'organizations', 'repository', 'branches',
    'commits', 'releases', 'issue_comments', 'pull_files', 'collaborators',
    'labels', 'milestones', 'workflow_runs', 'workflow_jobs', 'workflow_artifacts',
    'repository_permissions',
  ];
  static const writes = <String>[
    'create_repository', 'update_repository', 'delete_repository', 'fork_repository',
    'star_repository', 'unstar_repository', 'watch_repository', 'unwatch_repository',
    'create_branch', 'delete_branch', 'create_release', 'update_release', 'delete_release',
    'issue_comment', 'merge_pull', 'close_pull', 'rerun_workflow', 'cancel_workflow',
    'mark_notification_read', 'mark_all_notifications_read', 'create_gist',
    'update_gist', 'delete_gist', 'add_collaborator', 'remove_collaborator',
    'create_label', 'delete_label', 'create_milestone',
  ];

  static String _text(Map<String, dynamic> args, String key) {
    final value = args[key];
    if (value is! String || value.trim().isEmpty || value.contains(RegExp(r'[\x00-\x1f]'))) {
      throw const AiException('invalidProposal');
    }
    return value.trim();
  }
  static String _id(Map<String, dynamic> args, String key) {
    final value = '${args[key] ?? ''}';
    if (!RegExp(r'^[1-9][0-9]*$').hasMatch(value)) throw const AiException('invalidProposal');
    return value;
  }
  static String _segment(String value) => Uri.encodeComponent(value);
  static String _repo(String repo) {
    if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9_.-]*/[A-Za-z0-9_.-]+$').hasMatch(repo) || repo.split('/').contains('..')) {
      throw const AiException('invalidRepo');
    }
    return '/repos/$repo';
  }
  static Map<String, String> _page(Map<String, dynamic> args) {
    final page = args['page'] ?? 1;
    if (page is! int || page < 1 || page > 10000) throw const AiException('invalidProposal');
    return {'page': '$page', 'per_page': '100'};
  }

  static AiGithubPlan read(Map<String, dynamic> args, String repo) {
    final action = _text(args, 'action');
    if (!reads.contains(action)) throw const AiException('unknownTool');
    final query = _page(args);
    switch (action) {
      case 'current_user': return const AiGithubPlan('GET', '/user');
      case 'my_repositories': return AiGithubPlan('GET', '/user/repos', query: {...query, 'visibility': 'all', 'affiliation': 'owner,collaborator,organization_member', 'sort': 'full_name'});
      case 'starred_repositories': return AiGithubPlan('GET', '/user/starred', query: query);
      case 'search_repositories': return AiGithubPlan('GET', '/search/repositories', query: {...query, 'q': _text(args, 'query')});
      case 'notifications': return AiGithubPlan('GET', '/notifications', query: {...query, 'all': 'true'});
      case 'my_gists': return AiGithubPlan('GET', '/gists', query: query);
      case 'organizations': return AiGithubPlan('GET', '/user/orgs', query: query);
    }
    final root = _repo(repo);
    final suffix = switch (action) {
      'repository' || 'repository_permissions' => '',
      'branches' => '/branches',
      'commits' => '/commits',
      'releases' => '/releases',
      'issue_comments' => '/issues/${_id(args, 'number')}/comments',
      'pull_files' => '/pulls/${_id(args, 'number')}/files',
      'collaborators' => '/collaborators',
      'labels' => '/labels',
      'milestones' => '/milestones',
      'workflow_runs' => '/actions/runs',
      'workflow_jobs' => '/actions/runs/${_id(args, 'run_id')}/jobs',
      'workflow_artifacts' => '/actions/runs/${_id(args, 'run_id')}/artifacts',
      _ => throw const AiException('unknownTool'),
    };
    return AiGithubPlan('GET', '$root$suffix', query: query);
  }

  /// 写参数逐操作过滤；不提供 Secrets/任意请求头/强推/组织管理接口。
  static AiGithubPlan write(Map<String, dynamic> args, String repo) {
    final action = _text(args, 'action');
    if (!writes.contains(action)) throw const AiException('unknownTool');
    final raw = args['body'] ?? <String, Object?>{};
    if (raw is! Map) throw const AiException('invalidProposal');
    final body = Map<String, Object?>.from(raw);
    Map<String, Object?> fields(List<String> allowed, [List<String> required = const []]) {
      if (body.keys.any((k) => !allowed.contains(k)) || required.any((k) => !body.containsKey(k) || body[k] == null)) {
        throw const AiException('invalidProposal');
      }
      return body;
    }
    if (action == 'create_repository') {
      final data = fields(['name', 'description', 'private', 'auto_init', 'gitignore_template', 'license_template'], ['name']);
      if (data['name'] is! String || !RegExp(r'^[A-Za-z0-9_.-]+$').hasMatch(data['name'] as String)) throw const AiException('invalidProposal');
      return AiGithubPlan('POST', '/user/repos', body: data);
    }
    if (action == 'mark_all_notifications_read') return AiGithubPlan('PUT', '/notifications', body: {'read': true, 'last_read_at': DateTime.now().toUtc().toIso8601String().split('.').first + 'Z'});
    if (action == 'mark_notification_read') return AiGithubPlan('PATCH', '/notifications/threads/${_id(args, 'number')}', body: {});
    if (action.endsWith('_gist')) {
      if (action != 'delete_gist') {
        fields(['description', 'public', 'files'], action == 'create_gist' ? ['files'] : []);
        final files = body['files'];
        if (files != null) {
          if (files is! Map || files.isEmpty || files.length > 30) throw const AiException('invalidProposal');
          for (final entry in files.entries) {
            final name = '${entry.key}'.toLowerCase();
            if (name.contains('/') || name.contains('\\') || name.startsWith('.env') || name.endsWith('.key') || name.endsWith('.pem') || name == 'credentials.json' || name == 'key.properties' || name.endsWith('.keystore')) throw const AiException('secretFile');
          }
        }
      }
      if (action == 'create_gist') return AiGithubPlan('POST', '/gists', body: body);
      final id = _text(args, 'gist_id');
      if (!RegExp(r'^[A-Fa-f0-9]+$').hasMatch(id)) throw const AiException('invalidProposal');
      return AiGithubPlan(action == 'delete_gist' ? 'DELETE' : 'PATCH', '/gists/$id', body: action == 'delete_gist' ? null : body);
    }
    final root = _repo(repo);
    switch (action) {
      case 'update_repository': return AiGithubPlan('PATCH', root, body: fields(['description', 'homepage', 'private', 'has_issues', 'has_projects', 'has_wiki', 'archived']));
      case 'delete_repository': return AiGithubPlan('DELETE', root);
      case 'fork_repository': return AiGithubPlan('POST', '$root/forks', body: fields(['organization', 'name', 'default_branch_only']));
      case 'star_repository': return AiGithubPlan('PUT', '/user/starred/$repo');
      case 'unstar_repository': return AiGithubPlan('DELETE', '/user/starred/$repo');
      case 'watch_repository': return AiGithubPlan('PUT', '$root/subscription', body: {'subscribed': true});
      case 'unwatch_repository': return AiGithubPlan('DELETE', '$root/subscription');
      case 'create_branch':
        fields(['branch', 'sha'], ['branch', 'sha']);
        final branch = '${body['branch']}';
        if (branch.isEmpty || branch.contains('..') || branch.contains(RegExp(r'[\s~^:?*\[\\]')) || branch.startsWith('/') || branch.endsWith('/')) throw const AiException('invalidProposal');
        if (!RegExp(r'^[a-fA-F0-9]{40}$').hasMatch('${body['sha']}')) throw const AiException('invalidProposal');
        return AiGithubPlan('POST', '$root/git/refs', body: {'ref': 'refs/heads/$branch', 'sha': body['sha']});
      case 'delete_branch': return AiGithubPlan('DELETE', '$root/git/refs/heads/${_segment(_text(args, 'branch'))}');
      case 'create_release': return AiGithubPlan('POST', '$root/releases', body: fields(['tag_name', 'target_commitish', 'name', 'body', 'draft', 'prerelease', 'generate_release_notes'], ['tag_name']));
      case 'update_release': return AiGithubPlan('PATCH', '$root/releases/${_id(args, 'number')}', body: fields(['tag_name', 'target_commitish', 'name', 'body', 'draft', 'prerelease']));
      case 'delete_release': return AiGithubPlan('DELETE', '$root/releases/${_id(args, 'number')}');
      case 'issue_comment': return AiGithubPlan('POST', '$root/issues/${_id(args, 'number')}/comments', body: fields(['body'], ['body']));
      case 'close_pull': return AiGithubPlan('PATCH', '$root/pulls/${_id(args, 'number')}', body: {'state': 'closed'});
      case 'merge_pull':
        fields(['sha', 'merge_method', 'commit_title', 'commit_message'], ['sha']);
        if (!RegExp(r'^[a-fA-F0-9]{40}$').hasMatch('${body['sha']}') || (body['merge_method'] != null && !['merge', 'squash', 'rebase'].contains(body['merge_method']))) throw const AiException('invalidProposal');
        return AiGithubPlan('PUT', '$root/pulls/${_id(args, 'number')}/merge', body: body);
      case 'rerun_workflow': return AiGithubPlan('POST', '$root/actions/runs/${_id(args, 'run_id')}/rerun', body: {});
      case 'cancel_workflow': return AiGithubPlan('POST', '$root/actions/runs/${_id(args, 'run_id')}/cancel', body: {});
      case 'add_collaborator': return AiGithubPlan('PUT', '$root/collaborators/${_segment(_text(args, 'username'))}', body: fields(['permission']));
      case 'remove_collaborator': return AiGithubPlan('DELETE', '$root/collaborators/${_segment(_text(args, 'username'))}');
      case 'create_label': return AiGithubPlan('POST', '$root/labels', body: fields(['name', 'color', 'description'], ['name', 'color']));
      case 'delete_label': return AiGithubPlan('DELETE', '$root/labels/${_segment(_text(args, 'name'))}');
      case 'create_milestone': return AiGithubPlan('POST', '$root/milestones', body: fields(['title', 'state', 'description', 'due_on'], ['title']));
      default: throw const AiException('unknownTool');
    }
  }
}
