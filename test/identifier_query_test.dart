import 'package:flutter_test/flutter_test.dart';
import 'package:userinfo/core/identifier_query.dart';

void main() {
  test('country formats and Persian/Arabic digits share indexed variants', () {
    final expected = IdentifierQuery('09120000001', mobile: true).values;
    for (final input in ['+989120000001', '989120000001', '00989120000001',
        '9120000001', '۰۹۱۲۰۰۰۰۰۰۱', '٠٩١٢٠٠٠٠٠٠١']) {
      final query = IdentifierQuery(input, mobile: true);
      expect(query.exact, isTrue);
      expect(query.values, expected);
    }
  });
  test('national zeroes survive and complete values use equality', () {
    final query = IdentifierQuery('۰۰۰۰۰۰۱۲۳۴', mobile: false);
    expect(query.values, ['0000001234']);
    expect(query.exact, isTrue);
    expect(query.predicate('national').$1, 'national IN (?)');
  });
  test('prefix is bounded and wildcards are rejected', () {
    expect(IdentifierQuery('0912000', mobile: true).exact, isFalse);
    for (final input in ['0912', '%912%', '091_000', '+', 'abc']) {
      expect(() => IdentifierQuery(input, mobile: true), throwsArgumentError);
    }
  });
}
