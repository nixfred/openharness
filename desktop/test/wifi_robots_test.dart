// The Devices tab's robots paired over Wi-Fi: Add device ▸ Wi-Fi code pairs one with the six-character
// code it shows, and the tab lists what is paired with Revoke… beside each. These moved here from
// Settings ▸ Autonomous robots; the CLI behind them is faked, so nothing reaches a real network.
import 'dart:async';
import 'dart:ui' show SemanticsAction;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harness/autonomous_device/autonomous_device_cli.dart';
import 'package:harness/devices/device_settings.dart';
import 'package:harness/devices/devices_controller.dart';
import 'package:harness/devices/devices_screen.dart';
import 'package:harness/devices/wifi_robots.dart';
import 'package:harness/shared/widgets/app_icon_button.dart';
import 'package:harness/shared/widgets/app_select_field.dart';
import 'package:harness/shared/widgets/skeleton.dart';
import 'package:harness/state/dial_status.dart';

import 'devices_controller_test.dart' show deviceStatus, report;

class FakeAutonomousDeviceCli extends AutonomousDeviceCli {
  bool unsupported = false;
  int statusCalls = 0;
  Completer<void>? statusWait;
  Completer<void>? pairWait;
  String? pairFailure;
  bool networkBlocked = false;
  List<Map<String, dynamic>> discovered = [
    {'id': 'device-1', 'name': 'Kitchen', 'host': '192.0.2.2', 'port': 5000},
  ];
  List<Map<String, dynamic>> devices = [];
  final submissions = <Map<String, dynamic>>[];
  final revoked = <String>[];
  @override
  Future<Map<String, dynamic>> status() async {
    statusCalls++;
    if (statusWait != null) await statusWait!.future;
    if (unsupported) {
      throw const AutonomousDeviceCliException('NOT_FOUND', 'Unsupported CLI');
    }
    return {'transport': 'direct', 'connected': true, 'paired': devices.length};
  }

  @override
  Future<Map<String, dynamic>> list() async => {'devices': devices};
  @override
  Future<Map<String, dynamic>> discover() async {
    if (networkBlocked) {
      throw const AutonomousDeviceCliException(
        'LOCAL_NETWORK_BLOCKED',
        'Harness is not allowed to use the local network.',
      );
    }
    return {'devices': discovered};
  }

  @override
  Future<Map<String, dynamic>> pair({
    required String code,
    required String deviceId,
  }) async {
    submissions.add({'code': code, 'deviceId': deviceId});
    if (pairWait != null) await pairWait!.future;
    if (pairFailure != null) {
      throw AutonomousDeviceCliException('CODE_MISMATCH', pairFailure!);
    }
    // The real CLI persists the trust, so the next `list` is what reports it.
    devices.add({
      'id': 'fingerprint-$deviceId',
      'fingerprint': 'fingerprint-$deviceId',
      'label': 'Autonomous robot',
      'online': true,
    });
    return {
      'state': 'paired',
      'label': 'Autonomous robot',
      'fingerprint': 'fingerprint-$deviceId',
    };
  }

  @override
  Future<Map<String, dynamic>> revoke(String id) async {
    revoked.add(id);
    devices.removeWhere((device) => device['id'] == id);
    return {'revoked': 1};
  }
}

void main() {
  final codeField = find.byKey(const Key('autonomous-device-code'));
  const mismatch =
      'That code did not match. Generate a new code on your Autonomous robot, then try again.';

  /// The page as the Devices tab has it: the paired list, and a way into the Wi-Fi code dialog.
  Future<WifiRobotsController> open(
    WidgetTester tester,
    FakeAutonomousDeviceCli cli, {
    bool dialog = true,
    void Function()? openLocalNetworkSettings,
  }) async {
    final robots = WifiRobotsController(cli: cli)..start();
    addTearDown(robots.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => ListView(
              children: [
                TextButton(
                  key: const Key('open-wifi'),
                  onPressed: () => showWifiPairDialog(
                    context,
                    robots,
                    openLocalNetworkSettings: openLocalNetworkSettings,
                  ),
                  child: const Text('Wi-Fi code'),
                ),
                WifiRobotsList(controller: robots),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    if (dialog) {
      await tester.tap(find.byKey(const Key('open-wifi')));
      await tester.pumpAndSettle();
    }
    return robots;
  }

  Future<void> select(WidgetTester tester, String id) async {
    tester
        .widget<AppSelectField<String?>>(
          find.byKey(const Key('autonomous-device-selection')),
        )
        .onChanged(id);
    await tester.pumpAndSettle();
  }

  Future<void> submit(WidgetTester tester, String code) async {
    await tester.enterText(codeField, code);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
  }

  Future<void> refresh(WidgetTester tester) async {
    final button = find.byType(AppIconButton);
    await tester.ensureVisible(button);
    await tester.tap(button);
    await tester.pumpAndSettle();
  }

  testWidgets('the code dialog keeps separate accessible purposes', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    try {
      final cli = FakeAutonomousDeviceCli();
      await open(tester, cli);
      final picker = find.bySemanticsLabel('Autonomous robot');
      final pickerNode = tester.getSemantics(picker);
      final codeNode = tester.getSemantics(
        find.bySemanticsLabel('Six-character code'),
      );
      final refreshNode = tester.getSemantics(
        find.byTooltip('Refresh Autonomous robot status'),
      );
      expect(pickerNode.getSemanticsData().value, 'Select a device');
      expect(pickerNode.getSemanticsData().flagsCollection.isButton, isTrue);
      expect(codeNode.id, isNot(pickerNode.id));
      expect(codeNode.getSemanticsData().flagsCollection.isTextField, isTrue);
      expect(refreshNode.id, isNot(pickerNode.id));
      expect(
        refreshNode.getSemanticsData().hasAction(SemanticsAction.tap),
        isTrue,
      );
      await select(tester, 'device-1');
      expect(tester.getSemantics(picker).getSemanticsData().value, 'Kitchen');
      expect(cli.submissions, isEmpty);
      expect(
        find.textContaining('Separators are allowed, for example ABC-123.'),
        findsOneWidget,
      );
      expect(
        find.text(
          'Harness CLI keeps the connection running when you close Desktop.',
        ),
        findsOneWidget,
      );
    } finally {
      semantics.dispose();
    }
  });

  testWidgets(
    'pairing normalizes the code, binds the chosen robot, closes and lists it',
    (tester) async {
      final cli = FakeAutonomousDeviceCli();
      await open(tester, cli);
      await select(tester, 'device-1');
      await submit(tester, 'o-i_l·u23');
      expect(cli.submissions, [
        {'code': '011V23', 'deviceId': 'device-1'},
      ]);
      expect(find.byType(WifiPairDialog), findsNothing);
      expect(find.text('Paired over Wi-Fi'), findsOneWidget);
      expect(find.text('Connected · fingerprint-device-1'), findsOneWidget);
    },
  );

  testWidgets('a single robot on the network still has to be chosen', (
    tester,
  ) async {
    final cli = FakeAutonomousDeviceCli();
    await open(tester, cli);
    await submit(tester, 'ABC234');
    expect(cli.submissions, isEmpty);
    expect(
      find.text('Select your discovered Autonomous robot first.'),
      findsOneWidget,
    );
    expect(
      tester.widget<TextField>(codeField).controller!.text,
      'ABC234',
      reason: 'a code refused before sending stays to be corrected',
    );
  });

  testWidgets('choosing another robot clears the typed code', (tester) async {
    final cli = FakeAutonomousDeviceCli()
      ..discovered.add({'id': 'device-2', 'name': 'Desk'});
    await open(tester, cli);
    await select(tester, 'device-1');
    await tester.enterText(codeField, 'ABC234');
    await select(tester, 'device-2');
    expect(tester.widget<TextField>(codeField).controller!.text, isEmpty);
  });

  testWidgets('a robot that leaves the network takes its code with it', (
    tester,
  ) async {
    final cli = FakeAutonomousDeviceCli();
    await open(tester, cli);
    await select(tester, 'device-1');
    await tester.enterText(codeField, 'ABC234');
    cli.discovered = [
      {'id': 'device-2', 'name': 'Desk'},
    ];
    await refresh(tester);
    expect(tester.widget<TextField>(codeField).controller!.text, isEmpty);
    expect(
      tester
          .widget<AppSelectField<String?>>(
            find.byKey(const Key('autonomous-device-selection')),
          )
          .value,
      isNull,
    );
    expect(cli.submissions, isEmpty);
  });

  testWidgets(
    'while pairing the robot cannot be changed; a mismatch recovers',
    (tester) async {
      final pending = Completer<void>();
      final cli = FakeAutonomousDeviceCli()
        ..pairWait = pending
        ..discovered.add({'id': 'device-2', 'name': 'Desk'});
      await open(tester, cli);
      final picker = find.byKey(const Key('autonomous-device-selection'));
      await select(tester, 'device-1');
      final previousSelection = tester
          .widget<AppSelectField<String?>>(picker)
          .onChanged;
      await tester.enterText(codeField, 'ABC234');
      await tester.tap(find.byKey(const Key('autonomous-device-pair')));
      await tester.pump();
      expect(find.text('Pairing…'), findsOneWidget);
      previousSelection('device-2');
      await tester.pump();
      expect(tester.widget<AppSelectField<String?>>(picker).value, 'device-1');
      pending.completeError(
        const AutonomousDeviceCliException('CODE_MISMATCH', 'Mismatch'),
      );
      await tester.pumpAndSettle();
      expect(find.text(mismatch), findsOneWidget);
      expect(tester.widget<TextField>(codeField).enabled, isTrue);
      // The message stays through a refresh, and a retry pairs the same chosen robot.
      await refresh(tester);
      expect(find.text(mismatch), findsOneWidget);
      cli.pairWait = null;
      await submit(tester, 'DEF567');
      expect(cli.submissions.map((row) => row['deviceId']), [
        'device-1',
        'device-1',
      ]);
      expect(find.text(mismatch), findsNothing);
      expect(find.text('Connected · fingerprint-device-1'), findsOneWidget);
    },
  );

  testWidgets(
    'a blocked local network says where to allow it; paired robots stay listed',
    (tester) async {
      var opened = 0;
      final cli = FakeAutonomousDeviceCli()
        ..networkBlocked = true
        ..devices = [
          {
            'id': 'fingerprint-1',
            'fingerprint': 'fingerprint-1',
            'label': 'Desk lamp',
            'online': false,
          },
        ];
      await open(tester, cli, openLocalNetworkSettings: () => opened++);
      final notice = find.byKey(const Key('autonomous-device-network-blocked'));
      expect(notice, findsOneWidget);
      expect(find.text('Allow Harness on your local network'), findsOneWidget);
      expect(find.textContaining('No Autonomous robots found'), findsNothing);
      await tester.tap(find.text('Open Settings'));
      expect(opened, 1);
      cli.networkBlocked = false;
      await refresh(tester);
      expect(notice, findsNothing);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(find.text('Desk lamp'), findsOneWidget);
      expect(find.text('Paired · Offline · fingerprint-1'), findsOneWidget);
    },
  );

  testWidgets('an empty network says so and pairs nothing', (tester) async {
    final cli = FakeAutonomousDeviceCli()..discovered = [];
    await open(tester, cli);
    expect(find.textContaining('No Autonomous robots found.'), findsOneWidget);
    await submit(tester, 'ABC234');
    expect(cli.submissions, isEmpty);
  });

  testWidgets('an older CLI is told to update', (tester) async {
    await open(tester, FakeAutonomousDeviceCli()..unsupported = true);
    expect(
      find.text('Update Harness CLI to use Autonomous robots.'),
      findsOneWidget,
    );
    expect(find.text('harness update'), findsOneWidget);
    expect(codeField, findsNothing);
  });

  testWidgets('Revoke… confirms and targets the exact paired fingerprint', (
    tester,
  ) async {
    final cli = FakeAutonomousDeviceCli()
      ..devices = [
        {
          'id': 'fingerprint-1',
          'fingerprint': 'fingerprint-1',
          'label': 'Kitchen',
          'online': true,
        },
        {
          'id': 'fingerprint-2',
          'fingerprint': 'fingerprint-2',
          'label': 'Desk',
          'online': false,
        },
      ];
    await open(tester, cli, dialog: false);
    await tester.tap(
      find.byKey(const ValueKey('wifi-robot-revoke-fingerprint-1')),
    );
    await tester.pumpAndSettle();
    expect(cli.revoked, isEmpty);
    expect(find.text('Revoke Autonomous robot?'), findsOneWidget);
    await tester.tap(find.byKey(const Key('device-confirm')));
    await tester.pumpAndSettle();
    expect(cli.revoked, ['fingerprint-1']);
    expect(find.text('Kitchen'), findsNothing);
    expect(find.text('Desk'), findsOneWidget);
  });

  testWidgets('nothing paired, no list', (tester) async {
    await open(tester, FakeAutonomousDeviceCli(), dialog: false);
    expect(find.byKey(const Key('wifi-robots')), findsNothing);
  });

  testWidgets('without an injected CLI nothing runs, under test or later', (
    tester,
  ) async {
    final robots = WifiRobotsController()..start();
    addTearDown(robots.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: WifiPairDialog(controller: robots)),
      ),
    );
    await tester.pumpAndSettle();
    await tester.pump(const Duration(minutes: 2));
    expect(tester.takeException(), isNull);
    expect(
      tester.widget<AppIconButton>(find.byType(AppIconButton)).onPressed,
      isNull,
    );
  });

  testWidgets('an injected CLI is not polled in the background in tests', (
    tester,
  ) async {
    final cli = FakeAutonomousDeviceCli();
    await open(tester, cli);
    final calls = cli.statusCalls;
    await tester.pump(const Duration(minutes: 2));
    expect(cli.statusCalls, calls);
  });

  testWidgets('the first status read waits in a skeleton', (tester) async {
    final pending = Completer<void>();
    final cli = FakeAutonomousDeviceCli()..statusWait = pending;
    final robots = WifiRobotsController(cli: cli)..start();
    addTearDown(robots.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: WifiPairDialog(controller: robots)),
      ),
    );
    await tester.pump();
    expect(find.byType(SkeletonBlock), findsOneWidget);
    pending.complete();
    await tester.pumpAndSettle();
    expect(find.byType(SkeletonBlock), findsNothing);
  });

  group('the Devices tab', () {
    Future<(DevicesController, DialState, List<Map<String, Object?>>)> pump(
      WidgetTester tester, {
      WifiRobotsController? wifi,
    }) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1280, 940);
      addTearDown(tester.view.reset);
      final dial = DialState();
      final sent = <Map<String, Object?>>[];
      final controller = DevicesController(
        dial: dial,
        accountId: 'a',
        sendSettings: (_, patch) async {
          sent.add(patch);
          return true;
        },
      );
      await controller.load();
      report(dial, [deviceStatus('desk')]);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: DevicesScreen(controller: controller, wifi: wifi),
          ),
        ),
      );
      await tester.pumpAndSettle();
      addTearDown(() {
        controller.dispose();
        dial.dispose();
      });
      return (controller, dial, sent);
    }

    testWidgets('Add device offers the USB cable and the Wi-Fi code', (
      tester,
    ) async {
      final cli = FakeAutonomousDeviceCli();
      final wifi = WifiRobotsController(cli: cli);
      addTearDown(wifi.dispose);
      await pump(tester, wifi: wifi);
      await tester.tap(find.byKey(const Key('devices-add')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('devices-add-usb')), findsOneWidget);
      expect(find.byKey(const Key('devices-add-wifi')), findsOneWidget);
      await tester.tap(find.byKey(const Key('devices-add-wifi')));
      await tester.pumpAndSettle();
      expect(find.byType(WifiPairDialog), findsOneWidget);
      await select(tester, 'device-1');
      await submit(tester, 'ABC234');
      expect(find.byType(WifiPairDialog), findsNothing);
      expect(find.text('Paired over Wi-Fi'), findsOneWidget);
      expect(find.text('Connected · fingerprint-device-1'), findsOneWidget);

      await tester.tap(find.byKey(const Key('devices-add')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('devices-add-usb')));
      await tester.pumpAndSettle();
      expect(find.text('Add a device'), findsOneWidget);
    });

    testWidgets('without the network list, Add device is the cable alone', (
      tester,
    ) async {
      await pump(tester);
      await tester.tap(find.byKey(const Key('devices-add')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('devices-add-wifi')), findsNothing);
      expect(find.text('Add a device'), findsOneWidget);
    });

    testWidgets('Still companion is on the robot card and writes quiet', (
      tester,
    ) async {
      final (controller, _, sent) = await pump(tester);
      final key = controller.devices.single.key;
      final quiet = find.byKey(ValueKey('devices-quiet-$key'));
      await tester.ensureVisible(quiet);
      expect(find.text('Still companion'), findsOneWidget);
      await tester.tap(quiet);
      await tester.pump();
      expect(sent, [
        {'quiet': true},
      ]);
      // Unconfirmed, the change times out rather than holding a timer past the test.
      await tester.pump(const Duration(seconds: 9));
      // The companion skins are still off, so there is no switch to follow one.
      expect(kDeviceCompanionSkins, isFalse);
      expect(find.text('Follow desktop companion'), findsNothing);
    });
  });
}
