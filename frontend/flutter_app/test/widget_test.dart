import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_app/main.dart';

void main() {
  testWidgets('app boots', (WidgetTester tester) async {
    await tester.pumpWidget(const FlowgnimagApp());

    expect(find.byType(FlowgnimagApp), findsOneWidget);
  });
}
