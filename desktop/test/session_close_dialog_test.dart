import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harness/core/models.dart';
import 'package:harness/shared/theme/app_theme.dart' as grid;
import 'package:harness/widgets/desktop_prompt_surface.dart';
import 'package:harness/widgets/session_close_dialog.dart';

import 'box_render_preview_test.dart' show loadPreviewFonts;

void main() {
  final renderDir = Platform.environment['SESSION_CLOSE_RENDER_DIR'];
  setUpAll(() async {
    if (renderDir != null) await loadPreviewFonts();
  });

  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('${brightness.name} close prompt at ${scale}x', (
        tester,
      ) async {
        final previousBrightness = grid.AppTheme.brightness.value;
        grid.AppTheme.brightness.value = brightness;
        addTearDown(() => grid.AppTheme.brightness.value = previousBrightness);
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = scale == 1
            ? const Size(800, 500)
            : const Size(360, 320);
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final picture = GlobalKey();
        var dismissed = false;
        await tester.pumpWidget(
          MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: grid.buildAppTheme(brightness: brightness),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.linear(scale)),
              child: RepaintBoundary(key: picture, child: child!),
            ),
            home: Builder(
              builder: (context) => Scaffold(
                body: Center(
                  child: TextButton(
                    onPressed: () async {
                      final result = await showSessionCloseDialog(
                        context,
                        Agent(
                          id: 'fixture',
                          name: 'Example session',
                          engine: 'codex',
                        ),
                        'working',
                      );
                      expect(result, isNull);
                      dismissed = true;
                    },
                    child: const Text('Open'),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Open'));
        await tester.pumpAndSettle();
        final message = find.text('Still working. Close anyway?');
        final cancel = find.widgetWithText(TextButton, 'Cancel');
        final close = find.widgetWithText(FilledButton, 'Close');
        expect(message, findsOneWidget);
        expect(tester.widget<TextButton>(cancel).focusNode!.hasFocus, isTrue);
        // Enlarged text can scroll; the visible body must stay above actions.
        expect(
          tester.getBottomLeft(find.byType(DesktopPromptScrollBody)).dy,
          lessThan(tester.getTopLeft(cancel).dy),
        );
        expect(
          tester.getBottomRight(close).dy,
          lessThan(tester.view.physicalSize.height),
        );
        expect(tester.takeException(), isNull);

        if (renderDir != null) {
          await tester.runAsync(() async {
            final boundary =
                picture.currentContext!.findRenderObject()!
                    as RenderRepaintBoundary;
            final image = await boundary.toImage(pixelRatio: 2);
            final data = await image.toByteData(format: ui.ImageByteFormat.png);
            Directory(renderDir).createSync(recursive: true);
            await File('$renderDir/${brightness.name}-${scale}x.png')
                .writeAsBytes(data!.buffer.asUint8List());
            image.dispose();
          });
        }
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(dismissed, isTrue);
        expect(message, findsNothing);
      });
    }
  }
}
