import 'package:flutter_test/flutter_test.dart';
import 'package:ohgithublost/surface/i18n/og_l_i18n.dart';
import 'package:ohgithublost/surface/pages/ai_settings_page.dart';
import 'package:ohgithublost/surface/types.dart';

void main() {
  setUp(() => OgLI18n.instance.debugInject('en', {'ai': {
    'aiHttpFailure': 'Service rejected request', 'aiTimeout': 'Timed out',
    'aiMalformedResponse': 'Invalid response', 'requestFailed': 'Generic error',
  }}));
  test('HTTP error exposes only safe status and never arbitrary detail', () {
    expect(aiError(const AiTransportFailure('aiHttpFailure', statusCode: 400)),
      'Service rejected request (HTTP 400)');
    expect(aiError(const AiTransportFailure('aiTimeout')), 'Timed out');
    expect(aiError(const AiException('aiMalformedResponse', 'secret response')),
      'Invalid response');
    expect(aiError(StateError('api_key=secret')), 'Generic error');
  });
}
