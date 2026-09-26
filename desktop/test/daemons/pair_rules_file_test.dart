// pair.jsonc: where harnessd reads the pair's rules (cli/src/pair/rules.ts
// pairConfigPath), and the file the window writes when there is none, which
// must mean exactly what no file means: the model off, no rules.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:harness/daemons/pair_rules_file.dart';

/// JSON with `//` comments and trailing commas, read the way rules.ts does.
Object? _jsonc(String text) {
  final lines = [
    for (final line in const LineSplitter().convert(text))
      line.replaceFirst(RegExp(r'^\s*//.*$'), ''),
  ].join('\n');
  return jsonDecode(lines.replaceAll(RegExp(r',(\s*[}\]])'), r'$1'));
}

void main() {
  test('the path follows XDG_CONFIG_HOME when it is absolute', () {
    expect(
      pairRulesPath(environment: {'HOME': '/Users/pat'}),
      '/Users/pat/.config/harness/pair.jsonc',
    );
    expect(
      pairRulesPath(
        environment: {'HOME': '/Users/pat', 'XDG_CONFIG_HOME': '/cfg'},
      ),
      '/cfg/harness/pair.jsonc',
    );
    expect(
      pairRulesPath(
        environment: {'HOME': '/Users/pat', 'XDG_CONFIG_HOME': 'relative'},
      ),
      '/Users/pat/.config/harness/pair.jsonc',
    );
  });

  test('the template is no rules and no model, with the rules explained', () {
    expect(_jsonc(pairRulesTemplate), {'model': false, 'rules': []});
    expect(pairRulesTemplate, contains('act within rules'));
  });

  test('a missing file is written once; an existing one is never touched', () async {
    final dir = await Directory.systemTemp.createTemp('pair-rules');
    addTearDown(() => dir.delete(recursive: true));
    final env = {'HOME': '/nowhere', 'XDG_CONFIG_HOME': dir.path};
    final file = await ensurePairRules(environment: env);
    expect(file.path, '${dir.path}/harness/pair.jsonc');
    expect(await file.readAsString(), pairRulesTemplate);
    await file.writeAsString('{"rules": [], "model": true}');
    await ensurePairRules(environment: env);
    expect(await file.readAsString(), '{"rules": [], "model": true}');
  });
}
