import { describe, expect, it } from 'vitest'
import { redactSecrets, redacted } from './redact.js'

describe('redactSecrets', () => {
  it('masks provider keys and counts each', () => {
    const r = redactSecrets('OPENAI=sk-abcdefghijklmnop123 GH=ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123 PAT=github_pat_11AAAAAAA0bbbbbbbbbbbbbbbbbbbb AWS=AKIAIOSFODNN7EXAMPLE')
    expect(r.text).toBe('OPENAI=sk-[REDACTED] GH=gh*_[REDACTED] PAT=github_pat_[REDACTED] AWS=AKIA[REDACTED]')
    expect(r.redactionCount).toBe(4)
  })

  it('masks bearer tokens and key-labelled long runs', () => {
    expect(redacted('Authorization: Bearer eyJhbGciOiJIUzI1NiJ9.abc.def')).toBe('Authorization: Bearer [REDACTED]')
    const hex = 'a'.repeat(48)
    expect(redacted(`api_key = "${hex}"`)).toBe('api_key = [REDACTED]')
    expect(redacted(`token: ${hex}`)).toBe('token: [REDACTED]')
  })

  it('leaves long identifiers and fixture hashes alone when nothing labels them a secret', () => {
    const fn = 'nvmlDeviceGetCurrentClocksThrottleReasonsExtendedVariantForTesting'
    const sha = 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855'
    const r = redactSecrets(`${fn}() returned ${sha}`)
    expect(r.text).toBe(`${fn}() returned ${sha}`)
    expect(r.redactionCount).toBe(0)
  })

  it('keeps email domains and rewrites home paths', () => {
    expect(redacted('mail frednix@gmail.com from /home/pi/Projects/x and /Users/fred/x')).toBe('mail [user]@gmail.com from ~/Projects/x and ~/x')
  })

  it('masks public IPv4 but not private, loopback or CGNAT', () => {
    const r = redactSecrets('10.0.0.5 192.168.1.9 172.20.0.1 127.0.0.1 100.115.139.100 8.8.8.8 203.0.113.7')
    expect(r.text).toBe('10.0.0.5 192.168.1.9 172.20.0.1 127.0.0.1 100.115.139.100 8.8.x.x 203.0.x.x')
    expect(r.redactionCount).toBe(2)
  })

  it('does not treat a version-ish dotted number over 255 as an IP', () => {
    expect(redacted('v300.1.2.3')).toBe('v300.1.2.3')
  })
})
