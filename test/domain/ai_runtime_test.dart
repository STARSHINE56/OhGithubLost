import 'package:flutter_test/flutter_test.dart';
import 'package:ohgithublost/domain/ai/ai_models.dart';
import 'package:ohgithublost/domain/ai/ai_service.dart';
import 'package:ohgithublost/kernel/contract/disk_store.dart';

void main() {
  test('model cache is isolated, refreshable, and invalidated by saved keys', () async {
    var requests = 0;
    final service = AiService(
      store: InMemoryKv(),
      vault: InMemoryVault(),
      github: (_, __, ___, ____) async => {},
      provider: (_, __, key, ___) async {
        requests++;
        return {'data': [{'id': 'model-$key'}]};
      },
      account: () async => 'alice',
    );
    const config = AiSettings(enabled: true);
    await service.saveSettings(config, key: 'one');
    final models = await service.detectModels(refresh: false);
    models.clear();
    expect(await service.detectModels(refresh: false), ['model-one']);
    expect(requests, 1);
    await service.detectModels();
    expect(requests, 2);
    expect(await service.detectModels(key: 'two', refresh: false), ['model-two']);
    expect(requests, 3);
    await service.saveSettings(config, key: 'three');
    expect(await service.detectModels(refresh: false), ['model-three']);
    expect(requests, 4);
  });

  test('failed model detection is never cached', () async {
    var requests = 0;
    final service = AiService(
      store: InMemoryKv(), vault: InMemoryVault(),
      github: (_, __, ___, ____) async => {},
      provider: (_, __, ___, ____) async {
        requests++;
        return {'data': []};
      },
      account: () async => 'alice',
    );
    await service.saveSettings(const AiSettings(), key: 'key');
    for (var i = 0; i < 2; i++) {
      await expectLater(service.detectModels(refresh: false), throwsA(isA<AiException>()));
    }
    expect(requests, 2);
  });

  test('confirmed mutation uses bound account channel, never unbound fallback', () async {
    var user = 'alice';
    var boundRequests = 0;
    final service = AiService(
      store: InMemoryKv(), vault: InMemoryVault(),
      github: (_, __, ___, ____) async => throw StateError('unbound request'),
      accountGithub: (id, method, path, body, query) async {
        expect(id, 'alice');
        expect(method, 'POST');
        expect(path, '/repos/owner/repo/issues');
        boundRequests++;
        return {'number': 1, 'state': 'open'};
      },
      provider: (_, __, ___, ____) async => {},
      account: () async => user,
    );
    final proposal = AiProposal(operation: 'create_issue', accountId: 'alice',
      repo: 'owner/repo', branch: 'main', payload: {'title': 'Issue'});
    await service.executeProposal(proposal, (_) async => true);
    expect(boundRequests, 1);
    await expectLater(service.executeProposal(proposal, (_) async {
      user = 'bob';
      return true;
    }), throwsA(isA<AiException>()));
    expect(boundRequests, 1);
  });
}
