import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harness/auth/auth_session.dart';
import 'package:harness/core/config.dart';
import 'package:harness/settings/sections/account_devices_section.dart';
import 'package:harness/state/account_devices.dart';
import 'package:harness/shared/widgets/fingerprint_text.dart';
import 'package:harness/state/app_state.dart';

import 'support/devices_app.dart';

/// Settings ▸ Your devices: opening it is reviewing the devices the banner announced.
void main() {
  testWidgets('opening the devices list takes the new-device banner down', (tester) async {
    final app = AppNotifier(config: AppConfig.dev, authSession: AuthSession(), configStore: null);
    addTearDown(app.dispose);
    app.newDevices.add(const NewDeviceNotice(pub: 'p1', label: 'Test iPad', kind: 'viewer'));
    app.newDevices.add(const NewDeviceNotice(pub: 'p2', label: 'box9', kind: 'machine'));
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: AccountDevicesSection(notifier: app))));
    await tester.pump();
    expect(app.newDevices, isEmpty);
    // Let the list's read (no daemon in a test) run out before the tree goes.
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(minutes: 1));
  });
  group('the list', () {
    final now = DateTime.now();
    late FakeDevicesApp app;

    setUp(() {
      app = FakeDevicesApp()
        ..devices = AccountDevices(devices: [
          fakeDevice('old', label: 'Old laptop', kind: 'machine', added: now.subtract(const Duration(days: 300)),
              seen: now.subtract(const Duration(days: 40)), fingerprint: 'AAAA·0001·0001·0001'),
          fakeDevice('me', label: 'MacBook', kind: 'machine', self: true, added: now.subtract(const Duration(days: 200)),
              seen: now, fingerprint: 'E2FB·0DF5·5FD8·E6C7'),
          fakeDevice('phone-a', label: 'iPhone', added: now.subtract(const Duration(days: 100)),
              seen: now.subtract(const Duration(minutes: 2)), fingerprint: 'BBBB·0002·0002·0002'),
          fakeDevice('phone-b', label: 'iPhone', added: now.subtract(const Duration(days: 50)), fingerprint: 'CCCC·0003·0003·0003'),
          fakeDevice('twin', label: 'MacBook', added: now.subtract(const Duration(days: 30)),
              seen: now.subtract(const Duration(days: 3)), fingerprint: 'DDDD·0004·0004·0004'),
          fakeDevice('new', label: 'Test iPad', added: now.subtract(const Duration(hours: 3)), fingerprint: 'EEEE·0005·0005·0005'),
        ]);
      app.newDevices.add(const NewDeviceNotice(pub: 'new', label: 'Test iPad', kind: 'viewer'));
    });
    tearDown(() => app.dispose());

    Future<void> openList(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1200, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: AccountDevicesSection(notifier: app))));
      await tester.pump();
      await tester.pump();
    }

    String detailOf(WidgetTester tester, String pub) {
      final row = find.byKey(ValueKey('account-device-$pub'));
      return tester.widgetList<Text>(find.descendant(of: row, matching: find.byType(Text))).map((t) => t.data ?? '').join('\n');
    }

    testWidgets('this device is a card on top with its whole code, and is not a row again', (tester) async {
      await openList(tester);
      final card = find.byKey(const Key('account-device-this'));
      expect(card, findsOneWidget);
      expect(find.descendant(of: card, matching: find.text('MacBook')), findsOneWidget);
      expect(find.descendant(of: card, matching: find.text('This is the code your other devices show for this device.')), findsOneWidget);
      expect(find.descendant(of: card, matching: find.text('E2FB·0DF5·5FD8·E6C7')), findsOneWidget);
      expect(find.descendant(of: card, matching: find.byKey(const Key('this-device-copy'))), findsOneWidget);
      expect(find.byKey(const ValueKey('account-device-me')), findsNothing);
      expect(find.text('This device'), findsOneWidget);
    });

    testWidgets('rows: new first with a badge, then by activity; no whole code, the start of it only for a shared name', (tester) async {
      await openList(tester);
      double top(String pub) => tester.getTopLeft(find.byKey(ValueKey('account-device-$pub'))).dy;
      final order = ['new', 'phone-a', 'twin', 'old', 'phone-b'];
      for (var i = 1; i < order.length; i++) {
        expect(top(order[i - 1]), lessThan(top(order[i])), reason: '${order[i - 1]} above ${order[i]}');
      }
      expect(top('new'), greaterThan(tester.getTopLeft(find.byKey(const Key('account-device-this'))).dy));
      // Opening the list took the banner down, but this visit still shows which device was new.
      expect(app.newDevices, isEmpty);
      expect(find.descendant(of: find.byKey(const ValueKey('account-device-new')), matching: find.text('New')), findsOneWidget);
      expect(find.text('New'), findsOneWidget);

      expect(detailOf(tester, 'new'), contains('App · added 3 hours ago'));
      expect(detailOf(tester, 'phone-a'), contains('App · active now · BBBB…'));
      expect(detailOf(tester, 'phone-b'), contains('App · added 7 weeks ago · CCCC…'));
      // Shares its name with this device's card.
      expect(detailOf(tester, 'twin'), contains('App · last active 3 days ago · DDDD…'));
      expect(detailOf(tester, 'old'), contains('Computer · last active 5 weeks ago'));
      expect(detailOf(tester, 'old'), isNot(contains('AAAA')));
      expect(detailOf(tester, 'new'), isNot(contains('EEEE')));
      for (final pub in order) {
        expect(detailOf(tester, pub), isNot(matches(RegExp(r'[0-9A-F]{4}·[0-9A-F]{4}'))), reason: pub);
      }
      final everything = tester.widgetList<Text>(find.byType(Text)).map((t) => t.data ?? '').join('\n');
      expect(everything, isNot(matches(RegExp(r'\d{4}-\d{2}-\d{2}'))));
    });

    testWidgets('a row, or its Details button, opens that device with its whole code', (tester) async {
      await openList(tester);
      await tester.tap(find.descendant(of: find.byKey(const ValueKey('account-device-old')), matching: find.text('Old laptop')));
      await tester.pump();
      await tester.pump();
      expect(find.text('AAAA·0001·0001·0001'), findsOneWidget);
      expect(find.text(fingerprintHowToCompare(computer: true)), findsOneWidget);
      expect(find.byKey(const Key('device-detail-mine')), findsNothing);
      await tester.tap(find.byKey(const Key('device-detail-close')));
      await tester.pump();
      expect(find.text('AAAA·0001·0001·0001'), findsNothing);

      await tester.tap(find.byKey(const ValueKey('account-device-details-phone-b')));
      await tester.pump();
      await tester.pump();
      expect(find.text('CCCC·0003·0003·0003'), findsOneWidget);
      expect(find.text(fingerprintHowToCompare(computer: false)), findsOneWidget);
      expect(app.loads, 1, reason: 'the detail uses the row, it does not read the list again');
    });

    testWidgets('It’s mine in a new device’s detail takes its badge off; closing without it does not', (tester) async {
      await openList(tester);
      final badge = find.descendant(of: find.byKey(const ValueKey('account-device-new')), matching: find.text('New'));
      await tester.tap(find.byKey(const ValueKey('account-device-details-new')));
      await tester.pump();
      await tester.pump();
      await tester.tap(find.byKey(const Key('device-detail-close')));
      await tester.pump();
      expect(badge, findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('account-device-details-new')));
      await tester.pump();
      await tester.pump();
      await tester.tap(find.byKey(const Key('device-detail-mine')));
      await tester.pump();
      expect(find.text('EEEE·0005·0005·0005'), findsNothing);
      expect(badge, findsNothing);
    });

    testWidgets('Remove on a row still asks first, then takes the device out of the list', (tester) async {
      await openList(tester);
      await tester.tap(find.descendant(of: find.byKey(const ValueKey('account-device-old')), matching: find.text('Remove')));
      await tester.pump();
      expect(find.text('Remove Old laptop?'), findsOneWidget);
      await tester.tap(find.byKey(const Key('account-device-confirm')));
      await tester.pump();
      await tester.pump();
      await tester.pump();
      expect(app.removed, ['old']);
      expect(find.byKey(const ValueKey('account-device-old')), findsNothing);
    });
  });
}
