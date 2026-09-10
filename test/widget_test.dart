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

  test('firmware version parser accepts official formats', () {
    expect(parseFirmwareVersion('V2.19'), [2, 19]);
    expect(parseFirmwareVersion('v3'), [3, 0]);
    expect(parseFirmwareVersion('  V10.4 '), [10, 4]);
    expect(parseFirmwareVersion('2.19'), isNull);
    expect(parseFirmwareVersion('V2.1.3'), isNull);
  });

  test('firmware comparison is numeric and release-safe', () {
    expect(isNewerFirmwareVersion('V2.20', 'V2.19'), isTrue);
    expect(isNewerFirmwareVersion('V3.0', 'V2.99'), isTrue);
    expect(isNewerFirmwareVersion('V2.19', 'V2.20'), isFalse);
    expect(isNewerFirmwareVersion('invalid', 'V2.19'), isFalse);
  });
}
