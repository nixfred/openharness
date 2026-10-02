import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harness_mobile/phone/device_detail_page.dart';
import 'package:harness_mobile/phone/devices_page.dart';
import 'package:harness_mobile/phone/phone_shell.dart';

import 'devices_fixture.dart';

/// A tapped "new device" notice opens that device's page: as new while it is still news, plain once
/// it is only on the list, and the list when the account no longer holds it.
void main() {
  late DevicesApp app;
  final at = DateTime(2026, 9, 30, 8).millisecondsSinceEpoch;

  setUp(() => app = DevicesApp());
  tearDown(() => app.dispose());

  Future<void> pumpShell(WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(home: PhoneShell(notifier: app)));
    await tester.pump();
  }

  Future<void> tapNotice(WidgetTester tester, String pub) async {
    app.agentNotices.system.openedDevice.value = pub;
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
  }

  testWidgets('a device still news opens as new, and the tap is consumed', (
    tester,
  ) async {
    final m = member(pubOf(3), label: 'iPad', addedAt: at);
    app.newDevices.add(m);
    await pumpShell(tester);

    await tapNotice(tester, m.pub);

    final page = tester.widget<DeviceDetailPage>(find.byType(DeviceDetailPage));
    expect(page.row.member.pub, m.pub);
    expect(page.isNew, isTrue);
    expect(find.text(fpOf(m.pub)), findsOneWidget);
    expect(app.agentNotices.system.openedDevice.value, isNull);
  });

  testWidgets('a tap that launched the app still opens the device', (
    tester,
  ) async {
    // The launch tap is read before the shell exists, so no listener sees it change.
    final m = member(pubOf(5), label: 'iPad', addedAt: at);
    app.newDevices.add(m);
    app.agentNotices.system.openedDevice.value = m.pub;
    await pumpShell(tester);
    await tester.pump(const Duration(seconds: 1));

    final page = tester.widget<DeviceDetailPage>(find.byType(DeviceDetailPage));
    expect(page.row.member.pub, m.pub);
    expect(app.agentNotices.system.openedDevice.value, isNull);
  });

  testWidgets('a device only on the list opens plain', (tester) async {
    final m = member(pubOf(4), label: 'Pixel', addedAt: at);
    app.rows = [row(m)];
    await pumpShell(tester);

    await tapNotice(tester, m.pub);

    final page = tester.widget<DeviceDetailPage>(find.byType(DeviceDetailPage));
    expect(page.row.member.pub, m.pub);
    expect(page.isNew, isFalse);
  });

  testWidgets('a device the account no longer holds opens the list', (
    tester,
  ) async {
    await pumpShell(tester);

    await tapNotice(tester, pubOf(5));

    expect(find.byType(DeviceDetailPage), findsNothing);
    expect(find.byType(DevicesPage), findsOneWidget);
  });
}
