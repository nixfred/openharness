import 'package:flutter/material.dart';

import '../state/attention_state.dart';

/// A 2 px border and a soft outer glow in the state colour, only while the agent needs a person
/// (waiting, permission, failed). Everything else draws nothing, so a quiet desk stays quiet. The
/// child is never resized: the glow is painted outside it (DESIGN.md: glow means "needs Fred next").
class AttentionGlow extends StatefulWidget {
  const AttentionGlow({super.key, required this.attention, required this.agentId, required this.child, this.reducedMotion = false});

  final AttentionState attention;
  final String agentId;
  final Widget child;
  final bool reducedMotion;

  static Color colorFor(AgentAttention s, ColorScheme scheme) => switch (s) {
        AgentAttention.permission || AgentAttention.failed => scheme.error,
        AgentAttention.waiting => const Color(0xFFEAB308),
        _ => Colors.transparent,
      };

  @override
  State<AttentionGlow> createState() => _AttentionGlowState();
}

class _AttentionGlowState extends State<AttentionGlow> with SingleTickerProviderStateMixin {
  late final AnimationController _breath = AnimationController(vsync: this, duration: const Duration(milliseconds: 1200));

  @override
  void initState() {
    super.initState();
    widget.attention.addListener(_sync);
    _sync();
  }

  @override
  void didUpdateWidget(AttentionGlow old) {
    super.didUpdateWidget(old);
    if (!identical(old.attention, widget.attention)) {
      old.attention.removeListener(_sync);
      widget.attention.addListener(_sync);
    }
    _sync();
  }

  void _sync() {
    final row = widget.attention.of(widget.agentId);
    final breathe = !widget.reducedMotion && row != null && (row.state == AgentAttention.waiting || row.state == AgentAttention.permission);
    if (breathe && !_breath.isAnimating) {
      _breath.repeat(reverse: true);
    } else if (!breathe && _breath.isAnimating) {
      _breath.stop();
      _breath.value = 1;
    }
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.attention.removeListener(_sync);
    _breath.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final row = widget.attention.of(widget.agentId);
    if (row == null || !row.needsYou) return widget.child;
    final color = AttentionGlow.colorFor(row.state, Theme.of(context).colorScheme);
    return AnimatedBuilder(
      animation: _breath,
      child: widget.child,
      builder: (context, child) {
        final t = widget.reducedMotion || !_breath.isAnimating ? 1.0 : 0.55 + 0.45 * _breath.value;
        return DecoratedBox(
          position: DecorationPosition.foreground,
          decoration: BoxDecoration(
            border: Border.all(color: color.withValues(alpha: 0.9 * t), width: 2),
            boxShadow: [BoxShadow(color: color.withValues(alpha: 0.35 * t), blurRadius: 14, spreadRadius: 1)],
          ),
          child: child,
        );
      },
    );
  }
}
