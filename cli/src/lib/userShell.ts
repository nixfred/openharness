import { userInfo } from 'node:os'
import { isAbsolute } from 'node:path'

/**
 * The person's shell: `SHELL` when the daemon was given one, else the account's own (its passwd entry).
 *
 * A shell hands `SHELL` on only when it was handed it: bash sets it for itself without exporting it, zsh and sh do
 * not set it at all (measured with `env -i` on macOS 15, 2026-10-12). So a daemon started from `docker exec`, a CI
 * step or a bare service has none, while the account still has a shell. The launch path asked the account from the
 * start (engineLaunch.ts, measured in a Linux container). The login-shell environment and the engine lookups read
 * only `SHELL`, and there found no shell at all: the daemon logged "could not read a login shell environment", and
 * nothing the person's profile exports reached it (a moved CODEX_HOME, an API key, nvm's PATH). Found when
 * e2e/enginehomes.e2e.ts failed whole under `env -i`, which is that daemon.
 */
export function currentUserShell(): string | undefined {
  if (process.env.SHELL && isAbsolute(process.env.SHELL)) return process.env.SHELL
  try {
    const shell = userInfo().shell
    return shell && isAbsolute(shell) ? shell : undefined
  } catch {
    return undefined
  }
}
