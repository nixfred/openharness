import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harness/shared/theme/app_theme.dart' as grid;
import 'package:harness/widgets/session_work_dialog.dart';

import 'session_git_context_test.dart';
import 'support/real_fonts.dart';

void main() {
  setUpAll(loadRealFonts);
  testWidgets(
    'opening work details preserves launch context and only follows the selected PR link',
    (tester) async {
      final opened = <Uri>[];
      final git = gitFixture();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SessionWorkDialog(
              agent: workAgent(git: git),
              read: (_) async => {'gitContext': git, 'history': git['history']},
              open: (uri) async {
                opened.add(uri);
                return true;
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('/silent-beacon'), findsOneWidget);
      expect(find.text('hn/preview-fix'), findsOneWidget);
      await tester.tap(
        find.byKey(
          const ValueKey('work-pr-https://github.com/acme/app/pull/12'),
        ),
      );
      await tester.pumpAndSettle();
      expect(opened, [Uri.parse('https://github.com/acme/app/pull/12')]);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'late replies after dismissal cannot reopen or replace another view',
    (tester) async {
      final reply = Completer<Map<String, dynamic>>();
      final focus = FocusNode();
      addTearDown(focus.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                focusNode: focus,
                autofocus: true,
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (_) => SessionWorkDialog(
                    agent: workAgent(git: gitFixture()),
                    read: (_) => reply.future,
                  ),
                ),
                child: const Text('Inspect'),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(find.byType(SessionWorkDialog), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byType(SessionWorkDialog), findsNothing);
      expect(focus.hasFocus, isTrue);
      reply.complete({'status': 'unavailable'});
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );

  for (final brightness in Brightness.values) {
    for (final size in [const Size(1000, 720), const Size(420, 680)]) {
      testWidgets(
        'work details fit ${size.width} ${brightness.name}, including enlarged text',
        (tester) async {
          tester.view.devicePixelRatio = 1;
          tester.view.physicalSize = size;
          addTearDown(tester.view.reset);
          final old = grid.AppTheme.brightness.value;
          grid.AppTheme.brightness.value = brightness;
          addTearDown(() => grid.AppTheme.brightness.value = old);
          final boundary = GlobalKey();
          await tester.pumpWidget(
            RepaintBoundary(
              key: boundary,
              child: MaterialApp(
                debugShowCheckedModeBanner: false,
                theme: grid.buildAppTheme(brightness: brightness),
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(context).copyWith(
                    textScaler: TextScaler.linear(size.width < 500 ? 1.6 : 1),
                  ),
                  child: child!,
                ),
                home: Scaffold(
                  body: SessionWorkDialog(
                    agent: workAgent(git: manyPrFixture()),
                    online: false,
                    read: (_) =>
                        throw StateError('Offline must not request data'),
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(find.text('Offline · last known work'), findsOneWidget);
          expect(tester.takeException(), isNull);
          final output =
              Platform.environment['HARNESS_GIT_CONTEXT_CAPTURE_DIR'];
          if (output != null) {
            await tester.runAsync(() async {
              final render =
                  boundary.currentContext!.findRenderObject()!
                      as RenderRepaintBoundary;
              final picture = await render.toImage(pixelRatio: 1);
              final bytes = await picture.toByteData(
                format: ui.ImageByteFormat.png,
              );
              await Directory(output).create(recursive: true);
              await File(
                '$output/work-${size.width.toInt()}-${brightness.name}.png',
              ).writeAsBytes(bytes!.buffer.asUint8List());
              picture.dispose();
            });
          }
        },
      );
    }
  }
}
