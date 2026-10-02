import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harness_mobile/phone/device_detail_page.dart';
import 'package:harness_mobile/phone/devices_page.dart';
import 'package:harness_mobile/phone/settings_row.dart';

import 'devices_fixture.dart';

/// Settings ▸ Your devices on the phone: this phone's own code on a card, then the other devices —
/// new ones on top — with no key code in a row unless two rows share a name.
void main() {
  final fullCode = RegExp(r'[0-9A-F]{4}·[0-9A-F]{4}');
  int ago(Duration d) => DateTime.now().subtract(d).millisecondsSinceEpoch;

  late DevicesApp app;
  late String selfPub, oldPub, newPub, twinPub;

  setUp(() {
    selfPub = pubOf(0);
    oldPub = pubOf(1);
    newPub = pubOf(2);
    twinPub = pubOf(3);
    app = DevicesApp(
      rows: [
        row(
          member(
            selfPub,
            label: 'My iPhone',
            addedAt: ago(const Duration(days: 200)),
          ),
          self: true,
        ),
        row(
          member(
            oldPub,
            label: 'mbp',
            kind: 'machine',
            machineId: 'abcdef1234',
            addedAt: ago(const Duration(days: 100)),
          ),
        ),
        row(
          member(newPub, label: 'iPad', addedAt: ago(const Duration(days: 30))),
        ),
        // Shares this phone's name: its row has to say which one it is.
        row(
          member(
            twinPub,
            label: 'My iPhone',
            addedAt: ago(const Duration(days: 150)),
          ),
        ),
      ],
      seen: {
        oldPub: ago(const Duration(minutes: 2)),
        twinPub: ago(const Duration(days: 3)),
      },
    );
    app.newDevices.add(app.rows[2].member);
  });

  tearDown(() => app.dispose());

  Future<void> pump(WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(home: DevicesPage(notifier: app)));
    await tester.pumpAndSettle();
  }

  List<String> rowOrder(WidgetTester tester) => [
    for (final r in tester.widgetList<SettingsRow>(
      find.byWidgetPredicate(
        (w) =>
            w is SettingsRow &&
            w.key is ValueKey<String> &&
            (w.key! as ValueKey<String>).value.startsWith('account-device-'),
      ),
    ))
      (r.key! as ValueKey<String>).value.substring('account-device-'.length),
  ];

  SettingsRow rowFor(WidgetTester tester, String pub) =>
      tester.widget<SettingsRow>(find.byKey(ValueKey('account-device-$pub')));

  testWidgets('this phone is a card with its whole code, copyable, and is not '
      'listed again', (tester) async {
    await pump(tester);
    final card = find.byKey(const Key('account-device-this'));
    expect(card, findsOneWidget);
    expect(
      find.descendant(of: card, matching: find.text('This device · My iPhone')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: card, matching: find.text(fpOf(selfPub))),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: card,
        matching: find.text(
          'This is the code your other devices show for this device.',
        ),
      ),
      findsOneWidget,
    );
    expect(find.byKey(const Key('this-device-copy')), findsOneWidget);
    expect(find.byKey(ValueKey('account-device-$selfPub')), findsNothing);
  });

  testWidgets('no row holds a whole key code; a shared name shows only the '
      'first group', (tester) async {
    await pump(tester);
    for (final pub in [oldPub, newPub, twinPub]) {
      final r = rowFor(tester, pub);
      expect(r.title, isNot(contains(fullCode)));
      expect(r.detail, isNot(contains(fullCode)));
      expect(r.detail, isNot(contains(RegExp(r'\d{4}-\d{2}-\d{2}'))));
    }
    expect(rowFor(tester, oldPub).detail, 'Computer · active now');
    expect(rowFor(tester, newPub).detail, 'App · added 4 weeks ago');
    expect(
      rowFor(tester, twinPub).detail,
      'App · last active 3 days ago · ${fpOf(twinPub).split('·').first}…',
    );
  });

  testWidgets('a new device is on top with New; the rest follow by activity', (
    tester,
  ) async {
    await pump(tester);
    expect(rowOrder(tester), [newPub, oldPub, twinPub]);
    expect(rowFor(tester, newPub).value, 'New');
    expect(rowFor(tester, oldPub).value, isNull);
    expect(rowFor(tester, twinPub).value, isNull);
  });

  testWidgets(
    'opening the list clears the banner, yet New stays for this visit',
    (tester) async {
      expect(app.newDevices, hasLength(1));
      await pump(tester);
      expect(app.newDevices, isEmpty);
      expect(rowFor(tester, newPub).value, 'New');
      expect(rowOrder(tester).first, newPub);
    },
  );

  testWidgets(
    'tapping a row opens that device, Remove lives there, and It’s mine '
    'clears its New',
    (tester) async {
      await pump(tester);
      expect(find.text('Remove'), findsNothing, reason: 'no Remove on a row');

      await tester.tap(find.byKey(ValueKey('account-device-$newPub')));
      await tester.pumpAndSettle();
      final page = tester.widget<DeviceDetailPage>(
        find.byType(DeviceDetailPage),
      );
      expect(page.row.member.pub, newPub);
      expect(page.isNew, isTrue);
      expect(find.text(fpOf(newPub)), findsOneWidget);
      expect(find.byKey(const Key('device-detail-remove')), findsOneWidget);

      await tester.tap(find.byKey(const Key('device-detail-mine')));
      await tester.pumpAndSettle();
      expect(find.byType(DeviceDetailPage), findsNothing);
      expect(rowFor(tester, newPub).value, isNull);
    },
  );

  testWidgets('a device opened and closed without a choice keeps its New', (
    tester,
  ) async {
    await pump(tester);
    await tester.tap(find.byKey(ValueKey('account-device-$newPub')));
    await tester.pumpAndSettle();
    Navigator.of(tester.element(find.byType(DeviceDetailPage))).pop();
    await tester.pumpAndSettle();
    expect(rowFor(tester, newPub).value, 'New');
  });

  testWidgets('a device removed from its page leaves the list', (tester) async {
    await pump(tester);
    await tester.tap(find.byKey(ValueKey('account-device-$oldPub')));
    await tester.pumpAndSettle();
    final page = tester.widget<DeviceDetailPage>(find.byType(DeviceDetailPage));
    expect(page.isNew, isFalse);
    expect(page.lastSeen, app.seen[oldPub]);
    await tester.tap(find.byKey(const Key('device-detail-remove')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Remove'));
    await tester.pumpAndSettle();

    expect(app.removed, [oldPub]);
    expect(find.byType(DeviceDetailPage), findsNothing);
    expect(find.byKey(ValueKey('account-device-$oldPub')), findsNothing);
  });

  testWidgets('no row for this phone: no card', (tester) async {
    app.rows = app.rows.where((r) => !r.self).toList();
    await pump(tester);
    expect(find.byKey(const Key('account-device-this')), findsNothing);
    expect(rowOrder(tester), hasLength(3));
  });
}
