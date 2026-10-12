import { afterEach, describe, expect, it, vi } from 'vitest'

// The account, as the passwd entry gives it: a fixture, never the shell of whoever runs the tests.
const account = vi.hoisted(() => ({ shell: (): string | null => null }))
vi.mock('node:os', async (original) => ({ ...await original<typeof import('node:os')>(), userInfo: () => ({ shell: account.shell() }) }))

import { currentUserShell } from './userShell.js'

const given = process.env.SHELL

afterEach(() => {
  if (given === undefined) delete process.env.SHELL
  else process.env.SHELL = given
  account.shell = () => null
})

describe('the person\'s shell', () => {
  it('is SHELL when the daemon was given one', () => {
    process.env.SHELL = '/bin/zsh'
    account.shell = () => '/bin/bash'
    expect(currentUserShell()).toBe('/bin/zsh')
  })

  it('is the account\'s own when the daemon was given none, or one that is no path', () => {
    // `docker exec`, a CI step, a bare service: no shell handed SHELL on, and the account still has one.
    account.shell = () => '/bin/bash'
    delete process.env.SHELL
    expect(currentUserShell()).toBe('/bin/bash')
    process.env.SHELL = 'zsh'
    expect(currentUserShell()).toBe('/bin/bash')
  })

  it('is none when the account has no usable shell either', () => {
    delete process.env.SHELL
    expect(currentUserShell()).toBeUndefined()
    account.shell = () => 'sh'
    expect(currentUserShell()).toBeUndefined()
    // No passwd entry for this user id (a container run as an arbitrary uid): Node throws.
    account.shell = () => { throw new Error('ENOENT: no such file or directory, uv_os_get_passwd') }
    expect(currentUserShell()).toBeUndefined()
  })
})
