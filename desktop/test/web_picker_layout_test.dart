import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harness/auth/auth_session.dart';
import 'package:harness/core/config.dart';
import 'package:harness/core/models.dart';
import 'package:harness/screens/swarm_screen.dart';
import 'package:harness/shared/theme/app_theme.dart' as grid;
import 'package:harness/state/app_state.dart';
import 'package:harness/web/picker/web_picker_scopes.dart';
import 'package:harness/web/shell/web_chrome.dart';

import 'support/real_fonts.dart';

/// The web picker bar, laid out with real fonts: a regression here once
/// stacked every scope on a centered line of its own.
void main() {
  setUpAll(loadRealFonts);

  testWidgets('picker scopes sit on one row, left to right', (tester) async {
    final app = AppNotifier(
      config: AppConfig.dev,
      authSession: AuthSession(),
      configStore: null,
    )..newSwarm(newTabPage: true);
    const machine = Machine(
      machineId: 'remote-box',
      name: 'harness-remote-box',
      authMode: MachineAuthMode.remote,
    );
    app.machines.add(machine);
    app.machineStates['remote-box'] = MachineState(machine)
      ..nodeOnline = true
      ..needsLink = true;
    final boundary = GlobalKey();
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1440, 800);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      RepaintBoundary(
        key: boundary,
        child: MaterialApp(
          theme: grid.buildAppTheme(brightness: Brightness.dark),
          home: SwarmScreen(
            notifier: app,
            nativeTabs: false,
            chrome: webWorkspaceChrome(app),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 200));
    await tester.tap(find.byKey(const ValueKey('swarm-search-button')));
    await tester.pump(const Duration(milliseconds: 200));
    await tester.tap(find.byKey(const ValueKey('web-picker-scope:@')));
    await tester.pump(const Duration(milliseconds: 200));

    final rects = [
      for (final scope in kWebPickerScopes)
        tester.getRect(
          find.byKey(ValueKey('web-picker-scope:${scope.prefix}')),
        ),
    ];
    final close = tester.getRect(
      find.byKey(const ValueKey('web-picker-close')),
    );
    for (final rect in [...rects, close]) {
      expect(rect.center.dy, moreOrLessEquals(rects.first.center.dy));
    }
    for (var i = 1; i < rects.length; i++) {
      expect(rects[i].left, greaterThan(rects[i - 1].right));
    }
    // The bar starts where the input's text does.
    expect(
      rects.first.left,
      moreOrLessEquals(
        tester.getRect(find.byKey(const ValueKey('swarm-search-input'))).left,
        epsilon: 1,
      ),
    );
    // Each scope hugs its label rather than taking the row.
    expect(rects.first.width, lessThan(120));
    expect(tester.takeException(), isNull);

    final output = Platform.environment['HARNESS_REFINEMENT_CAPTURE_DIR'];
    if (output != null) {
      await tester.runAsync(() async {
        final image =
            await (boundary.currentContext!.findRenderObject()
                    as RenderRepaintBoundary)
                .toImage();
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        Directory(output).createSync(recursive: true);
        File('$output/web-picker-bar.png')
            .writeAsBytesSync(data!.buffer.asUint8List());
        image.dispose();
      });
    }
    await tester.pumpWidget(const SizedBox.shrink());
    app.dispose();
  });
}
