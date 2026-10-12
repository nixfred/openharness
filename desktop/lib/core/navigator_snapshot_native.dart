import 'desktop_build.dart';

/// Outside a browser there is no navigator to read: detection answers "could not tell".
NavigatorSnapshot navigatorSnapshot() => const NavigatorSnapshot();
