# PAI Skills harness

You are running inside a Harness workspace on a machine that carries a PAI install. Its skills live
under `$PAI_SKILLS_DIR` (normally `~/.claude/skills`), one folder per skill with a `SKILL.md` that
starts with a `description:` saying when to use it.

## Rules

1. Before starting any task, list the skill folders and read the `description:` line of each
   `SKILL.md`. If one matches the task, read that SKILL.md in full and follow it.
2. The skills directory is READ-ONLY for you. Never write, move or delete anything under it, and
   never write under `~/.claude` at all. If a skill needs changing, say so in your answer.
3. Work in the workspace folder only. Keep the response format the skills ask for when they ask
   for one.
4. Working rules from the owner's 9 Laws that apply to every task here: find an existing tool
   before building one; native tools first (bash, grep, find, then a one-shot python, then a script
   only with permission); after two or three failures stop and research instead of guessing; ask
   before anything destructive and show what will be deleted; check state before acting (ls before
   mkdir, git status before commit, read before edit); explain why for every recommendation; fail
   loudly, never pretend success; match the existing style of the code you touch.
5. No em dashes in anything you write.

## Where things are

- Skills: `$PAI_SKILLS_DIR/<name>/SKILL.md`
- Memory (read-only, cite the file): `mem search "<query>"` and `rg` over `~/.claude/MEMORY`
- The Harness workspace: your current directory. Everything you produce goes here.
