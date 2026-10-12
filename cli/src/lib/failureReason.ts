/**
 * Why a program that exited with a failure failed, in its own words: one line of what it printed.
 *
 * The line that says what failed comes first ("No such file or directory", "Could not resolve host",
 * "… failed, reason: getaddrinfo ENOTFOUND …"), then one that names an error, then the first line. A
 * Node stack trace starts with a source location and ends with the Node version, and npm ends with
 * where its log is, so neither end is the reason. Harness's own lines in an installer's output
 * (`harness: …`) are never the reason. [otherwise] is said when it printed nothing at all.
 */
export function failureReason(output: string, otherwise: string): string {
  const lines = output.split('\n').map(line => line.replace(/[\x00-\x1f\x7f]/g, ' ').trim()).filter(line => line && !line.startsWith('harness:'))
  const line = lines.find(text => /\b(failed|could not|cannot|can't|no such|not found|denied|refused|timed out|unable|missing)\b/i.test(text))
    ?? lines.find(text => /\berror\b/i.test(text)) ?? lines[0]
  return line ? line.slice(0, 300) : otherwise
}
