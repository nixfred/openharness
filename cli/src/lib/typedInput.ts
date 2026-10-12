/**
 * Whether a terminal's input frame is the person typing, or what the terminal sends by itself.
 *
 * A window's or the phone's terminal answers the engine's queries and reports what happens to it, unasked: a device
 * attribute report (`ESC [ ? 1 ; 2 c`), the cursor's position, the colours (`ESC ] 11 ; rgb:… ESC \`), focus in and
 * out (`ESC [ I`, `ESC [ O`), the mouse over a pane that tracks it. Every harness another agent starts now opens as a
 * pane beside its starter (docs/design/2026-10-11-agent-client.md), so those reports reach almost every one of them:
 * taken for typing, they made every such harness the person's, and the agent cleanup never closed one
 * (services/agentCleanup.ts). Typing is what is left once they are taken out: a letter, Enter, Backspace, Ctrl-C.
 * Arrow keys and other keys sent as escape sequences are not counted: moving around a pane is not giving it work.
 */

const ESC = 0x1b

const isAlnum = (byte: number): boolean => (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x5a) || (byte >= 0x61 && byte <= 0x7a)

/** The end of the escape sequence that starts at [i] (an ESC with a byte after it), the index after it. */
function sequenceEnd(bytes: Uint8Array, i: number): number {
  const kind = bytes[i + 1]
  // CSI: parameters, intermediates, one final byte. `ESC [ M` with three bytes after it is the old mouse report,
  // whose three bytes can be letters.
  if (kind === 0x5b) {
    let j = i + 2
    while (j < bytes.length && bytes[j] >= 0x30 && bytes[j] <= 0x3f) j++
    while (j < bytes.length && bytes[j] >= 0x20 && bytes[j] <= 0x2f) j++
    return bytes[j] === 0x4d && j === i + 2 ? j + 4 : j + 1
  }
  // OSC, DCS, SOS, PM, APC: a string to BEL or ESC \.
  if (kind === 0x5d || kind === 0x50 || kind === 0x58 || kind === 0x5e || kind === 0x5f) {
    for (let j = i + 2; j < bytes.length; j++) {
      if (bytes[j] === 0x07) return j + 1
      if (bytes[j] === ESC && bytes[j + 1] === 0x5c) return j + 2
    }
    return bytes.length
  }
  // SS3 (`ESC O A`, an arrow key in application mode): one byte after it.
  if (kind === 0x4f) return i + 3
  // Alt with a letter or a digit is typing: the letter is read next, as is a second ESC (Alt with an arrow key). Any
  // other pair is the terminal's.
  return isAlnum(kind) || kind === ESC ? i + 1 : i + 2
}

/**
 * Whether [bytes] hold anything the person typed: a byte outside every escape sequence the terminal sends itself.
 * Escape alone, the key, is the person's: it interrupts the engine's turn.
 */
export function typedByPerson(bytes: Uint8Array): boolean {
  if (bytes.length === 1 && bytes[0] === ESC) return true
  for (let i = 0; i < bytes.length;) {
    if (bytes[i] !== ESC) return true
    i = sequenceEnd(bytes, i)
  }
  return false
}
