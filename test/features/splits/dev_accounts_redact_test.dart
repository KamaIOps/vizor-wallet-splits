// What the development import logs about the seed driver: never its token.
import 'package:flutter_test/flutter_test.dart';
import 'package:zcash_wallet/src/features/splits/dev_accounts_import.dart';

void main() {
  const url = 'http://127.0.0.1:39297/jxHpCKZhwLcdBj16bg0MI5R9Hr46Kpvp';
  const token = 'jxHpCKZhwLcdBj16bg0MI5R9Hr46Kpvp';

  test('a failed fetch names the request without the token', () {
    const line =
        'dev accounts: TAZ-4 failed: SeedDriverException: The seed driver did '
        'not answer: HttpException: 404 for $url/seed/3';
    final out = redactSeedDriverToken(line, url);
    expect(out, isNot(contains(token)));
    expect(out, contains('http://127.0.0.1:39297/<token>/seed/3'));
  });

  test('every occurrence is redacted, the bare origin line included', () {
    final out = redactSeedDriverToken(
      'no seed driver at $url; tried $url/health',
      url,
    );
    expect(out, isNot(contains(token)));
    expect('<token>'.allMatches(out), hasLength(2));
  });

  test('a line without the token is left as it is', () {
    const line = 'dev accounts: imported TAZ-1';
    expect(redactSeedDriverToken(line, url), line);
  });

  test('a driver URL with no path redacts nothing', () {
    const line = 'dev accounts: TAZ-1 failed: refused';
    expect(redactSeedDriverToken(line, 'http://127.0.0.1:39297'), line);
    expect(redactSeedDriverToken(line, 'http://127.0.0.1:39297/'), line);
    expect(redactSeedDriverToken(line, ''), line);
  });
}
