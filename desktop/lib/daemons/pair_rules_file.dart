/// `pair.jsonc`: the person's rules for their paired daemon (`daemons/BRAIN.md`,
/// "Autonomy and rules"; `cli/src/pair/rules.ts`). harnessd reads it, on every
/// machine, at `$XDG_CONFIG_HOME/harness/pair.jsonc` (an absolute
/// `XDG_CONFIG_HOME`), else `~/.config/harness/pair.jsonc`, and re-reads it
/// when it changes. The window only opens it for editing, writing a commented
/// file with no rules first when there is none: no rules is what a missing
/// file already means, so creating it changes nothing.
library;

import 'dart:io';

/// Where harnessd reads the rules on this computer.
String pairRulesPath({Map<String, String>? environment}) {
  final env = environment ?? Platform.environment;
  final xdg = env['XDG_CONFIG_HOME'];
  final base = xdg != null && xdg.startsWith('/')
      ? xdg
      : '${env['HOME'] ?? ''}/.config';
  return '$base/harness/pair.jsonc';
}

/// A file that means exactly what no file means: the model off, no rules.
const pairRulesTemplate = '''// Your paired daemon's rules (daemons/BRAIN.md, "Autonomy and rules").
// harnessd reads this on every machine and re-reads it when it changes.
{
  // true lets the daemon ask one small model for better status-line words.
  "model": false,

  // Answers to give without asking, used only while the dial is
  // "act within rules". The first rule that matches wins. A rule never
  // answers a push, delete, force-push, deploy or merge prompt, never picks
  // an option that answers for more than this once, and approves only what
  // a key could (reads, tests, builds, linters, formatters, in-project
  // edits). Everything a rule does is journaled and reported afterwards.
  "rules": [
    // {
    //   "name": "tests in api",
    //   "harness": "api*",
    //   "project": "~/code/api",
    //   "question": "npm (run )?test",
    //   "choice": "Yes"
    // }
  ]
}
''';

/// The rules file, written from [pairRulesTemplate] when it does not exist
/// yet (never over one that does).
Future<File> ensurePairRules({Map<String, String>? environment}) async {
  final file = File(pairRulesPath(environment: environment));
  if (!await file.exists()) {
    await file.parent.create(recursive: true);
    await file.writeAsString(pairRulesTemplate, flush: true);
  }
  return file;
}
