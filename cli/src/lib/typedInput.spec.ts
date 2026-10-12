import { describe, expect, it } from 'vitest'
import { typedByPerson } from './typedInput.js'

const bytes = (text: string): Uint8Array => new TextEncoder().encode(text)

describe('whether a terminal input frame is the person typing', () => {
  it('counts what a person types: letters, Enter, Backspace, Ctrl-C, Escape, Alt with a key, a paste', () => {
    for (const typed of ['a', 'hello', '\r', '\x7f', '\x03', '\x1b', '\x1bb', '\x1b1', '\x1b[200~fix it\x1b[201~', '\x1b[Ax']) {
      expect(typedByPerson(bytes(typed)), JSON.stringify(typed)).toBe(true)
    }
  })

  it('does not count what the terminal sends by itself, nor keys that only move around', () => {
    for (const reply of [
      '', '\x1b[?1;2c', '\x1b[>0;276;0c', '\x1b[12;40R', '\x1b[I', '\x1b[O', // attributes, cursor, focus
      '\x1b]11;rgb:0000/0000/0000\x1b\\', '\x1b]10;rgb:ffff/ffff/ffff\x07', '\x1bP1$r0m\x1b\\', '\x1b]52;c;', // colours, a DCS reply, unended
      '\x1b[<0;10;5M', '\x1b[<0;10;5m', '\x1b[M #!', // the mouse, in both encodings
      '\x1b[A', '\x1b[1;5C', '\x1bOA', '\x1b[3~', '\x1b[15~', '\x1b\x1b[A', '\x1b=', '\x1b[', // keys that move, and halves
    ]) expect(typedByPerson(bytes(reply)), JSON.stringify(reply)).toBe(false)
  })
})
