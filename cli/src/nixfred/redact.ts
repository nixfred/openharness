/**
 * Secret scrubbing for anything that leaves the machine or lands in a log: audit lines, review
 * bundles, transcript excerpts. Conservative on purpose: a long identifier is masked only when a
 * credential-shaped prefix or a nearby key/token/secret/password word says it is one, so ordinary
 * code (long function names, hashes in test fixtures) survives untouched.
 */
export interface Redaction {
  text: string
  redactionCount: number
}

const RULES: Array<{ re: RegExp; sub: string | ((...m: string[]) => string) }> = [
  { re: /\bsk-[A-Za-z0-9_-]{8,}\b/g, sub: 'sk-[REDACTED]' },
  { re: /\b(?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{20,}\b/g, sub: 'gh*_[REDACTED]' },
  { re: /\bgithub_pat_[A-Za-z0-9_]{20,}\b/g, sub: 'github_pat_[REDACTED]' },
  { re: /\bAKIA[0-9A-Z]{16}\b/g, sub: 'AKIA[REDACTED]' },
  { re: /\bBearer\s+[A-Za-z0-9._~+/=-]{8,}/g, sub: 'Bearer [REDACTED]' },
  // A key-ish word, then separator, then a 40+ char hex/base64 run: the run is the secret.
  {
    re: /\b(key|token|secret|password|passwd|pwd|api[_-]?key|access[_-]?key)\b(\s*[:=]\s*|\s+)["']?([A-Za-z0-9+/=_-]{40,})["']?/gi,
    sub: (_m, word: string, sep: string) => `${word}${sep}[REDACTED]`,
  },
  // Emails keep the domain so a report still says which provider was involved.
  { re: /\b[A-Za-z0-9._%+-]+@([A-Za-z0-9.-]+\.[A-Za-z]{2,})\b/g, sub: (_m, domain: string) => `[user]@${domain}` },
  { re: /\/home\/[A-Za-z0-9._-]+\//g, sub: '~/' },
  { re: /\/Users\/[A-Za-z0-9._-]+\//g, sub: '~/' },
]

const IPV4 = /\b(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})\b/g

function isPrivateIp(a: number, b: number): boolean {
  if (a === 10 || a === 127 || a === 0) return true
  if (a === 192 && b === 168) return true
  if (a === 172 && b >= 16 && b <= 31) return true
  if (a === 169 && b === 254) return true
  if (a === 100 && b >= 64 && b <= 127) return true // CGNAT, where Tailscale lives
  return false
}

export function redactSecrets(input: string): Redaction {
  let count = 0
  let text = input
  for (const rule of RULES) {
    text = text.replace(rule.re, (...args: string[]) => {
      count++
      return typeof rule.sub === 'string' ? rule.sub : rule.sub(...args)
    })
  }
  text = text.replace(IPV4, (m, a: string, b: string) => {
    const na = Number(a), nb = Number(b)
    if ([a, b].some((o) => Number(o) > 255)) return m
    if (isPrivateIp(na, nb)) return m
    count++
    return `${a}.${b}.x.x`
  })
  return { text, redactionCount: count }
}

/** Convenience for callers that only want the string. */
export const redacted = (s: string): string => redactSecrets(s).text
