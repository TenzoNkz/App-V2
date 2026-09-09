import 'package:flutter_test/flutter_test.dart';
import 'package:horizoncooler/main.dart';

void main() {
  testWidgets('Horizon Cooler app renders the dashboard', (tester) async {
    await tester.pumpWidget(const HorizonCoolerApp());
    await tester.pump();

    expect(find.text('Horizon Cooler'), findsOneWidget);
    expect(find.text('Battery Temperature'), findsOneWidget);
    expect(find.text('Adaptive Mode'), findsWidgets);
  });
}
