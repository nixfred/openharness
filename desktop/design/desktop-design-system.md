# Harness desktop design system

The canonical system for everything around terminal panes. This supersedes
older BIOS, bracket-button and mixed desktop recipes. The user-approved
direction is the authority: refine one system, then use it everywhere.

## Character

A calm, precise Mac workspace. Content supplies the personality: an agent's
real mark, a session name, a useful preview. Surfaces organize; they do not
compete. System typography, comfortable density, consistent optical alignment,
quiet neutral controls and a deliberate blue selection are the visual language.
No ornamental gradients, noisy borders, imitation terminal forms or gratuitous
animation. Keep the live terminal, terminal font, status glyphs and native tabs.

The Spotlight references guide search hierarchy and recognizable identity.
They are inspiration, not a claim of Apple authorship or pixel-identical AppKit.

## The design brief

Harness should feel like a precise, welcoming instrument for working with agents.
The terminal is the working surface. Starting, finding and arranging work should
feel effortless around it. Opening a picker should lower the amount the person
has to think about; closing it should return them to exactly where they were.

Our interpretation of Jony Ive's published emphasis on "bringing order to
complexity" is to design these relationships before their decoration. It is not
a prediction of what he or his team would make. See the
[research and comparison record](macos-design-research.md) for primary sources.

Five decisions give this system its character:

1. **One focal point per surface.** The task in Cmd-N, the query and selected
   result in Cmd-P, the name in Rename. Configuration stays visible but quiet.
   Only the action that completes the task has a strong filled treatment.
2. **Depth has a job.** The workspace, one floating task surface, and an anchored
   child picker are distinct layers. A child menu stays attached to its source;
   its parent loses active emphasis. Opaque content protects legibility over
   busy terminals. Decorative glass, refraction and stacks of translucent cards
   are not part of this implementation.
3. **Content supplies identity.** Real agent marks and clear names carry color
   and recognition. System symbols explain actions. Text needs no extra symbol
   unless the symbol makes the action faster to recognize.
4. **Proportion is deliberate.** A short form has a short reading line. The
   space around a heading relates to the fields below it. Nested corners share
   a rhythm. Controls keep their bounds through hover, focus and press.
5. **Continuity is part of the finish.** Typing never moves its own field.
   Search scopes preserve the query. Menus open at the expected edge, dismiss
   one level at a time and return focus. Drafts survive dismissal. Immediate
   feedback takes priority over a decorative transition.

The benchmark is the relationship between surfaces, not a collection of good
looking individual dialogs. Rename and Move Pane have different content but
must clearly belong to the same application when viewed beside Cmd-N and Cmd-P.

## Bringing order to machines, agents and models

The interface follows the person's task, not the internal service architecture.
Show each decision where it changes the outcome, and disclose the next level
from the control that owns it.

| Person's decision | Visible place | Relationship to preserve |
| --- | --- | --- |
| What should happen? | Prompt, then the terminal's work | The task remains the focal point |
| Where is the project? | Project selector; machine inside its search row | A folder belongs to a machine; its path is not globally interchangeable |
| Which agent or specialized harness? | Agent selector, with its real mark | A specialized harness can run with an agent framework: “Run Blender with” |
| Which model and effort? | Model control and its options | Available models belong to the selected agent and connection |
| What may it do? | Visible approvals control | Preserve the explicit setting; never hide a permission change behind styling |
| How is the work isolated? | Worktree and branch together | Fresh main default, remembered worktree choice, reviewed draft kept intact |
| Which work am I returning to? | Session name in tabs/search, with machine/project context when useful | Session identity stays stable when its model or activity changes |

The footer describes the focused work. Creation controls describe the next
launch. Search scopes describe the result set. Do not mix those contexts or repeat
all machine, framework and model details in every row. Reveal extra context when
names are ambiguous; full values remain available to accessibility and tooltips.

## Reference decisions

| Reference | What informs this system | Harness decision |
| --- | --- | --- |
| Apple Spotlight, including the user's references | Query first; recognizable identities; a clear selected row; secondary details separated from results | Compact scope pills, real agent marks, quiet toolbar, optional preview |
| Apple design system and Materials guidance | Layout and grouping establish hierarchy; curvature relates to its container; materials separate functional layers | Shared surface anatomy and concentric geometry; legible neutral panels rather than a simulated Liquid Glass effect |
| Things' task editor | Optional detail is available without competing with the task | A prompt-led composer with calm configuration and one completion action |
| Raycast's official design/engineering account | Native quality includes placement, focus, opening behavior and responsiveness | Check interaction continuity alongside screenshots; keep the user's requested hand cursor as a deliberate Harness choice |

Capsules are a deliberate part of Harness's requested control language, not a
claim that every Mac control should be a capsule. Apple retains rounded
rectangles for dense controls. Here, action buttons and scope/identity selectors
use capsules; fields, result rows and compact icon targets use related rounded
rectangles. Consistency means the same role looks and behaves the same everywhere.

## One implementation

`AppType` owns typography. `AppPalette` owns semantic colors. `AppDesktop` and
`AppControl` own geometry, focus, selection and control dimensions. `AppMenu`
owns floating surface colors. `buildAppTheme` applies those recipes to standard
Flutter buttons, fields, menus and dialogs. `DesktopChrome` exposes the same
values to creation, search and desktop presenters; it is not a second palette.

`DesktopDialogSurface` frames every custom dialog and chooser.
`DesktopDialogHeader` provides the shared title/dismiss anatomy.
`DesktopPromptSurface` keeps form actions visible beneath scrolling content.
`DesktopPill` is the selector/scope variant of the same control family.
`AppMenuItem` is the ordinary context-menu row. Controllers, keymaps, pending
receipts, transport state and persistence remain independent of presentation.

Do not solve a local styling problem by inventing another button or palette.
Use a named role below. If a new role is necessary, define it here and in shared
tokens before adopting it at call sites.

## Type and language

| Role | System face, size, weight | Use |
| --- | --- | --- |
| Display | 28, semibold | Welcome or sign-in title |
| Page title | 20, semibold | Settings or substantial detail page |
| Dialog / section heading | 17, semibold, 1.3 line height | Rename Tab, Move Pane |
| Body | 13–14, regular, 1.45 line height | Explanations and result names |
| Control | 13, regular or medium, 1.25 line height | Buttons and menu choices |
| Metadata | 12, regular, 1.35 line height | Context, counts, explanations |
| Search / task editor | 17 / 15, regular | Cmd-P and Cmd-N |

SF system typography on Apple platforms, system fallbacks elsewhere. Monospace
is explicit for code, copyable technical identifiers and shortcut hints; it is
not the default for navigation or session context. Terminal zoom never resizes
app controls. Platform text scaling does, and controls grow rather than clip.
Buttons keep at least 6 points of padding above and below the rendered label.
The fallback workspace tab strip and Harness Store control follow these same
rules, including platform text scaling; compact terminal/status bars retain
their separate sizing contract.

Names before context. Buttons state the action: New Harness, Save, Cancel,
Open Folder, New Folder, GitHub. Use short sentence-case instructions: Enter
project name, Enter GitHub URL, Run Blender with. Standard named destinations
retain their names, such as Harness Store and New Tab. Avoid repeated labels,
internal state names, decorative punctuation and implementation details.

## Color and state

Use semantic light/dark tokens throughout. Floating surfaces share the same
neutral material (`AppMenu.fill`); fields are one step inset, not another card.
A hairline rim and soft shadow separate floating content from its background.
Avoid repeatedly drawing cards inside a dialog.

- Primary text is nearly white or nearly black. Metadata remains readable.
- Blue filled capsules identify the primary action. Blue rows identify the
  active keyboard/pointer choice; their labels and secondary text turn white.
- A stored choice also has a checkmark. Focus and stored selection differ.
- Ordinary controls use a faint neutral fill and one thin rim. Hover increases
  the fill. Press increases it again. Focus has a stable 1.5-point blue boundary.
- Quiet inline controls beneath the creation prompt stay borderless. A subtle
  neutral fill identifies focus; Increase Contrast may add the focus boundary.
  Returning from a chooser must not leave a bright outline around the branch.
- Destructive actions use the shared danger fill or semantic error ink.
- Unavailable choices explain why and preserve useful previews. Disabled
  controls do not show a hand cursor. Color is never the only status signal.
- Increase Contrast strengthens boundaries. Reduce Motion removes optional
  motion. Live terminal content is never blurred or scaled for decoration.

The terminal's chosen color palette remains independent from UI focus blue.
All modal veils share one 95% token: black in dark appearance, white in light.
Cmd-N and Cmd-P must have exactly the same backdrop darkness, including coverage
of the native footer. Popovers have no independent full-window veil.

## Icons

The [icon design system](icon-design-system.md) defines the complete vocabulary,
size roles, state treatment, deliberate exceptions and audit workflow.

`AppIcons` owns one monochrome outline vocabulary: the regular (400) Lucide
family with rounded ends and joins. Use its named constants, never raw Material
icons, alternate stroke weights or text characters for app actions. A close
button always uses `AppIcons.close`; plus, search, back, disclosure, folder,
branch and check retain one silhouette everywhere.

Small pane split/zoom controls use the shared `AppPaneIcon` optical variants:
the same 24-unit grid, two-unit outline and round caps, with four-unit corners
so their rounding remains visible at 14 points. This includes Restore. The
close mark remains the unchanged Lucide ×; keep this adjustment in the shared
icon implementation, not in individual pane widgets.

Use 16-point icons beside text, 20 for standalone controls, and 24 for a feature
illustration. Center the drawing optically inside its role's target; icon-only
controls retain a 32-point target and a descriptive tooltip/accessibility label.
Workspace close marks are a quiet exception: 12-point Lucide × at 45% foreground,
with an optically matched 8-point regular SF Symbol in AppKit, inside the existing
click target. Hover or keyboard focus restores full ink;
Increase Contrast strengthens the resting mark. Tabs reveal the mark on hover,
while pane headers keep it visible. Neither changes geometry on interaction.
Use the surrounding text's semantic color. Hover changes emphasis or the shared
control fill, never the symbol, weight or position. Disabled icons stay legible
without suggesting an action. Agent, provider, service and product logos retain
their recognizable artwork; welcome recents keep the original color at a small
size so agent identity remains easy to distinguish.

AppKit-owned menus and toolbar controls use regular monochrome SF Symbols with
one shared sizing recipe, matching the system menus. Terminal text, user-chosen
Powerline symbols, activity marks and companion artwork retain their meaning;
they are content rather than competing app-control styles. Quantitative stars
use `AppRatingStar`: one rounded outline with a proportional fill. Connection
dots remain solid at their intended size; color is accompanied by status text.

## Geometry

| Role | Logical points |
| --- | --- |
| Spacing scale | 4, 8, 12, 16, 24 |
| Dialog outer radius | 20 |
| Popover outer radius | 16 |
| Field / inset row / pane radius | 10 |
| Tab upper corner / outward lower shoulder | 10 / 8 |
| Tab top inset | 6 |
| Tab close target inset from outer bounds | 8 |
| Pane close target trailing inset | 4 |
| Dialog content inset | 24 |
| Group / control gap | 16 / 8 |
| Menu inset | 6 |
| Standard / compact control minimum height | 32 / 28 |
| Standard field minimum height | 36 |
| Inline icon / search identity mark | 16 / 28 |
| Small form / destination chooser width | 460 |
| Creation composer maximum width | 680 |
| Search maximum width / height | 1120 / 680 |

Primary and secondary action buttons and scope selectors are capsules. Text
fields are rounded rectangles. Icon buttons have 32-point targets. Related
corners are concentric: an inset row is less rounded than its enclosing panel.
Widths describe content: agent 304, project 400, model 440, machine submenu 264;
all clamp to the available window. The project search grows with enlarged text
so its query and machine remain readable together. Never stretch a short list
to fill a page.

List anatomy is consistent: identity at left, name, optional useful secondary
context, then a checkmark, shortcut or disclosure at right. Text baselines and
accessory columns align. Specialized harness names need no marketing second
line. Machine menus align to the project popover's top edge with an 8-point gap,
then flip or constrain when the window has insufficient room.

## Surface families

**Task dialogs** — one heading, optional short explanation, fields, and fixed
trailing actions. Rename, confirmation, linking and sharing use the same type,
frame, padding and control states. Content scrolls before actions disappear.
`DesktopPromptScrollBody` shows a quiet, draggable scroll thumb when the body
overflows, including before the first scroll gesture. Text leaves 12 points of
clearance for the thumb. Short content has no visible scroll furniture; nested
editors keep their own input and scrolling behavior.

**Pickers** — the same frame and header, inset result rows and a quiet footer
with relevant keyboard hints. Move Pane uses a tab icon, destination name,
harness count and optional number accelerator. Selection uses the same blue
row treatment as search; no competing outlined selection card.

**History** — use the shared dialog header, search field and result rows.
The scope label is “This window”: these are the window's visited and closed
tabs and panes. Search receives initial focus. Tab reaches Close, and Enter on
Close dismisses the dialog without accepting a result. Results scroll and
reveal the active row without moving the search field. History keeps its
existing controller and does not add a preview.

**Cmd-P** — a prominent search field, separate compact scope pills, recognizable
agent marks and clean results. Harnesses is the default scope. Preserve typed
words when changing scope. Keep result selection stable through live updates.
Details remain in the existing optional preview. No second search index or
management implementation. Toolbar controls are secondary to the query. Keep
the editor and footer stationary while results update; do not resize the panel
on every keystroke or make short lists stretch their individual rows. On wide
windows, results take 44% and the preview 56% of the reading area. The panel
clamps to the window; narrower layouts retain their existing preview toggle.
Section headings use their natural text height with 8-point group spacing,
never a full result-row height. Loading, failed refresh and settled emptiness
are different states; keep existing results visible while refreshing.

**Cmd-N / New Tab** — one shared form and controller. Agent and project above
the “Harness anything” prompt; model, approvals and profile below; Worktree and
branch together.
The dialog is frameless over its veil. New Tab uses the same width on the page.
Agent and project capsules use an opaque neutral surface beneath their state
tints, so workspace text never shows through them. Machine stays inside the
repo search row.

**Welcome and New Tab hierarchy** — creation is primary. Show at most six rows
under “Recent harnesses”, separated from creation controls by 56 points. Use
small original-color agent marks and one muted neutral ink for names, context,
heading and timestamps. Use “now” for visits under one minute old. Context
reuses `StatusLine`, honoring the selected wording, machine/project/branch
visibility and status font, but omitting ANSI colors and segment backplates.
It is never a second renderer with a hard-coded dot separator.
A new user with no history sees the composer
without an empty recents section; initial project guidance is neutral. Empty
tabs hide the workspace footer, which returns when there is work to describe.
Before a creation machine is available, show “Harness anything”, a short next
step and a natural-width “Choose a machine” action. Keep that action available
while finding machines. While saved defaults load, show “Preparing your harness…”
in the same quiet hierarchy, then hand focus to the existing composer. Startup
must not leave a blank page or imply that a harness has already started.

Fresh forms focus the prompt and use the last explicit agent, project,
approvals and worktree choices. Fresh branches default to main; reopening a
draft preserves its selected branch. Enter submits except during composition.
Escape and outside click dismiss the innermost picker first, then the dialog;
they preserve its draft. Pending operations retain their existing close guards.
Opening any form or preview must never start work.
The GitHub entry starts with only “Enter GitHub URL”; a valid address reveals
its clone action and an invalid submission reveals inline validation. Do not
add a duplicate example line or an empty results area beneath an empty field.

**Workspace tabs and pane frames** — tabs use the 13-point system control face,
independent of the status bar and terminal font. Center the name and its adjacent
status as one compact group, without permanent number prefixes. Navigation ink
follows the tab-bar surface, including beside light app content. The default label
is New Tab. A small right-hand close icon appears on hover, with its 32-point
target inset 8 points from the outer tab bounds. This puts the cross's center
16 points inside the curved body edge. Reserve that space before truncating
the title so hover never crowds the name or status. Holding Command
temporarily replaces the status with the actual remapped shortcut beside the
name. An idle tab has no empty status slot; its name centers on its own. Hover
never moves the name, and Command never changes tab width. Long names truncate
and retain a full-name tooltip. Selection, dragging, middle-click close and the
existing keyboard commands keep their meaning.

The selected tab has 10-point upper corners and 8-point outward lower shoulders,
joining the workspace along its bottom edge. It starts 6 points below the top
of the strip. Pane frames use the related 10-point radius, with a 9-point clipped
inner edge beneath their 1-point rim. Only their frame changes: terminal content,
input, selection and status typography remain the terminal's own. AppKit mirrors
these shared geometry values; Flutter uses AppDesktop directly.

**Pane header** — the right-hand controls read model, split down, split right,
zoom, close. Use the rounded 14-point `AppPaneIcon` split/zoom variants and the
shared 12-point close glyph in 28-point targets. The close target sits 4 points
inside the header's trailing edge. Resting ink is 45%; hover and keyboard focus
brighten the glyph without a fill, border, or movement. Keep the controls on one
line; model and title text truncate before icon targets shrink. Zoom becomes
Restore while enlarged. Unavailable controls stay in place with disabled ink.
Split opens New Harness directly, inheriting the clicked pane's agent, machine,
and project; the pane is created only after submission. Clicking the model focuses that
pane and opens the same Models picker as Cmd-:. Selection stays bound to that
harness; a closed or replaced pane cannot receive a stale selection. Long model
names truncate and retain their full-name tooltip. Keep effort in the terminal,
and keep the icon targets clear at narrow widths. Tab-strip close behavior is
separate and remains hover-revealed.

**Focused workspace footer** — remaining subscription usage at the left,
with machine, project, branch and PR together at the right following the focused pane. Each
context field keeps its existing action, including the branch/PR chooser.
Titles stay quiet when several panes are visible; do not repeat branches in
pane headers. Do not repeat model or effort in the footer. Context honors Customize Harness's selected
status face, fields, colors and shell/Powerline treatment. Recent-harness
context uses that same renderer's monochrome presentation to stay secondary.
Use compact labels such as “Claude 0%  Codex 50%”, separated by whitespace only.
Provider names stay neutral. Color only the remaining percentage: quiet amber
from 0% through 20%, neutral above 20% or when unavailable. Use shared
semantic ink adjusted to remain readable on the selected workspace surface;
the number always conveys the state independently of color. These percentages are
remaining, not used. Use the same deduplicated accounts, limiting window and
freshness rules as Models. Separate subscriptions remain separate; unknown or
expired values show “—”, never a fabricated zero. Hover explains reset windows
and account identity; clicking opens Subscriptions without switching a model.
Companion and sharing controls sit after usage without shifting the context.

**Settings, Store and supporting screens** — the same type, colors and controls
at page scale. Related settings use grouping and whitespace. Existing artwork,
terminal previews, native toolbar/footer components and domain-specific visuals
retain their meaning. Read-only loading/error views use the same hierarchy.
Pane-resize guidance is app navigation: use the shared popover surface, system
type and wrapping keyboard hints. It must not look like terminal output.

## Interaction and review

Every clickable element has a hand cursor, every editor a text cursor.
Settings controls expose purpose, current value and state to accessibility;
neighboring explanatory text alone is not an accessible label. Do not merge
multiple actions into a single settings row. Short popovers use their measured
content height, including enlarged text, before applying the window height cap. Standard
editing, IME, keymap remaps, focus traversal and focus return remain intact.
Pending selectors must be unavailable to pointer, keyboard and accessibility
activation together. A queued selection cannot change an operation's target;
failure or cancellation restores the original control and permits retry.
Opening a modal isolates the workspace and native footer in the accessibility
tree. A late reply cannot restore a dismissed form or act on a different pane.

Review actual system-font renders in both appearances, narrow/short windows,
160–200% text, long names, empty/loading/error states, changed live data and
Increase Contrast. Exercise mouse, keyboard, nested dismissal, drafts and
composition. Use synthetic review data, not real agent launches or permissions.
Inspect the rebuilt app; widget tests alone do not prove native VoiceOver or
physical IME behavior. Record evidence and limitations in the migration ledger.

## Standard of finish

This specification establishes a direction, not an award or a quality score.
The work is ready for visual review only when:

- Cmd-N, Cmd-P, Rename, Move Pane and an ordinary menu are reviewed together,
  in both appearances, at normal desktop scale. None uses a competing recipe.
- The first intended action is obvious without reading a paragraph. Secondary
  settings are discoverable without turning the main surface into a dashboard.
- Optical alignment, text baselines, icon weight, nested corners and empty space
  hold up with short, long, missing and changing content.
- Hover, focus, stored selection, unavailable and error states stay distinct;
  small text remains readable. Enlarged text receives space instead of clipping.
- Opening, typing, scope changes, child menus and dismissal feel continuous in
  the running app. An attractive still image is insufficient evidence.

Remaining defects and unverified platform behavior belong in the review ledger.
Do not describe the implementation as flawless, Apple's design, or the best Mac
design system. Let the functioning app and the user's review establish its quality.
