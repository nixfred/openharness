/**
 * nixfred: mark each item of a PERMISSION dialog with `permission: true`.
 *
 * The daemon already knows (QuestionView.permission); the dial did not, so a permission prompt and an
 * ordinary question looked the same on the glass. The nixfred firmware draws the red ring and the lock
 * for it. Per item rather than beside `questions` because `questions` is the one thing that travels
 * unchanged through both paths to the dial (`question` and the inbox's `question.state`). A dial that
 * predates it ignores an unknown key. An ordinary question is returned as the same array.
 *
 * Its own module so the core (core/questions.ts) can mark a question without importing the cable host,
 * which runs in the devices' process (services/devices.ts). cable/cableHost.ts re-exports it.
 */
export function withPermissionFlag<T>(questions: T[], permission: boolean): T[] {
  if (!permission) return questions
  return questions.map((q) => (q && typeof q === 'object' ? { ...q, permission: true } : q))
}
