/// 加密会话按条存储；串行更新索引，兼容旧版整账号 JSON。
library;

import 'dart:async';
import 'dart:convert';

import '../../kernel/contract/disk_store.dart';
import 'ai_models.dart';

class AiConversationStore {
  AiConversationStore(this.vault);
  final DiskVault vault;
  Future<void> _tail = Future<void>.value();

  /// 上一个任务失败不能阻塞后续任务；同实例读/写/迁移互不交错。
  Future<T> _serial<T>(Future<T> Function() action) {
    final result = _tail.then((_) => action());
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return result;
  }

  String _indexKey(String user) => 'ai.chat-index.$user';
  String _chatKey(String user, String id) =>
      'ai.chat.$user.${Uri.encodeComponent(id)}';

  Future<List<String>> _index(String user) async {
    final raw = await vault.readSecret(_indexKey(user));
    if (raw != null) return (jsonDecode(raw) as List).cast<String>();
    final legacy = await vault.readSecret('ai.chats.$user');
    final chats = legacy == null
        ? <AiConversation>[]
        : (jsonDecode(legacy) as List).map((e) => AiConversation.fromJson(
            Map<String, dynamic>.from(e as Map))).toList();
    final ids = <String>[];
    for (final chat in chats) {
      if (chat.accountId != user) throw const AiException('accountChanged');
      await vault.writeSecret(_chatKey(user, chat.id), jsonEncode(chat.toJson()));
      if (!ids.contains(chat.id)) ids.add(chat.id);
    }
    // 索引最后发布；任何迁移写入失败时，旧数据仍可重试，不丢历史。
    await vault.writeSecret(_indexKey(user), jsonEncode(ids));
    // 新索引提交后才清旧数据，避免删除会话后旧快照仍保留私有内容。
    await vault.deleteSecret('ai.chats.$user');
    return ids;
  }

  Future<List<AiConversation>> list(String user) => _serial(() async {
    final ids = await _index(user);
    final result = <AiConversation>[];
    for (final id in ids) {
      final raw = await vault.readSecret(_chatKey(user, id));
      if (raw == null) throw const AiException('invalidResponse');
      final chat = AiConversation.fromJson(Map<String, dynamic>.from(
          jsonDecode(raw) as Map));
      if (chat.accountId != user) throw const AiException('accountChanged');
      result.add(chat);
    }
    return result;
  });

  Future<void> save(AiConversation chat) {
    // 进入队列前固定快照，等待期间的 UI 修改不能污染待写入内容。
    final encoded = jsonEncode(chat.toJson());
    return _serial(() async {
      final ids = await _index(chat.accountId);
      await vault.writeSecret(_chatKey(chat.accountId, chat.id), encoded);
      final updated = <String>[chat.id, ...ids.where((id) => id != chat.id)];
      await vault.writeSecret(_indexKey(chat.accountId), jsonEncode(updated));
    });
  }

  Future<void> delete(String user, String id) => _serial(() async {
    final ids = await _index(user);
    await vault.writeSecret(_indexKey(user),
        jsonEncode(ids.where((value) => value != id).toList()));
    await vault.deleteSecret(_chatKey(user, id));
  });
}
