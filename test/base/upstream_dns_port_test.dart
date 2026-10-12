import 'package:flutter_test/flutter_test.dart';
import 'package:ohgithublost/base/net/net_dns.dart';

void main() {
  test('DoH endpoint only accepts absolute HTTPS hosts', () {
    expect(ogLIsUsableDohEndpoint('https://dns.google/dns-query'), isTrue);
    for (final value in [null, '', 'http://dns.google/dns-query', 'dns.google', 'https://']) {
      expect(ogLIsUsableDohEndpoint(value), isFalse);
    }
  });

  test('DNS input normalization preserves IPv4 and IPv6 literals', () {
    expect(ogLNormalizeDnsAddress(' https://1.1.1.1/dns-query '), '1.1.1.1');
    expect(ogLNormalizeDnsAddress('1.1.1.1:53'), '1.1.1.1');
    expect(ogLNormalizeDnsAddress('[2606:4700::1111]:53'), '2606:4700::1111');
    expect(ogLNormalizeDnsAddress('not-an-ip'), isNull);
  });

  test('changing DNS selection invalidates cache but identical selection does not', () {
    final service = DnsService();
    expect(service.applySelection(custom: true, serverId: 'cloudflare', preferDoh: true), isTrue);
    expect(service.applySelection(custom: true, serverId: 'cloudflare', preferDoh: true), isFalse);
    expect(service.applySelection(custom: true, serverId: 'google', preferDoh: true), isTrue);
    expect(service.policy.servers.single.id, 'google');
    expect(service.applySelection(custom: true, serverId: 'google', preferDoh: false), isTrue);
  });
}
