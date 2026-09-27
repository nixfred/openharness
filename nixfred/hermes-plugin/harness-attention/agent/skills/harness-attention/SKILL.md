---
name: harness-attention
description: Answer "who needs me", "what is waiting on me", "which agent failed" or "is anyone stuck" by calling the harness_attention tool and reading the fleet state from the local Harness daemon.
---

# Harness attention

When the person asks who needs them, what is waiting, whether an agent failed, or what to look at
next, call `harness_attention`. Pass `only_urgent: true` unless they asked for the whole fleet.

Read the result like this:

- `needs_you` is the list to answer with first: name, state and detail, most urgent first
  (permission, then waiting, then failed).
- `alerts` are collisions: two agents on the same file, folder or branch within the hour. Name both
  agents and the path or branch; suggest one of them pauses or takes a lock (`harness lock`).
- If `needs_you` and `alerts` are both empty, say so in one line and mention how many are working.
- Never invent an agent that is not in the result. If the tool returns an error, say the daemon is
  not reachable and how to start it.

Keep the answer short: one line per agent that needs the person, nothing for the ones that do not.
