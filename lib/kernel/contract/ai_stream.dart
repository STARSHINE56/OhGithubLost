/// 可取消 AI 网络契约；不取消已经送出的 GitHub 写操作。
library;

class AiRequestCancelled implements Exception {
  const AiRequestCancelled();
}

class AiCancellation {
  bool _cancelled = false;
  final Set<void Function()> _listeners = {};
  bool get isCancelled => _cancelled;
  void check() { if (_cancelled) throw const AiRequestCancelled(); }
  void add(void Function() listener) {
    if (_cancelled) { listener(); } else { _listeners.add(listener); }
  }
  void remove(void Function() listener) => _listeners.remove(listener);
  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    for (final listener in List<void Function()>.of(_listeners)) { listener(); }
    _listeners.clear();
  }
}

typedef AiEventStream = Future<void> Function(
  String url, Map<String, String> headers, Map<String, Object?> body,
  AiCancellation cancellation, void Function(Map<String, dynamic>) onEvent,
);
