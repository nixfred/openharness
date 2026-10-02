#!/usr/bin/env python3
"""The pets on the Focus agent screen: pixel art that stands in for an engine's static mark.

    python3 devices/harness-device/firmware/scripts/gen_pets.py          # write
    python3 devices/harness-device/firmware/scripts/gen_pets.py --check  # fail if stale

Claude Code: a 12 x 8 cell sprite at 5 px per cell plus one spare row on top, 60 x 45 px per frame.
Codex: a 14 x 14 cell cloud-headed robot at 4 px per cell, 56 x 56 px per frame.
Each state (idle, working, done, asking) is a loop of 24 steps, each a frame and a vertical offset in
px, on the Pro daemons' clock. Frames are de-duplicated per pet, so the file holds each pose once and
the loops index it. Writes main/ui/habitat/pets.c: each pet's frames, loops and step_ms, and the
registry ht_pets[] / ht_pet_count (declared in pets.h). Frames use the same encoding as
gen_focus_marks.py: RGB565 in panel order plus alpha8 (0 or 255 only).
"""
import sys
from pathlib import Path

from PIL import Image, ImageDraw

root = Path(__file__).resolve().parents[1]
STEPS = 24

# ---- Claude Code ----
CELL = 5
W, H = 12 * CELL, 9 * CELL
BODY = (204, 120, 92)
EYE = (0, 0, 0)
LEGS = (2, 4, 7, 9)                  # leg columns
STEP_MS = (150, 90, 55, 140)         # idle, working, done, asking


def sprite(eyes='open', arms=0, legs=(2, 2, 2, 2), look=0):
    """One pose as {(col, row): colour}. arms: 0 level, -1 raised one row. legs: rows per leg."""
    cells = {}
    for r in range(6):
        for c in range(2, 10):
            cells[(c, r)] = BODY
    for r in (2 + arms, 3 + arms):
        for c in (0, 1, 10, 11):
            cells[(c, r)] = BODY
    for c, n in zip(LEGS, legs):
        for r in range(6, 6 + n):
            cells[(c, r)] = BODY
    if eyes == 'open':
        cells[(3 + look, 1)] = EYE
        cells[(8 + look, 1)] = EYE
    elif eyes == 'happy':            # ^ ^ : the eye cell lifted a row
        for c in (3, 8):
            cells[(c, 0)] = EYE
    return cells                     # 'closed' leaves the eyes as body


def idle():
    bob = (0,) * 6 + (1,) * 6 + (0,) * 6 + (1,) * 6
    return [(sprite('closed' if i in (20, 21) else 'open'), bob[i]) for i in range(STEPS)]


def working():
    out = []
    for i in range(STEPS):
        phase = (i // 3) % 4
        legs = [(2, 1, 2, 1), (2, 2, 2, 2), (1, 2, 1, 2), (2, 2, 2, 2)][phase]
        look = ([0] * 6 + [1] * 6 + [0] * 6 + [-1] * 6)[i]
        out.append((sprite('open', 0, legs, look), 0 if phase in (1, 3) else -1))
    return out


def done():
    hop = (0, -1, -2, -3, -4, -4, -3, -2, -1, 0, 0, 0)
    out = []
    for i in range(STEPS):
        if i < 12:
            arms = -1 if hop[i] < -1 else 0
            legs = (2, 2, 2, 2) if hop[i] == 0 else (1, 1, 1, 1)
            out.append((sprite('happy', arms, legs), hop[i] * CELL // 2))
        else:
            out.append((sprite('happy' if i < 20 else 'open'), 0))
    return out


def asking():
    return [(sprite('open', -1 if (i // 4) % 2 == 0 else 0), 0) for i in range(STEPS)]


def render(cells):
    """Row r at y = (r + 1) * CELL: the spare row on top is for the hop."""
    im = Image.new('RGBA', (W, H), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    for (c, r), col in cells.items():
        y = r * CELL + CELL
        d.rectangle([c * CELL, y, c * CELL + CELL - 1, y + CELL - 1], fill=col)
    return im



# ---- Codex ----
XCELL = 4
XW = XH = 14 * XCELL
XSTEP_MS = (150, 90, 55, 140)
HI = (138, 162, 255)      # cloud highlight
BLUE = (92, 124, 240)     # cloud / body
SHADE = (63, 91, 208)     # underside
SCREEN = (27, 34, 68)     # the face's screen
GLOW = (127, 240, 230)    # terminal glyphs

# The head: a cloud with three bumps on top, rows 0-7.
HEAD = [
    "....HHH.HHH...",
    "..HHBBBHBBBH..",
    ".HBBBBBBBBBBH.",
    "HBBBBBBBBBBBBH",
    "HBBBBBBBBBBBBB",
    "BBBBBBBBBBBBBB",
    "SBBBBBBBBBBBBS",
    ".SSBBBBBBBBSS.",
]
# The screen sits on the face, rows 2-6, cols 3-10 (8 x 5 cells).
SX, SY, SW, SH = 3, 2, 8, 5


def xbase(arms=0, legs=(1, 1)):
    cells = {}
    pal = {'H': HI, 'B': BLUE, 'S': SHADE}
    for r, row in enumerate(HEAD):
        for c, ch in enumerate(row):
            if ch in pal:
                cells[(c, r)] = pal[ch]
    for r in range(SY, SY + SH):
        for c in range(SX, SX + SW):
            cells[(c, r)] = SCREEN
    # Body rows 8-11, cols 4-9; a tiny ">-" on the chest.
    for r in range(8, 12):
        for c in range(4, 10):
            cells[(c, r)] = BLUE if r < 11 else SHADE
    cells[(5, 9)] = GLOW
    cells[(7, 9)] = GLOW
    cells[(8, 9)] = GLOW
    # Arms: one cell each side, rows 9-10, raised one row when arms = -1.
    for r in (9 + arms, 10 + arms):
        cells[(3, r)] = BLUE
        cells[(10, r)] = BLUE
    # Legs: cols 5 and 8, rows 12.. (1 or 2 rows).
    for c, n in zip((5, 8), legs):
        for r in range(12, 12 + n):
            cells[(c, r)] = SHADE
    return cells


def glyphs(cells, marks):
    for c, r in marks:
        cells[(SX + c, SY + r)] = GLOW
    return cells


PROMPT = [(1, 1), (2, 2), (1, 3)]               # ">"
CHECK = [(1, 2), (2, 3), (3, 2), (4, 1), (5, 0)]  # a tick
QUESTION = [(3, 0), (4, 0), (5, 1), (4, 2), (4, 4)]
HAPPY = [(1, 2), (2, 1), (3, 2), (5, 2), (6, 1), (7, 2)]  # ^ ^


def xface(prompt=True, cursor=True, typed=0, extra=()):
    marks = list(PROMPT) if prompt else []
    for i in range(typed):                       # dots typed before the cursor
        marks.append((4 + i, 3))
    if cursor:
        marks += [(4 + typed, 3), (5 + typed, 3)] if 5 + typed < SW else []
    return marks + list(extra)


def xidle():
    out = []
    for i in range(STEPS):
        on = (i // 4) % 2 == 0                   # the cursor blinks
        out.append((glyphs(xbase(), xface(cursor=on)), 1 if i % 12 >= 6 else 0))
    return out


def xworking():
    out = []
    for i in range(STEPS):
        typed = (0, 1, 2, 1)[(i // 3) % 4]       # dots run across and back
        legs = [(1, 2), (1, 1), (2, 1), (1, 1)][(i // 3) % 4]
        out.append((glyphs(xbase(0, legs), xface(typed=typed)), 0 if (i // 3) % 2 else -1))
    return out


def xdone():
    hop = (0, -1, -2, -3, -4, -4, -3, -2, -1, 0, 0, 0)
    out = []
    for i in range(STEPS):
        if i < 12:
            out.append((glyphs(xbase(-1 if hop[i] < -1 else 0), HAPPY), hop[i] * XCELL // 2))
        else:
            out.append((glyphs(xbase(), CHECK), 0))
    return out


def xasking():
    return [(glyphs(xbase(-1 if (i // 4) % 2 == 0 else 0), QUESTION), 0) for i in range(STEPS)]


def xrender(cells):
    """Row r at y = r * XCELL; the hop is the loop's dy, not part of the image."""
    im = Image.new('RGBA', (XW, XH), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    for (c, r), col in cells.items():
        y = r * XCELL
        d.rectangle([c * XCELL, y, c * XCELL + XCELL - 1, y + XCELL - 1], fill=col)
    return im

def emit(name, img):
    w, h = img.size
    px, alpha = [], []
    for r, g, b, a in img.get_flattened_data():
        v = ((r & 0xF8) << 8) | ((g & 0xFC) << 3) | (b >> 3)
        px.append(((v << 8) | (v >> 8)) & 0xFFFF)
        alpha.append(255 if a else 0)
    return (f'static const uint16_t {name}_px[] = {{' + ','.join(map(str, px)) + '};\n'
            f'static const uint8_t {name}_a[] = {{' + ','.join(map(str, alpha)) + '};\n',
            f'{{{w},{h},{name}_px,{name}_a}}')


# engine, prefix, frame size, the four states, renderer, step_ms
PETS = (
    ('claude', 'claude', (W, H), (idle, working, done, asking), render, STEP_MS),
    ('codex', 'codex', (XW, XH), (xidle, xworking, xdone, xasking), xrender, XSTEP_MS),
)


def generate_pet(prefix, states, draw):
    frames, index, loops = [], {}, []
    for state in states:
        steps = []
        for cells, dy in state():
            key = tuple(sorted(cells.items()))
            if key not in index:
                index[key] = len(frames)
                frames.append(cells)
            steps.append((index[key], dy))
        loops.append(steps)
    out, refs = [], []
    for n, cells in enumerate(frames):
        code, ref = emit(f'{prefix}{n}', draw(cells))
        out.append(code)
        refs.append(ref)
    return out, refs, loops


def generate():
    out = ['// Generated by scripts/gen_pets.py. Do not edit.\n'
           '// The pets: per engine the de-duplicated frames and the idle/working/done/asking loops.\n'
           '#include "pets.h"\n']
    table, counts = [], []
    for engine, prefix, (w, h), states, draw, step_ms in PETS:
        code, refs, loops = generate_pet(prefix, states, draw)
        out += code
        counts.append(len(refs))
        out.append(f'static const ht_icon_t {prefix}_frames[{len(refs)}] = {{' + ','.join(refs) + '};\n')
        rows = ['{' + ','.join(f'{{{f},{dy}}}' for f, dy in steps) + '}' for steps in loops]
        out.append(f'static const ht_pet_step_t {prefix}_loops[HT_PET_STATES][HT_PET_STEPS] = {{' + ','.join(rows) + '};\n')
        out.append(f'static const uint16_t {prefix}_step_ms[HT_PET_STATES] = {{' + ','.join(map(str, step_ms)) + '};\n')
        table.append(f'{{"{engine}",{w},{h},{prefix}_frames,{prefix}_loops,{prefix}_step_ms}}')
    out.append('const ht_pet_t ht_pets[] = {' + ','.join(table) + '};\n')
    out.append(f'const unsigned ht_pet_count = {len(PETS)};\n')
    return ''.join(out), counts


def main():
    text, counts = generate()
    target = root / 'main/ui/habitat/pets.c'
    if '--check' in sys.argv[1:]:
        if not target.exists() or target.read_text() != text:
            print(f'{target} is stale: run scripts/gen_pets.py', file=sys.stderr)
            return 1
        return 0
    target.write_text(text)
    for (engine, _, (w, h), *_), n in zip(PETS, counts):
        print(f'{engine}: {n} frames, {n * w * h * 3} bytes')
    print(f'wrote {target}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
