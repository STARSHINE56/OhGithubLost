/// AI 固定账号请求不能在网络排队或读取凭据期间串用新账号。
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:ohgithublost/base/net/net_bridge.dart';
import 'package:ohgithublost/base/net/net_transport.dart';
import 'package:ohgithublost/base/net/net_types.dart';
import 'package:ohgithublost/domain/gh/gh_auth.dart';
import 'package:ohgithublost/domain/gh/gh_client.dart';
import 'package:ohgithublost/kernel/contract/disk_store.dart';

class _GateTransport extends NetTransport {
  final started = Completer<void>(), release = Completer<void>();
  final requests = <NetRequest>[];
  @override
  Future<NetResponse> send(NetRequest request) async {
    requests.add(request);
    if (!started.isCompleted) {
      started.complete();
    }
    await release.future;
    return const NetResponse(
        statusCode: 200, body: '{}', duration: Duration.zero);
  }
}

class _SwitchingVault extends InMemoryVault {
  Future<void> Function(String)? beforeRead;
  @override
  Future<String?> readSecret(String key) async {
    await beforeRead?.call(key);
    return super.readSecret(key);
  }
}

Future<void> _accounts(GhAuthService auth) async {
  await auth.saveAccount(const GhAccount(id: 'alice', login: 'alice'),
      const GhToken('ghp_fake_alice'));
  await auth.saveAccount(
      const GhAccount(id: 'bob', login: 'bob'), const GhToken('ghp_fake_bob'));
  await auth.switchTo('alice');
}

void main() {
  test('Queued mutation is rejected after switching accounts', () async {
    final auth = GhAuthService(vault: InMemoryVault(), store: InMemoryKv());
    await _accounts(auth);
    final transport = _GateTransport();
    final client = GhClient(
        net: NetBridge(transport: transport, observer: NetObserver()),
        auth: auth,
        maxConcurrent: 1);
    final first =
        client.send(const GhRequest(path: '/user', expectedAccountId: 'alice'));
    await transport.started.future;
    final queued = expectLater(
        client.send(const GhRequest(
            path: '/repos/alice/repo/issues',
            method: NetMethod.post,
            body: {'title': 'test'},
            expectedAccountId: 'alice')),
        throwsA(isA<GhAuthException>()
            .having((e) => e.message, 'reason', 'accountChanged')));
    await auth.switchTo('bob');
    transport.release.complete();
    await first;
    await queued;
    expect(transport.requests.length, 1);
    expect(transport.requests.single.headers['authorization'],
        'Bearer ghp_fake_alice');
  });
  test('Switching during credential lookup prevents dispatch', () async {
    final store = InMemoryKv(), vault = _SwitchingVault();
    final auth = GhAuthService(vault: vault, store: store);
    await _accounts(auth);
    vault.beforeRead = (key) async {
      if (key == '${GhAuthService.secretPrefix}alice') {
        await store.write(GhAuthService.activeKey, 'bob');
      }
    };
    final transport = ScriptedTransport([]);
    final client = GhClient(
        net: NetBridge(transport: transport, observer: NetObserver()),
        auth: auth);
    await expectLater(
        client.send(const GhRequest(
            path: '/repos/alice/repo/issues',
            method: NetMethod.post,
            body: {'title': 'test'},
            expectedAccountId: 'alice')),
        throwsA(isA<GhAuthException>()));
    expect(transport.received, isEmpty);
  });
}
