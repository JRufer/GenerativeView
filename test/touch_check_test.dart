import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:generativeview/src/ui/touch_check.dart';

void main() {
  testWidgets('the touch check reports a held press as a long press, and a quick one as a tap', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: TouchCheckPage()));
    final pad = find.text('Press and hold here');

    await tester.longPress(pad);
    await tester.pumpAndSettle();
    expect(find.textContaining('LONG PRESS'), findsOneWidget);
    expect(find.textContaining('Press 1: touch, lifted'), findsOneWidget);

    await tester.tap(pad);
    await tester.pumpAndSettle(const Duration(milliseconds: 400));
    expect(find.textContaining('Press 2: touch, lifted'), findsOneWidget);
    expect(find.textContaining('tap at'), findsOneWidget);
    expect(find.textContaining('Pad built afresh: 1 time(s)'), findsOneWidget);
  });
}
