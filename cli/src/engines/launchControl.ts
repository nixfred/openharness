/** Eager native launch control. Importing it neither probes a binary nor reads or writes a store. */
import { opencodeBinAsync } from '../lib/engineBin.js'
import { sqliteReadAll } from '../lib/sqliteRead.js'
import { OPENCODE_SESSION_MODEL, OPENCODE_V2_TURN, OPENCODE_VERSION } from './opencode/contract.js'
import { executableSnapshot, majorVersion, nativeVersionProbe, parseMajor, type NativeExecutableSnapshot, type VersionProbe } from './kit/nativeVersion.js'
import { createSessionModelControl, type NativeApiRun, type NativeModelResult, type NativeSessionModel, type NativeModelAuthority } from './kit/nativeSessionModel.js'
export { isOpencodeV2 } from './opencode/contract.js'

/** Whether OpenCode 2 session [sessionId] is in a turn, read from [dbPath] (`OPENCODE_V2_TURN`). Null when
 *  the store cannot be read. */
export async function opencodeV2TurnOpen(dbPath: string, sessionId: string): Promise<boolean | null> {
  if (!OPENCODE_SESSION_MODEL.id.test(sessionId)) return null
  const result = await sqliteReadAll(dbPath, OPENCODE_V2_TURN.sql, [sessionId])
  if (!result.ok) return null
  return result.rows[0]?.type === OPENCODE_V2_TURN.opens
}

export type OpencodeVersionProbe = VersionProbe
const versionMemo = new Map<string, number | null>()
export const parseOpencodeMajor = (output: string): number | null => parseMajor(OPENCODE_VERSION, output)
export async function opencodeMajorVersion(probe?: VersionProbe, memo = versionMemo): Promise<number | null> {
  if (!probe) {
    const binary = await opencodeBinAsync()
    probe = nativeVersionProbe(OPENCODE_VERSION, () => binary)
  }
  return majorVersion(OPENCODE_VERSION, probe, memo)
}

export interface OpencodeLaunchSnapshot extends NativeExecutableSnapshot { major: number }
export async function opencodeLaunchSnapshot(binary?: string): Promise<OpencodeLaunchSnapshot | null> {
  const command = binary ?? await opencodeBinAsync()
  const probe = nativeVersionProbe(OPENCODE_VERSION, () => command)
  const executable = executableSnapshot(probe)
  if (!executable) return null
  const major = await majorVersion(OPENCODE_VERSION, probe, versionMemo)
  return major !== null && executable.current() ? { ...executable, major } : null
}

export type OpencodeSessionModel = NativeSessionModel
export type SetOpencodeSessionModelResult = NativeModelResult
export type OpencodeApiRun = NativeApiRun
const model = createSessionModelControl(OPENCODE_SESSION_MODEL, opencodeBinAsync)
export const opencodeModelFromArgv = model.modelFromArgv
export const parseOpencodeModelId = model.parseModelId
export const setOpencodeSessionModel = model.setSessionModel
export const switchOpencodeSessionModel = model.switchSessionModel
export function applyOpencodeSessionModel(
  input: { opencodeMajor: number | null | undefined; dbPath: string; sessionId: string; model: NativeSessionModel; cwd?: string; checkCatalog?: boolean },
  deps: { run?: NativeApiRun; retryDelayMs?: number } & NativeModelAuthority = {},
): Promise<NativeModelResult> { return model.applySessionModel({ ...input, major: input.opencodeMajor }, deps) }
