/** Read a small literal subset of code-mode calls. This never evaluates JavaScript. */
function literal(source: string): unknown {
  let at = 0
  const fail = (): never => { throw new Error('Not a literal') }
  const space = () => { while (/\s/.test(source[at] ?? '') && at < source.length) at++ }
  function string(): string {
    const quote = source[at++]
    let result = ''
    while (at < source.length) {
      let ch = source[at++]
      if (ch === quote) return result
      if (quote === '`' && ch === '$' && source[at] === '{') fail()
      if (ch === '\n' && quote !== '`') fail()
      if (ch === '\\') {
        ch = source[at++]
        if (ch === undefined) fail()
        if (ch === '\n') continue
        if (ch === 'u' || ch === 'x') {
          const count = ch === 'u' ? 4 : 2, digits = source.slice(at, at + count)
          if (digits.length !== count || !/^[a-f0-9]+$/i.test(digits)) fail()
          result += String.fromCharCode(parseInt(digits, 16)); at += count; continue
        }
        if (/\d/.test(ch)) fail() // Legacy octal and \0 are not needed for tool arguments.
        result += ({ n: '\n', r: '\r', t: '\t', b: '\b', f: '\f', v: '\v' } as Record<string, string>)[ch] ?? ch
      } else result += ch
    }
    return fail()
  }
  function value(depth = 0): unknown {
    if (depth > 4) fail()
    space()
    const ch = source[at]
    if (["'", '"', '`'].includes(ch)) return string()
    if (ch === '{') {
      at++; space()
      const result: Record<string, unknown> = Object.create(null)
      let count = 0
      while (source[at] !== '}') {
        if (++count > 32) fail()
        space()
        let key: string
        if (["'", '"'].includes(source[at])) key = string()
        else {
          const identifier = /^[a-zA-Z_$][\w$]*/.exec(source.slice(at))?.[0]
          if (!identifier) fail()
          key = identifier!; at += key.length
        }
        if (Object.hasOwn(result, key)) fail()
        space(); if (source[at++] !== ':') fail()
        result[key] = value(depth + 1); space()
        if (source[at] === '}') break
        if (source[at++] !== ',') fail()
        space()
      }
      at++; return result
    }
    if (ch === '[') {
      at++; space()
      const result: unknown[] = []
      while (source[at] !== ']') {
        if (result.length >= 32) fail()
        result.push(value(depth + 1)); space()
        if (source[at] === ']') break
        if (source[at++] !== ',') fail()
        space()
      }
      at++; return result
    }
    const primitive = /^(?:true|false|null|-?(?:0|[1-9]\d*)(?:\.\d+)?(?:[eE][+-]?\d+)?)/.exec(source.slice(at))?.[0]
    if (!primitive) fail()
    at += primitive!.length
    return JSON.parse(primitive!)
  }
  const result = value()
  space(); if (at !== source.length) fail()
  return result
}

export function literalToolCall(raw: string): { name: string; input: unknown } | null {
  if (raw.length > 128 * 1024) return null
  const source = raw.replace(/^\s*\/\/ @exec:[^\n]*\n/, '').trim()
  const wrapped = /^text\(\s*await\s+tools\.(exec_command|apply_patch|write_stdin)\(([\s\S]*)\)\s*\)\s*;?$/.exec(source)
    ?? /^await\s+tools\.(exec_command|apply_patch|write_stdin)\(([\s\S]*)\)\s*;?$/.exec(source)
  const assigned = /^(?:const|let)\s+([a-zA-Z_$][\w$]*)\s*=\s*await\s+tools\.(exec_command|apply_patch|write_stdin)\(([\s\S]*)\)\s*;\s*text\(\s*\1\s*\)\s*;?$/.exec(source)
  const name = wrapped?.[1] ?? assigned?.[2], argument = wrapped?.[2] ?? assigned?.[3]
  if (!name || argument === undefined) return null
  try { return { name, input: literal(argument) } } catch { return null }
}
