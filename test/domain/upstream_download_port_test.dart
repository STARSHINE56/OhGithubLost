import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:ohgithublost/domain/ix/ix_download.dart';

class DelayedBackend implements IxDownloadBackend {
  final path = Completer<String>();
  final controller = StreamController<IxDownloadEvent>.broadcast();
  int enqueued = 0;
  @override
  Stream<IxDownloadEvent> get events => controller.stream;
  @override
  bool get canReadLocalFile => false;
  @override
  bool get supportsRanged => false;
  @override
  bool get supportsPauseResume => false;
  @override
  Future<String> pathFor(IxDownloadSpec spec) => path.future;
  @override
  Future<void> enqueue(IxDownloadSpec spec) async { enqueued++; }
  @override
  Future<void> cancel(String id) async {}
  @override
  Future<void> pause(String id) async {}
  @override
  Future<void> resume(String id) async {}
  @override
  Future<int?> completedSize(String id, {String? path}) async => null;
  @override
  Future<String?> fileSha256(String id, {String? path}) async => null;
  @override
  Future<void> deleteFile(String id, {String? path}) async {}
  @override
  void dispose() { unawaited(controller.close()); }
}

void main() {
  test('new download is registered before path resolves and really enters backend', () async {
    final backend = DelayedBackend();
    final manager = IxDownloadManager(backend: backend);
    final operation = manager.enqueue(url: 'https://example.com/a.apk', fileName: 'a.apk', category: IxDownloadCategory.release);
    expect(manager.tasks.length, 1);
    backend.path.complete('/tmp/a.apk');
    final task = await operation;
    expect(task.id, manager.tasks.single.id);
    expect(backend.enqueued, 1);
    expect(manager.tasks.single.savePath, '/tmp/a.apk');
    manager.dispose();
  });

  test('disposing manager while path resolves cannot revive or enqueue task', () async {
    final backend = DelayedBackend();
    final manager = IxDownloadManager(backend: backend);
    final operation = manager.enqueue(url: 'https://example.com/a.apk', fileName: 'a.apk', category: IxDownloadCategory.release);
    manager.dispose();
    backend.path.complete('/tmp/a.apk');
    await operation;
    expect(backend.enqueued, 0);
  });
}
