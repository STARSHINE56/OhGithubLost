import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:ohgithublost/base/disk/disk_store.dart';
import 'package:ohgithublost/domain/ai/ai_models.dart';
import 'package:ohgithublost/domain/productivity/productivity_service.dart';

void main() {
  test(
    'bulk read uses one authenticated request with a cutoff for all pages',
    () async {
      final calls = <String>[];
      final service = ProductivityService(
        store: InMemoryKv(),
        account: () async => 'alice',
        github: (_, __, ___, ____) async => throw StateError('unbound request'),
        notificationGithub: (account, method, path, body, query) async {
          calls.add('$account $method $path');
          final data = body!;
          expect(data['read'], isTrue);
          final cutoff = DateTime.parse(data['last_read_at'] as String);
          expect(cutoff.isUtc, isTrue);
          expect(
            DateTime.now().toUtc().difference(cutoff).inSeconds,
            lessThan(3),
          );
          expect(query, isEmpty);
          return {'message': 'Accepted for background processing'};
        },
      );
      await service.markAllNotificationsRead();
      expect(calls, ['alice PUT /notifications']);
    },
  );

  test('bulk failure remains visible to the caller', () async {
    final service = ProductivityService(
      store: InMemoryKv(),
      account: () async => 'alice',
      github: (_, __, ___, ____) async => throw StateError('403'),
    );
    await expectLater(service.markAllNotificationsRead(), throwsStateError);
  });

  test('no account does not send a bulk write', () async {
    var calls = 0;
    final service = ProductivityService(
      store: InMemoryKv(),
      account: () async => null,
      github: (_, __, ___, ____) async {
        calls++;
        return {};
      },
    );
    await expectLater(
      service.markAllNotificationsRead(),
      throwsA(isA<AiException>()),
    );
    expect(calls, 0);
  });

  test('switching accounts rejects a delayed bulk result', () async {
    var active = 'alice';
    final result = Completer<Object?>();
    final sent = Completer<void>();
    final service = ProductivityService(
      store: InMemoryKv(),
      account: () async => active,
      github: (_, __, ___, ____) async => throw StateError('unbound request'),
      notificationGithub: (account, method, path, body, query) {
        expect(account, 'alice');
        sent.complete();
        return result.future;
      },
    );
    final operation = service.markAllNotificationsRead();
    final assertion = expectLater(operation, throwsA(isA<AiException>()));
    await sent.future;
    active = 'bob';
    result.complete({});
    await assertion;
  });
}
