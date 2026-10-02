// The band a new device raises across the window: one device goes straight to its key code, several
// go to Settings ▸ Your devices, where each is a row.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harness/settings/sections/account_devices_section.dart';
import 'package:harness/state/account_devices.dart' hide NewDeviceNotice;
import 'package:harness/state/account_devices.dart'
    as model
    show NewDeviceNotice;
import 'package:harness/widgets/new_device_notice.dart';

import 'support/devices_app.dart';

void main() {
  late FakeDevicesApp app;

  setUp(() => app = FakeDevicesApp());
  tearDown(() => app.dispose());

  Future<void> mount(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          // As the app shell draws it: rebuilt whenever the app changes.
          body: ListenableBuilder(
            listenable: app,
            builder: (context, _) => Column(
              children: [
                NewDeviceNotice(notifier: app),
                const Expanded(child: SizedBox()),
              ],
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('one new device: Review opens that device, offering It’s mine', (
    tester,
  ) async {
    app.newDevices.add(
      const model.NewDeviceNotice(
        pub: 'p1',
        label: 'Test iPad',
        kind: 'viewer',
        frameFingerprint: 'AAAA·BBBB·CCCC·DDDD',
      ),
    );
    app.devices = AccountDevices(
      devices: [
        fakeDevice(
          'p1',
          label: 'Test iPad',
          fingerprint: 'AAAA·BBBB·CCCC·DDDD',
        ),
      ],
    );
    await mount(tester);
    final review = find.byKey(const Key('new-device-review'));
    expect(
      find.descendant(of: review, matching: find.text('Review')),
      findsOneWidget,
    );
    // The banner's sentence carries no key code.
    expect(find.textContaining('AAAA'), findsNothing);
    await tester.tap(review);
    await tester.pump();
    await tester.pump();
    expect(find.text('AAAA·BBBB·CCCC·DDDD'), findsOneWidget);
    expect(find.byKey(const Key('device-detail-mine')), findsOneWidget);
    expect(find.byType(AccountDevicesSection), findsNothing);
    // It’s mine there is the banner's It’s mine.
    await tester.tap(find.byKey(const Key('device-detail-mine')));
    await tester.pump();
    expect(app.newDevices, isEmpty);
    expect(find.byKey(const Key('new-device-notice')), findsNothing);
  });

  testWidgets(
    'two new devices: Review devices opens the list, the new ones on top',
    (tester) async {
      final now = DateTime.now();
      app.newDevices
        ..add(
          const model.NewDeviceNotice(
            pub: 'p1',
            label: 'Test iPad',
            kind: 'viewer',
          ),
        )
        ..add(
          const model.NewDeviceNotice(
            pub: 'p2',
            label: 'box9',
            kind: 'machine',
          ),
        );
      app.devices = AccountDevices(
        devices: [
          fakeDevice(
            'old',
            label: 'Old phone',
            added: now.subtract(const Duration(days: 90)),
            seen: now,
          ),
          fakeDevice(
            'p1',
            label: 'Test iPad',
            added: now.subtract(const Duration(hours: 2)),
          ),
          fakeDevice(
            'p2',
            label: 'box9',
            kind: 'machine',
            added: now.subtract(const Duration(hours: 1)),
          ),
        ],
      );
      await mount(tester);
      expect(find.textContaining('(+1 more)'), findsOneWidget);
      final review = find.byKey(const Key('new-device-review'));
      expect(
        find.descendant(of: review, matching: find.text('Review devices')),
        findsOneWidget,
      );
      await tester.tap(review);
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.byType(AccountDevicesSection), findsOneWidget);
      double top(String pub) =>
          tester.getTopLeft(find.byKey(ValueKey('account-device-$pub'))).dy;
      expect(top('p2'), lessThan(top('p1')));
      expect(top('p1'), lessThan(top('old')));
      expect(find.text('New'), findsNWidgets(2));
      expect(app.newDevices, isEmpty);
    },
  );
}
