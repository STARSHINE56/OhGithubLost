/// AI 的数据契约：只包含可序列化数据，不持有 GitHub 令牌。
library;

import 'dart:convert';

/// 两条网络通道都由装配根注入；业务层不依赖底座实现。
typedef AiGithubRequest = Future<Object?> Function(
  String method,
  String path,
  Map<String, Object?>? body,
  Map<String, String> query,
);

/// 将请求固定在发起会话的账号，避免并发排队期间切号串用凭据。
typedef AiGithubScopedRequest = Future<Object?> Function(
  String accountId,
  String method,
  String path,
  Map<String, Object?>? body,
  Map<String, String> query,
);
typedef AiProviderRequest = Future<Map<String, dynamic>> Function(
  AiSettings settings,
  String endpoint,
  String key,
  Map<String, Object?>? body,
);
typedef AiProviderStreamRequest = Future<Map<String, dynamic>> Function(
  AiSettings settings,
  String key,
  Map<String, Object?> body,
  void Function(String text) onText,
  AiCancellation cancellation,
);

/// 单次请求取消信号，同时中断传输和后续工具调度。
class AiCancellation {
  bool cancelled = false;
  void Function()? onCancel;
  void cancel() {
    cancelled = true;
    onCancel?.call();
  }

  void check() {
    if (cancelled) {
      throw const AiException('cancelled');
    }
  }
}

typedef AiConfirmation = Future<bool> Function(AiProposal proposal);

/// 可读的业务错误键由展示层翻译。
class AiException implements Exception {
  const AiException(this.code, [this.detail = '']);
  final String code;
  final String detail;
  @override
  String toString() => '$code${detail.isEmpty ? '' : ': $detail'}';
}

/// 仅保存非敏感配置；密钥单独写入系统保险库。
class AiSettings {
  const AiSettings({
    this.enabled = false,
    this.model = '',
    this.kind = 'openai',
    this.baseUrl = 'https://api.deepseek.com',
    this.optimization = 'balanced',
    this.optimize = true,
    this.automaticBudget = true,
    this.contextTokens = 16000,
    this.taskBudget = 48000,
    this.outputTokens = 4096,
    this.tools = true,
    this.streaming = true,
    this.autoSummary = true,
    this.cache = true,
    this.autoScroll = true,
    this.fontSize = 16,
    this.toolMode = 'all',
    this.outputParameter = 'auto',
    this.inputPrice = 0,
    this.outputPrice = 0,
    this.structured = false,
    this.reasoningEffort = '',
    this.defaultRepo = '',
    this.autoRepository = true,
  });
  final bool enabled;
  final String model;
  final String kind;
  final String baseUrl;
  final String optimization,
      toolMode,
      outputParameter,
      reasoningEffort,
      defaultRepo;
  final bool optimize,
      automaticBudget,
      tools,
      streaming,
      autoSummary,
      cache,
      autoScroll,
      structured,
      autoRepository;
  final int contextTokens, taskBudget, outputTokens;
  final double fontSize, inputPrice, outputPrice;
  String get capabilityId => '$keyId.${Uri.encodeComponent(model)}';
  String get keyId => 'ai.key.$kind.${Uri.encodeComponent(baseUrl)}';
  Map<String, Object?> toJson() => {
        'enabled': enabled,
        'model': model,
        'kind': kind,
        'baseUrl': baseUrl,
        'optimization': optimization,
        'optimize': optimize,
        'automaticBudget': automaticBudget,
        'contextTokens': contextTokens,
        'taskBudget': taskBudget,
        'outputTokens': outputTokens,
        'tools': tools,
        'streaming': streaming,
        'autoSummary': autoSummary,
        'cache': cache,
        'autoScroll': autoScroll,
        'fontSize': fontSize,
        'toolMode': toolMode,
        'outputParameter': outputParameter,
        'inputPrice': inputPrice,
        'outputPrice': outputPrice,
        'structured': structured,
        'reasoningEffort': reasoningEffort,
        'defaultRepo': defaultRepo,
        'autoRepository': autoRepository,
      };
  factory AiSettings.fromJson(Map<String, dynamic> json) => AiSettings(
        enabled: json['enabled'] == true,
        model: json['model'] as String? ?? '',
        kind: json['kind'] as String? ?? 'openai',
        baseUrl: json['baseUrl'] as String? ?? 'https://api.deepseek.com',
        optimization: json['optimization'] as String? ?? 'balanced',
        optimize: json['optimize'] != false,
        automaticBudget: json['automaticBudget'] != false,
        tools: json['tools'] != false,
        streaming: json['streaming'] != false,
        autoSummary: json['autoSummary'] != false,
        cache: json['cache'] != false,
        autoScroll: json['autoScroll'] != false,
        autoRepository: json['autoRepository'] != false,
        contextTokens:
            ((json['contextTokens'] as num?)?.toInt() ?? 16000).clamp(
          1024,
          2000000,
        ),
        taskBudget: ((json['taskBudget'] as num?)?.toInt() ?? 48000).clamp(
          1024,
          4000000,
        ),
        outputTokens: ((json['outputTokens'] as num?)?.toInt() ?? 4096).clamp(
          128,
          128000,
        ),
        fontSize: ((json['fontSize'] as num?)?.toDouble() ?? 16).clamp(12, 28),
        inputPrice: (json['inputPrice'] as num?)?.toDouble() ?? 0,
        outputPrice: (json['outputPrice'] as num?)?.toDouble() ?? 0,
        toolMode: json['toolMode'] as String? ?? 'all',
        outputParameter: json['outputParameter'] as String? ?? 'auto',
        structured: json['structured'] == true,
        reasoningEffort: json['reasoningEffort'] as String? ?? '',
        defaultRepo: json['defaultRepo'] as String? ?? '',
      );
}

/// 一条聊天消息；附件只保存 GitHub 产物 ID，不保存短期签名地址。
class AiMessage {
  AiMessage(
    this.role,
    this.content, {
    DateTime? at,
    this.artifacts = const [],
    this.notice = false,
  }) : at = at ?? DateTime.now();
  final bool notice;
  final String role;
  final String content;
  final DateTime at;
  final List<Map<String, dynamic>> artifacts;
  Map<String, Object?> toJson() => {
        'role': role,
        'content': content,
        'at': at.toIso8601String(),
        'artifacts': artifacts,
        'notice': notice,
      };
  factory AiMessage.fromJson(Map<String, dynamic> json) => AiMessage(
        json['role'] as String,
        json['content'] as String,
        at: DateTime.parse(json['at'] as String),
        notice: json['notice'] == true,
        artifacts: (json['artifacts'] as List? ?? [])
            .map((e) => Map<String, dynamic>.from(e as Map))
            .toList(),
      );
}

/// 会话按 GitHub 账号隔离，每个会话持有独立仓库上下文。
class AiConversation {
  AiConversation({
    required this.id,
    required this.accountId,
    this.repo = '',
    this.branch = '',
    this.title = '',
    this.summary = '',
    Map<String, dynamic>? usage,
    List<AiMessage>? messages,
  })  : messages = messages ?? [],
        usage = usage ?? {};
  final String id;
  final String accountId;
  String repo;
  String branch;
  final List<AiMessage> messages;
  String title, summary;
  final Map<String, dynamic> usage;
  String get displayTitle =>
      title.isNotEmpty ? title : messages.firstOrNull?.content ?? '';

  Map<String, Object?> toJson() => {
        'id': id,
        'accountId': accountId,
        'repo': repo,
        'branch': branch,
        'title': title,
        'summary': summary,
        'usage': usage,
        'messages': messages.map((e) => e.toJson()).toList(),
      };
  factory AiConversation.fromJson(Map<String, dynamic> json) => AiConversation(
        id: json['id'] as String,
        accountId: json['accountId'] as String,
        repo: json['repo'] as String? ?? '',
        branch: json['branch'] as String? ?? '',
        title: json['title'] as String? ?? '',
        summary: json['summary'] as String? ?? '',
        usage: Map<String, dynamic>.from(json['usage'] as Map? ?? {}),
        messages: (json['messages'] as List)
            .map((e) => AiMessage.fromJson(Map<String, dynamic>.from(e as Map)))
            .toList(),
      );
}

/// 文件差异是不可变快照，确认之后不会再次读取模型生成的内容。
class AiFileChange {
  const AiFileChange({
    required this.path,
    required this.before,
    required this.after,
    this.mode = '100644',
  });
  final String path;
  final String? before;
  final String? after;
  final String mode;
  Map<String, Object?> toJson() => {
        'path': path,
        'before': before,
        'after': after,
        'mode': mode,
      };
}

/// 所有写操作共用确认对象，固定账号、仓库、分支和远端基线。
class AiProposal {
  AiProposal({
    required this.operation,
    required this.accountId,
    required this.repo,
    required this.branch,
    required this.payload,
    this.conversationId = '',
    this.baseSha = '',
    this.baseTree = '',
    List<AiFileChange> files = const [],
  })  : files = List.unmodifiable(files),
        payloadJson = jsonEncode(payload);
  final String conversationId;
  final String operation;
  final String accountId;
  final String repo;
  final String branch;
  final String baseSha;
  final String baseTree;
  final Map<String, Object?> payload;
  final String payloadJson;
  final List<AiFileChange> files;
}
