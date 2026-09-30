// nixfred: a stand-alone window with only the Subscriptions screen, for screenshots and design review
// against a running daemon. Not used by release builds.
//   flutter run -d linux -t lib/nixfred/subscriptions/subscriptions_preview_main.dart \
//     --dart-define=SUBS_URL=http://127.0.0.1:18473
library;

import 'package:flutter/material.dart';

import '../../shared/theme/app_theme.dart' as grid;
import 'subscriptions_section.dart';

void main() {
  const url = String.fromEnvironment('SUBS_URL', defaultValue: 'http://127.0.0.1:18473');
  grid.AppTheme.brightness.value = Brightness.dark;
  runApp(MaterialApp(
    title: 'Harness Subscriptions',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(brightness: Brightness.dark, colorSchemeSeed: grid.AppPalette.accentOnSurface),
    home: Scaffold(
      backgroundColor: grid.AppPalette.windowBg,
      body: SubscriptionsSection(source: DaemonSubscriptionsSource(url)),
    ),
  ));
}
