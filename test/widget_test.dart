import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('displays Persian text in a right-to-left widget', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Directionality(
        textDirection: TextDirection.rtl,
        child: Scaffold(body: Center(child: Text('بانک ملی'))),
      ),
    ));
    expect(find.text('بانک ملی'), findsOneWidget);
  });
}
