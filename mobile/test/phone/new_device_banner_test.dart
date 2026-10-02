import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harness_mobile/phone/device_detail_page.dart';
import 'package:harness_mobile/phone/devices_page.dart';
import 'package:harness_mobile/phone/new_device_banner.dart';

import 'devices_fixture.dart';

/// "New device: X" — Review goes to that device when there is one, to the list when there are more.
void main() {
  late DevicesApp app;
  final nav = GlobalKey<NavigatorState>();

  setUp(() => app = DevicesApp());
  tearDown(() => app.dispose());

  Future<void> pump(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: nav,
        home: Scaffold(
          body: NewDeviceBanner(notifier: app, navigator: nav),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('one new device: Review opens its page, as new, with its whole '
      'code; the sentence has no code', (tester) async {
    final m = member(
      pubOf(7),
      label: 'iPad',
      addedAt: DateTime.now()
          .subtract(const Duration(hours: 1))
          .millisecondsSinceEpoch,
    );
    app.newDevices.add(m);
    await pump(tester);
    expect(find.text('New device: iPad'), findsOneWidget);
    expect(find.textContaining('·'), findsNothing);

    await tester.tap(find.text('Review'));
    await tester.pumpAndSettle();

    final page = tester.widget<DeviceDetailPage>(find.byType(DeviceDetailPage));
    expect(page.row.member.pub, m.pub);
    expect(page.isNew, isTrue);
    expect(find.text(fpOf(m.pub)), findsOneWidget);
    expect(find.text('Added'), findsOneWidget);
    expect(find.byKey(const Key('device-detail-mine')), findsOneWidget);
    expect(find.byType(DevicesPage), findsNothing);
  });

  testWidgets('two new devices: Review opens the list, the newest on top', (
    tester,
  ) async {
    final now = DateTime.now();
    final older = member(
      pubOf(7),
      label: 'iPad',
      addedAt: now.subtract(const Duration(hours: 5)).millisecondsSinceEpoch,
    );
    final newer = member(
      pubOf(8),
      label: 'Pixel',
      addedAt: now.subtract(const Duration(hours: 1)).millisecondsSinceEpoch,
    );
    app
      ..rows = [row(older), row(newer)]
      ..newDevices.addAll([older, newer]);
    await pump(tester);
    expect(find.text('New device: iPad +1'), findsOneWidget);

    await tester.tap(find.text('Review'));
    await tester.pumpAndSettle();

    expect(find.byType(DevicesPage), findsOneWidget);
    expect(find.byType(DeviceDetailPage), findsNothing);
    final newerTop = tester.getTopLeft(
      find.byKey(ValueKey('account-device-${newer.pub}')),
    );
    final olderTop = tester.getTopLeft(
      find.byKey(ValueKey('account-device-${older.pub}')),
    );
    expect(newerTop.dy, lessThan(olderTop.dy));
  });
}
