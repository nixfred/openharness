/**
 * What the person lets agents do (lib/agentSettings.ts), turned on for a test: a signed-in session in the test's own
 * auth folder (`HARNESS_AUTH_DIR`, vitest.setup.ts; an end-to-end daemon's own) and the copy the core's sync would
 * keep for it. In the product the copy is the sync's alone (core/experiments.ts); a test that is not about the sync
 * writes it here.
 */
import { AGENT_SETTINGS_DEFAULTS, readAgentSettings, saveAgentSettings, type AgentSettings } from '../lib/agentSettings.js'
import { clearAuthSession, readAuthSession, writeAuthSession, type AuthSession } from '../lib/authSession.js'

/** The account and machine a test signs in as, unless its session names others. */
export const TEST_ACCOUNT = { accountId: 'account-test', machineId: 'machine-test' }

/** The session in the test's auth folder, signed in as TEST_ACCOUNT when there is none. */
export function signedInForTest(): AuthSession {
  const existing = readAuthSession()
  if (existing?.machineId) return existing
  const session: AuthSession = { version: 1, accessToken: 'test-token', autonomousEnv: 'prod', computerId: 'computer-test', machineId: TEST_ACCOUNT.machineId, updatedAt: 0 }
  writeAuthSession(session)
  return session
}

/** Signs the test's auth folder out again. */
export const signedOutForTest = (): void => clearAuthSession()

/** Turns [settings] on (or off) in [dataDir] for the signed-in test account; the rest stay as they were. */
export function setAgentSettingsForTest(dataDir: string, settings: Partial<AgentSettings>): AgentSettings {
  const session = signedInForTest()
  const next = { ...AGENT_SETTINGS_DEFAULTS, ...readAgentSettings(dataDir, session), ...settings }
  saveAgentSettings(dataDir, { accountId: session.signInAcct ?? TEST_ACCOUNT.accountId, machineId: session.machineId! }, next)
  return next
}
