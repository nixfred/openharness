import { stripVTControlCharacters } from 'node:util'

export function screenLines(capture: string): { lines: string[]; raw: string[] } {
  const raw = capture.split('\n')
  const lines = raw.map((line) => stripVTControlCharacters(line).replace(/ /g, ' ').trimEnd())
  while (lines.length && !lines.at(-1)) { lines.pop(); raw.pop() }
  return { lines, raw }
}

/** Whether the first character of a row is drawn bold: the SGR in force when it is written. */
export function startsBold(row: string): boolean {
  let bold = false
  const sgr = /^\u001b\[([0-9;:]*)m/
  let rest = row
  for (let match = sgr.exec(rest); match; match = sgr.exec(rest)) {
    for (const code of match[1].split(/[;:]/)) {
      if (code === '1') bold = true
      else if (code === '' || code === '0' || code === '22') bold = false
    }
    rest = rest.slice(match[0].length)
  }
  return bold
}

/** The background an SGR leaves in force: `48;…` (one parameter with colons, or its own run of parameters), `4x`/`10x`,
 *  or none after a reset (`0`, `49`, an empty SGR). A foreground's `38;…` run is skipped, never read as codes. */
function background(params: string, bg: string | null): string | null {
  const parts = params.split(';')
  for (let i = 0; i < parts.length; i++) {
    const code = parts[i].split(':')[0]
    if (code === '' || code === '0' || code === '49') bg = null
    else if (code === '38' || code === '48') {
      const run = parts[i].includes(':') ? 0 : parts[i + 1] === '5' ? 2 : parts[i + 1] === '2' ? 4 : 0
      if (code === '48') bg = parts.slice(i, i + 1 + run).join(';')
      i += run
    } else if (/^(?:4[0-7]|10[0-7])$/.test(code)) bg = code
  }
  return bg
}

/** Each row's background where its first cell is drawn, null for the terminal's own. A capture carries
 *  attributes from one row into the next, so a blank row inside a shaded block is shaded too. */
export function rowBackgrounds(raw: readonly string[]): (string | null)[] {
  const sgr = /\u001b\[([0-9;:]*)m/g
  let bg: string | null = null
  return raw.map((row) => {
    // The background in force once the SGRs in front of the row's first character have run.
    let first: string | null | undefined
    let at = 0
    for (const match of row.matchAll(sgr)) {
      if (first === undefined && match.index !== at) first = bg
      bg = background(match[1], bg)
      at = match.index + match[0].length
    }
    return first === undefined ? bg : first
  })
}

/** The word being typed at the end of a draft, where a `/command` or an `@mention` opens its popup. */
export function typedToken(draft: string): string {
  return draft.split(/\s/).at(-1) ?? ''
}

