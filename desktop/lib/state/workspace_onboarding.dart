import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../core/local_key_value_store.dart';

enum OnboardingStep {
  harnesses(
    '>',
    'Harnesses',
    'agent.new',
    'Finish a turn in your first harness',
  ),
  machines('@', 'Machines', 'machines.list', 'Connect another computer'),
  models(':', 'Models', 'models.list', 'Finish a turn with a local model'),
  store(
    '*',
    'Harness Store',
    'app.store',
    'Finish a turn in a non-coding harness',
  );

  const OnboardingStep(this.symbol, this.label, this.command, this.mission);
  final String symbol, label, command, mission;
}

/// Optional next steps, separate from unread work and real notification counts.
/// Observed use completes a step; simply opening its panel does not.
class WorkspaceOnboarding extends ChangeNotifier {
  WorkspaceOnboarding({this.storage});
  final LocalKeyValueStore? storage;
  String? _scope;
  bool _loaded = false, _disposed = false;
  bool _otherComputer = false, _modelsAvailable = false;
  int _revision = 0;
  final _completed = <OnboardingStep>{};
  final _dismissed = <OnboardingStep>{};
  final _seen = <OnboardingStep>{};
  final _usedHarnesses = <String>{};
  Set<OnboardingStep> _observed = {};
  Set<String> _observedHarnesses = {};
  Future<void> _saving = Future.value();

  String? get scope => _scope;
  bool get loaded => _loaded;
  bool completed(OnboardingStep step) => _completed.contains(step);
  OnboardingStep? get next {
    if (!_loaded) return null;
    if (!completed(OnboardingStep.harnesses) && !_otherComputer) {
      return _dismissed.contains(OnboardingStep.harnesses)
          ? null
          : OnboardingStep.harnesses;
    }
    if (!completed(OnboardingStep.machines) &&
        !_dismissed.contains(OnboardingStep.machines)) {
      return OnboardingStep.machines;
    }
    if (!completed(OnboardingStep.store) &&
        !_dismissed.contains(OnboardingStep.store)) {
      return OnboardingStep.store;
    }
    // Local models are an optional discovery after the others.
    return _modelsAvailable &&
            !completed(OnboardingStep.models) &&
            !_dismissed.contains(OnboardingStep.models)
        ? OnboardingStep.models
        : null;
  }

  bool showsDot(OnboardingStep step) => next == step && !_seen.contains(step);
  static String storageKey(String scope) =>
      'workspace.onboarding.v1.${base64Url.encode(utf8.encode(scope))}';

  void sync({
    required String scope,
    required Set<OnboardingStep> observed,
    required bool otherComputer,
    required bool modelsAvailable,
    Set<String> usedHarnesses = const {},
  }) {
    if (_disposed) return;
    final changedScope = _scope != scope;
    final before = next;
    _observed = Set.of(observed);
    _observedHarnesses = Set.of(usedHarnesses);
    _otherComputer = otherComputer;
    _modelsAvailable = modelsAvailable;
    if (changedScope) {
      _scope = scope;
      _loaded = false;
      _completed.clear();
      _dismissed.clear();
      _seen.clear();
      _usedHarnesses.clear();
      final revision = ++_revision;
      notifyListeners();
      unawaited(_load(scope, revision));
    } else if (_loaded) {
      final changed = _observe();
      if (changed) _save();
      if (changed || next != before) notifyListeners();
    }
  }

  bool _observe() {
    final before = _completed.length;
    final harnessesBefore = _usedHarnesses.length;
    _usedHarnesses.addAll(_observedHarnesses);
    _completed.addAll(_observed);
    if (_usedHarnesses.isNotEmpty) _completed.add(OnboardingStep.harnesses);
    // Coding engines all share the "coding" identity. A completed turn in a
    // purpose-built store harness earns this discovery, not switching engines.
    if (_usedHarnesses.any((id) => id != 'coding')) {
      _completed.add(OnboardingStep.store);
    }
    if (_completed.contains(OnboardingStep.models) ||
        _completed.contains(OnboardingStep.store)) {
      _completed.add(OnboardingStep.harnesses);
    }
    return _completed.length != before ||
        _usedHarnesses.length != harnessesBefore;
  }

  Future<void> _load(String scope, int revision) async {
    Map data = {};
    try {
      await _saving;
      final raw = await storage?.read(storageKey(scope));
      final decoded = raw == null ? null : jsonDecode(raw);
      if (decoded is Map) data = decoded;
    } catch (_) {
      // A missing or corrupt preference cannot block getting to work.
    }
    if (_disposed || _revision != revision) return;
    void read(String key, Set<OnboardingStep> target) {
      final values = data[key];
      if (values is List) {
        target.addAll(
          OnboardingStep.values.where((s) => values.contains(s.name)),
        );
      }
    }

    read('completed', _completed);
    read('dismissed', _dismissed);
    read('seen', _seen);
    final used = data['usedHarnesses'];
    if (used is List) _usedHarnesses.addAll(used.whereType<String>());
    _loaded = true;
    if (_observe()) _save();
    notifyListeners();
  }

  void acknowledge(OnboardingStep step) {
    if (_disposed || !_loaded || next != step || !_seen.add(step)) return;
    _save();
    notifyListeners();
  }

  void dismiss(OnboardingStep step) {
    if (_disposed || !_loaded || !_dismissed.add(step)) return;
    _save();
    notifyListeners();
  }

  void _save() {
    final key = storageKey(_scope!);
    final data = jsonEncode({
      'completed': _completed.map((s) => s.name).toList(),
      'dismissed': _dismissed.map((s) => s.name).toList(),
      'seen': _seen.map((s) => s.name).toList(),
      'usedHarnesses': _usedHarnesses.toList(),
    });
    _saving = _saving.then((_) async {
      try {
        await storage?.write(key, data);
      } catch (_) {}
    });
  }

  Future<void> flush() => _saving;

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
