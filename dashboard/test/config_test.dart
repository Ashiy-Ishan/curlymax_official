import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:curlymax_dashboard/main.dart';

void main() {
  test(
    'Startup distinguishes missing settings from invalid or privileged settings',
    () {
      expect(studioConfigurationError('', ''), contains('missing'));
      expect(
        studioConfigurationError(
          'http://example.com',
          'sb_publishable_example_public_key',
        ),
        contains('HTTPS'),
      );
      expect(
        studioConfigurationError(
          'https://example.supabase.co',
          'sb_secret_forbidden',
        ),
        contains('rejected'),
      );
      expect(
        studioConfigurationError(
          'https://example.supabase.co',
          'sb_publishable_example_public_key',
        ),
        isNull,
      );
    },
  );
  test('Studio accepts only HTTPS project origins', () {
    expect(isValidProjectUrl('https://example.supabase.co'), isTrue);
    for (final url in [
      'http://example.com',
      'https://user:pass@example.com',
      'https://example.com/api',
      'https://example.com?token=secret',
      'https://example.com/#fragment',
    ]) {
      expect(isValidProjectUrl(url), isFalse, reason: url);
    }
  });
  test('Studio rejects privileged or malformed configuration keys', () {
    String jwt(String role) =>
        'header.${base64Url.encode(utf8.encode(jsonEncode({'role': role})))}.signature';
    expect(isPublicKey(jwt('anon')), isTrue);
    expect(isPublicKey(jwt('service_role')), isFalse);
    expect(isPublicKey('sb_secret_example_secret'), isFalse);
    expect(isPublicKey('sb_publishable_'), isFalse);
    expect(isPublicKey('sb_publishable_example_public_key'), isTrue);
    expect(isPublicKey(jwt('anon').replaceAll('.signature', '')), isFalse);
  });
}
