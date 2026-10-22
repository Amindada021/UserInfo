import 'package:flutter_test/flutter_test.dart';
import 'package:userinfo/core/text_normalizer.dart';

void main() {
  test('Arabic and Persian spellings share the same search key', () {
    expect(TextNormalizer.normalize('علي  رضازاده'),
        TextNormalizer.normalize('علی رضازاده'));
    expect(TextNormalizer.normalize('كريم'), 'کریم');
  });
  test('normalizes digits and empty source markers', () {
    expect(TextNormalizer.normalize('۰۹١۲'), '0912');
    expect(TextNormalizer.cleaned('None'), isNull);
    expect(TextNormalizer.cleaned('  '), isNull);
  });
}
