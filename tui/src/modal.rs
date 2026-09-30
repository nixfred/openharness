//! The overlays and what their rows are: the fzf list's modes (harnesses, > commands, @ machines,
//! # projects, : models, * store, ? help), needs input, the New Harness form, layouts, and the
//! one-line prompts (rename, first message, send, link password).

use ratatui::style::Style;
use ratatui::text::Span;
use serde_json::Value;

use crate::app::App;
use crate::fleet::{ago, Reach, State};
use crate::layout::Preset;
use crate::picker::{Picker, Row};
use crate::theme::{self, engine_label, engine_mark, fg, state_mark};

/// Which harnesses a list shows. Only All is reachable from a key today.
#[allow(dead_code)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Filter { All, NeedsInput, Running, Paused }

impl Filter {
    pub fn label(self) -> &'static str { match self { Filter::All => "All", Filter::NeedsInput => "Needs input", Filter::Running => "Running", Filter::Paused => "Paused" } }
    fn keeps(self, state: State) -> bool {
        match self {
            Filter::All => true,
            Filter::NeedsInput => state == State::NeedsInput,
            Filter::Paused => state == State::Paused,
            Filter::Running => !matches!(state, State::Paused | State::Offline),
        }
    }
}

#[derive(Clone, Debug)]
pub struct What { pub engine: String, pub dsh: Option<String>, pub label: String }

#[derive(Clone, Debug)]
pub enum PickerKind {
    /// Harnesses — optionally inside one machine or one project folder.
    Open { filter: Filter, machine: Option<String>, project: Option<String> },
    Palette,
    Projects,
    Models,
    Inbox,
    Machines,
    Layout,
    Help,
    Store,
    /// A task routed to a harness; [voice]: the dial's spoken task it answers.
    Route { text: String, voice: Option<String> },
    /// `show-messages`, `list-keys`, `choose-buffer`.
    Messages,
    Keys,
    Buffers,
    /// What `list-windows`, `list-panes`, `show-options`… print, in a view (tmux's view mode).
    Output { title: String, lines: Vec<String> },
}

#[derive(Clone, Debug)]
pub enum PromptKind {
    RenameTab,
    RenameHarness { machine: String, agent: String },
    Send,
    Broadcast,
    LinkPassword { machine: String },
    /// A question's answer, typed: option numbers or your own words.
    /// The question's request id when M-a was pressed: a new one meanwhile is not answered.
    Answer { machine: String, agent: String, request: String },
    /// A message to a harness (C-b s's M-s).
    Message { machine: String, agent: String },
    /// tmux `command-prompt`: with a template, the answers fill it (`%1` `%2` …, `%%` the first
    /// not yet used, `%%%` quoted); without one, the typed text is the command. `more`: the
    /// prompts still to ask (label, initial text); `answers`: those given; `one`: -1, a single
    /// key is the answer; `digits`: -N, only numbers; `incremental`: -i, the template run on
    /// every change (after `=`, `+` or `-`), `last` what C-r and C-s bring back; `ptype`: -T,
    /// whose history Up and Down walk (command, search, target, window-target).
    Command { template: Option<String>, more: Vec<(String, String)>, answers: Vec<String>, one: bool, digits: bool, incremental: bool, ptype: usize, last: String },
    /// command-prompt -k: the next key pressed, by its tmux name, fills the template.
    Key { template: String },
    /// A prompt of choose-tree's for the tree in [pane]: search, filter, kill (one key), a
    /// command for the tagged items.
    Tree { pane: u64, ask: crate::tree::Ask },
}

/// A line typed in the status line, tmux-style: `(rename-window) name`, `:split-window -h`.
#[derive(Clone, Debug)]
pub struct Prompt {
    pub kind: PromptKind,
    pub title: String,
    pub label: String,
    pub hint: String,
    pub value: String,
    pub secret: bool,
    /// Cursor position in `value`, in chars (emacs keys move it, as in tmux's prompt).
    pub cursor: usize,
    /// Where Up/Down are in the command history.
    pub history_at: Option<usize>,
    /// status-keys vi: Esc leaves insert for normal mode; an operator (d, c, r) waits for its motion.
    pub vi_normal: bool,
    /// What C-w last cut (prompt_saved): C-y puts it back before the newest paste buffer.
    pub saved: Option<String>,
}

impl Prompt {
    pub fn status(kind: PromptKind, label: &str, initial: &str) -> Prompt {
        Prompt { kind, title: String::new(), label: label.to_string(), hint: String::new(), value: initial.to_string(), secret: false, cursor: initial.chars().count(), history_at: None, vi_normal: false, saved: None }
    }
}

/// One row of a tmux display-menu: a label (a format, its styles kept), its shortcut key, the
/// command it runs.
#[derive(Clone, Debug)]
pub struct MenuItem { pub label: String, pub key: String, pub command: String, pub disabled: bool, pub separator: bool }

/// tmux's display-menu (menu.c): its items, where its box is (x, y: the top-left corner; the box
/// is width + 4 by the items + 2), which item is chosen (none yet when the mouse opened it), -O,
/// and the mouse event of the command that opened it (its items' commands run with it). A
/// choose-tree's menu (a right click in it) gives its item's key to the tree in that pane, the
/// line clicked made current, in place of a command.
#[derive(Clone, Debug)]
pub struct Menu {
    pub title: String,
    pub items: Vec<MenuItem>,
    pub choice: Option<usize>,
    pub x: u16,
    pub y: u16,
    pub width: u16,
    pub stay_open: bool,
    pub no_mouse: bool,
    pub mouse: Option<crate::mouse::Event>,
    pub tree: Option<(u64, usize)>,
    /// A prompt's completion menu (status_prompt_complete_list_menu): the prompt under it, back
    /// when it closes, the chosen word put in it.
    pub complete: Option<Box<Complete>>,
}

/// What a completion menu completes: the prompt, the words its items stand for, the flag they
/// go after (-t, -s), and whether the prompt is a window target's (the word is the whole line).
#[derive(Clone, Debug)]
pub struct Complete { pub prompt: Prompt, pub list: Vec<String>, pub flag: Option<char>, pub window_target: bool }

pub enum Modal {
    /// tmux's display-menu: a box of items, each with its key; Enter or the key runs one.
    Menu(Menu),
    /// Compact New Harness form with searchable choices and a persistent draft.
    NewHarness(Box<crate::new_harness::Form>),
    Picker { kind: PickerKind, picker: Picker },
    Prompt(Prompt),
    /// tmux `confirm-before`: `Confirm 'kill-pane'? (y/n)` in the status line; `key` answers
    /// yes (-c), and with `enter_yes` (-y) so does Enter.
    Confirm { prompt: String, command: String, key: char, enter_yes: bool },
    /// tmux `display-panes` (C-b q): a big number on every pane; press one to go there.
    /// display-panes: until when (none: until a key, -d 0), the command a number runs (%% its
    /// pane), and whether keys choose at all (-N: not).
    DisplayPanes { until: Option<std::time::Instant>, template: Option<String>, keys: bool },
    /// display-popup: a shell floating over the window; it goes when its program exits.
    /// display-popup: its program's pane, where it is, its border (lines: tmux's box lines,
    /// `none` for -B), title (a format drawn with its styles) and styles (-s, -S).
    Popup { pane: u64, x: u16, y: u16, width: u16, height: u16, border: bool, title: String, look: PopupLook },
    /// copy-mode (C-b [): move a cursor over the pane's text and copy from it, vi-style.
    Copy { pane: u64 },
}

pub const ENGINES: [&str; 14] = ["claude", "codex", "opencode", "cursor", "pi", "amp", "hermes", "kilo", "grok", "devin", "copilot", "commandcode", "muse", "terminal"];

/// The palette's commands: (id, title, keys, hint, group).
pub const COMMANDS: &[(&str, &str, &str, &str, &str)] = &[
    ("open", "Harnesses…", "⌥P", "every harness on every machine", "Harness"),
    ("projects", "Projects…", "⌥O", "a project, then one of its harnesses", "Harness"),
    ("models", "Models…", "⌥I", "switch this harness's model and effort", "Harness"),
    ("new", "New Harness…", "⌥N", "", "Harness"),
    ("terminal", "New Terminal", "⌥⇧T", "a shell on this pane's machine", "Harness"),
    ("inbox", "Harnesses needing input", "⌥⇧I", "", "Harness"),
    ("next-waiting", "Next harness waiting on you", "⌥A", "oldest question first", "Harness"),
    ("send", "Send to harness…", "⌥B", "type a task — Harness picks who", "Harness"),
    ("broadcast", "Broadcast to this swarm…", "", "one message to every harness in the swarm", "Harness"),
    ("clone", "Clone Harness", "⌥⇧N", "a second one with this one's history", "Harness"),
    ("restart", "Restart Harness", "⌥⇧E", "", "Harness"),
    ("pause", "Pause Harness", "", "stop the engine, keep the conversation", "Harness"),
    ("rename", "Rename Harness…", "", "", "Harness"),
    ("take", "Take Control", "", "reclaim all panes across every tab", "App"),
    ("tab", "New Swarm", "⌥T", "", "Swarms"),
    ("rename-tab", "Rename Swarm…", "⌥⇧R", "", "Swarms"),
    ("close-tab", "Close Swarm", "⌥⇧W", "harnesses keep running", "Swarms"),
    ("next-tab", "Next Swarm", "⌥}", "", "Swarms"),
    ("prev-tab", "Previous Swarm", "⌥{", "", "Swarms"),
    ("tab-left", "Move Swarm Left", "⌥<", "", "Swarms"),
    ("tab-right", "Move Swarm Right", "⌥>", "", "Swarms"),
    ("split-right", "Split Right", "⌥\\", "", "Panes"),
    ("split-down", "Split Down", "⌥-", "", "Panes"),
    ("close-pane", "Close Pane", "⌥W", "the harness keeps running", "Panes"),
    ("zoom", "Zoom Pane", "⌥Z", "", "Panes"),
    ("layout", "Layout…", "⌥L", "grid, columns, main + stack…", "Panes"),
    ("equalize", "Equalize Panes", "⌥=", "", "Panes"),
    ("pane-tab", "Move Pane to New Swarm", "", "", "Panes"),
    ("find", "Find in Pane…", "⌥⇧F", "search this pane's history", "Panes"),
    ("copy-mode", "Copy Mode", "⌥V", "select and copy with the keyboard", "Panes"),
    ("machines", "Machines", "⌥M", "", "Machines"),
    ("store", "Harness Store", "⌥S", "", "Machines"),
    ("help", "Keyboard Shortcuts", "⌥/", "", "App"),
    ("keys", "Every Key…", "", "every binding, searched as you type (C-b ? lists them as tmux does)", "App"),
    ("quit", "Quit", "⌥Q", "harnesses keep running", "App"),
];


fn span(text: impl Into<String>, style: Style) -> Span<'static> { Span::styled(text.into(), style) }

/// A popup's look (popup.c): its box lines, its style and its border's style.
#[derive(Clone, Debug, Default)]
pub struct PopupLook { pub lines: String, pub style: String, pub border_style: String }

pub fn agent_rows(app: &App, filter: Filter, machine: Option<&str>, project: Option<&str>) -> Vec<Row> {
    let many = app.fleet.visible_machines().filter(|m| m.usable()).count() > 1;
    // The project in each row when the harnesses work in more than one.
    let projects = { let mut p: Vec<&str> = app.fleet.agents.values().map(|a| a.project.as_str()).filter(|p| !p.is_empty()).collect(); p.sort(); p.dedup(); p.len() > 1 };
    let open: Vec<(String, String)> = app.panes.values().map(|p| (p.machine_id.clone(), p.agent_id.clone())).collect();
    // As the desktop's Cmd-P lists them ("Recently active"): the one active last first — a query
    // ranks by how well it matches, this order breaking ties. (C-b A lists those waiting on you.)
    let mut agents: Vec<&crate::fleet::Agent> = app.fleet.agents.values().collect();
    agents.sort_by(|a, b| b.recency().cmp(&a.recency()).then_with(|| a.name.cmp(&b.name)).then_with(|| a.id.cmp(&b.id)));
    agents.into_iter()
        .filter(|a| machine.map(|m| a.machine_id == m).unwrap_or(true))
        .filter(|a| project.map(|p| a.project_root == p || a.cwd == p).unwrap_or(true))
        .filter(|a| filter.keeps(app.fleet.state_of(a)))
        .map(|a| {
            let state = app.fleet.state_of(a);
            let (dot, _, color) = state_mark(state, app.tick);
            let (mark, mark_color) = engine_mark(&a.engine);
            let group = match state {
                State::NeedsInput => "Needs you", State::Failed => "Failed", State::Done => "Done", State::Working => "Working", State::Starting => "Starting",
                State::Ready => "Idle", State::Paused => "Paused", State::Offline => "Offline",
            };
            let is_open = open.contains(&a.key());
            // Its one line: the question it asks, what it is doing now, what its last turn came to,
            // why it failed — the rest in the finder's dim.
            let (line, loud) = match state {
                State::NeedsInput => (a.question.as_ref().map(|q| q.prompt.clone()).unwrap_or_default(), true),
                State::Working => (a.doing.clone().unwrap_or_else(|| "Working".into()), false),
                State::Done => (a.did.clone().unwrap_or_else(|| "Finished".into()), false),
                State::Failed => (Some(a.launch_error.clone()).filter(|e| !e.is_empty()).or_else(|| a.did.clone()).unwrap_or_else(|| "Failed to start".into()), true),
                State::Starting => ("Starting".into(), false),
                _ => (a.did.clone().unwrap_or_default(), false),
            };
            let quiet = matches!(state, State::Ready | State::Paused | State::Offline);
            // An idle one's line is where it works (its last turn in the preview).
            let line = if quiet && line.is_empty() { [a.project.clone(), a.branch.clone()].into_iter().filter(|s| !s.is_empty()).collect::<Vec<_>>().join(" ") } else { line };
            let detail = vec![span(line, if loud { fg(theme::ATTENTION) } else if quiet { fg(theme::MUTED) } else { Style::default() })];
            // Where it works and how long it has been as it is (waiting on you since its question,
            // working since its turn began, done since it ended).
            let since = a.state_since(state);
            // Right: the machine (when there are several) and how long — the name and its line
            // come first; where it works is searchable and in the preview's title.
            // Its pull request, where it has one (what it cost is in the preview).
            let pr = a.pr.as_ref().map(|p| p.label()).unwrap_or_default();
            let _ = is_open;
            let narrow = ago(since);
            let right = [pr.clone(), if projects { a.project.clone() } else { String::new() }, if many { app.fleet.machine_name(&a.machine_id) } else { String::new() }, ago(since)]
                .into_iter().filter(|s| !s.is_empty()).collect::<Vec<_>>().join("  ");
            let live = !matches!(state, State::Paused | State::Offline);
            // What a query finds it by besides its name: where it works, its engine, its pull
            // request, and its state in words ('failed, 'done, 'waiting, 'working, 'idle).
            let words = match state {
                State::NeedsInput => "waiting needs-you", State::Failed => "failed", State::Done => "done finished", State::Working => "working",
                State::Starting => "starting", State::Ready => "idle", State::Paused => "paused", State::Offline => "offline",
            };
            // Its pull request's state in words too: 'pr, 'open, 'merged.
            let pr_words = a.pr.as_ref().map(|p| format!("pr {}", p.state.to_lowercase())).unwrap_or_default();
            Row::new(format!("{}:{}", a.machine_id, a.id), a.name.clone())
                .boost(if state == State::NeedsInput { 60 } else if live { 30 } else { 0 })
                .extra(format!("{} {} {} {} {} {} {} {} {}", a.project, a.branch, app.fleet.machine_name(&a.machine_id), a.engine, engine_label(&a.engine), a.dsh, pr, pr_words, words))
                // What it is doing now and how long it has been as it is change as you look.
                .volatile(matches!(state, State::Working | State::Starting), narrow.chars().count())
                .group(group)
                .lead(vec![span(dot, fg(color)), span(" ", Style::default()), span(mark, fg(mark_color)), span(" ", Style::default())])
                .detail(detail)
                .right(right)
                .right_narrow(narrow)
                .line_first(loud)
        })
        .collect()
}

/// The Claude Code and Codex conversations Harness did not start that C-b s's query found by what
/// was said in them (never in the list as it opens): `not in Harness`, Enter resuming one as a
/// harness; one open in another terminal or app is marked so, and not opened twice.
pub fn external_rows(app: &App) -> Vec<Row> {
    let many = app.fleet.visible_machines().filter(|m| m.usable()).count() > 1;
    app.said.iter().filter_map(|s| s.external.as_ref()).map(|x| {
        let (mark, mark_color) = engine_mark(&x.engine);
        let folder = x.cwd.trim_end_matches('/').rsplit('/').next().unwrap_or("").to_string();
        let title = if x.title.is_empty() { folder.clone() } else { x.title.clone() };
        let note = if x.open { "open elsewhere" } else { "not in Harness" };
        let right = [note.to_string(), if many { app.fleet.machine_name(&x.machine) } else { String::new() }, ago(x.last_at)].into_iter().filter(|s| !s.is_empty()).collect::<Vec<_>>().join("  ");
        Row::new(format!("external:{}:{}", x.machine, x.session_id), title)
            .extra(format!("{} {} {} {}", x.cwd, x.engine, engine_label(&x.engine), app.fleet.machine_name(&x.machine)))
            .group("Not in Harness")
            .lead(vec![span("◌", fg(theme::MUTED)), span(" ", Style::default()), span(mark, fg(mark_color)), span(" ", Style::default())])
            .detail(vec![span(folder, fg(theme::MUTED))])
            .right(right)
            .right_narrow(ago(x.last_at))
    }).collect()
}

/// A hit's snippet on one line: its marks taken off, from a little before the first match
/// (`…`), at most a line's worth.
pub fn snippet_line(snippet: &str) -> String {
    let at = snippet.find('\u{2}').unwrap_or(0);
    let flat = |s: &str| s.replace(['\u{2}', '\u{3}'], "").split_whitespace().collect::<Vec<_>>().join(" ");
    let before: Vec<char> = flat(&snippet[..at]).chars().collect();
    let lead = if before.len() > 24 { format!("…{} ", before[before.len() - 23..].iter().collect::<String>().trim_start()) } else if before.is_empty() { String::new() } else { format!("{} ", before.iter().collect::<String>()) };
    let text = format!("{lead}{}", flat(&snippet[at..]));
    let chars: Vec<char> = text.chars().collect();
    if chars.len() > 110 { format!("{}…", chars[..109].iter().collect::<String>()) } else { text }
}

/// The sessions, when there is more than one: `work: 2 windows`, the one on screen `(attached)`.
pub fn session_rows(app: &App) -> Vec<Row> {
    let all = app.session_list();
    if all.len() < 2 { return Vec::new() }
    all.into_iter().map(|(id, name)| {
        let windows = app.session_windows(id).len();
        // Attached: this client's, or shown by another client.
        let attached = id == app.session_id || app.stash_value(id, "session_attached").as_deref() == Some("1");
        // The harnesses in its windows, in counts (this client's sessions: another's are its).
        let keys = app.session_harnesses(id);
        let counts = state_counts(app, app.fleet.agents.values().filter(|a| keys.contains(&a.key())));
        let right = [counts, if attached { "attached".to_string() } else { String::new() }].into_iter().filter(|s| !s.is_empty()).collect::<Vec<_>>().join("  ");
        Row::new(format!("session:{id}"), format!("{name}: {windows} windows")).group("Sessions")
            .lead(vec![span("§ ", fg(theme::MUTED))])
            .right(right)
    }).collect()
}

/// Only says something when a filter is on — the count beside the prompt already says the rest.
pub fn open_status(_app: &App, filter: Filter) -> String {
    if filter == Filter::All { String::new() } else { format!("{} · tab ↹", filter.label().to_lowercase()) }
}

/// The mode a launcher query is in, by its first character.
pub fn launcher_kind(query: &str, current: &PickerKind) -> PickerKind {
    match crate::picker::scope_of(query) {
        Some('>') => PickerKind::Palette,
        Some('@') => PickerKind::Machines,
        Some('#') => PickerKind::Projects,
        Some(':') => PickerKind::Models,
        Some('*') => PickerKind::Store,
        Some('?') => PickerKind::Help,
        _ => match current { PickerKind::Open { .. } => current.clone(), _ => PickerKind::Open { filter: Filter::All, machine: None, project: None } },
    }
}

pub fn is_launcher(kind: &PickerKind) -> bool {
    matches!(kind, PickerKind::Open { .. } | PickerKind::Palette | PickerKind::Machines | PickerKind::Projects | PickerKind::Models | PickerKind::Store | PickerKind::Help)
}

/// (title, placeholder) for a launcher mode.
pub fn launcher_title(app: &App, kind: &PickerKind) -> (String, String) {
    match kind {
        PickerKind::Open { machine: Some(m), project: None, .. } => (format!("harnesses · @{}", app.fleet.machine_name(m)), "Search this machine's harnesses — esc back".into()),
        PickerKind::Open { project: Some(p), .. } => (format!("harnesses · #{}", p.rsplit('/').next().unwrap_or(p)), "Search this project's harnesses — esc back".into()),
        PickerKind::Open { .. } => ("harnesses".into(), "Search harnesses   > commands   @ machines   # projects   : models   * store   ? help".into()),
        PickerKind::Palette => ("commands".into(), "Run anything by name".into()),
        PickerKind::Machines => ("machines".into(), "Choose a machine, then one of its harnesses".into()),
        PickerKind::Projects => ("projects".into(), "Choose a project, then one of its harnesses".into()),
        PickerKind::Models => ("models".into(), "Switch the focused harness's model and effort".into()),
        PickerKind::Store => ("store".into(), "Find a harness in the Store".into()),
        PickerKind::Help => ("quick access".into(), "What this box can do".into()),
        _ => (String::new(), String::new()),
    }
}

/// `#`: every project folder with harnesses in it, grouped per machine.
/// A set of harnesses in counts, as the status line's (`?1 ✗1 ✓2 ⠹3`): the states that ask
/// something of you and the working ones; none is nothing.
pub fn state_counts<'a>(app: &App, agents: impl Iterator<Item = &'a crate::fleet::Agent>) -> String {
    let mut n = [0usize; 4];
    for a in agents.filter(|a| a.engine != "terminal") {
        match app.fleet.state_of(a) { State::NeedsInput => n[0] += 1, State::Failed => n[1] += 1, State::Done => n[2] += 1, State::Working => n[3] += 1, _ => {} }
    }
    let glyphs = ["?", "✗", "✓", crate::theme::spinner(app.tick)];
    (0..4).filter(|i| n[*i] > 0).map(|i| format!("{}{}", glyphs[i], n[i])).collect::<Vec<_>>().join(" ")
}

pub fn project_rows(app: &App) -> Vec<Row> {
    let mut groups: std::collections::BTreeMap<(String, String), (usize, usize, u64)> = std::collections::BTreeMap::new();
    for a in app.fleet.agents.values() {
        if a.project_root.is_empty() { continue }
        let entry = groups.entry((a.machine_id.clone(), a.project_root.clone())).or_insert((0, 0, 0));
        entry.0 += 1;
        if !matches!(app.fleet.state_of(a), State::Paused | State::Offline) { entry.1 += 1 }
        entry.2 = entry.2.max(a.recency());
    }
    let many = app.fleet.visible_machines().filter(|m| m.usable()).count() > 1;
    let mut rows: Vec<(u64, Row)> = groups.into_iter().map(|((machine, root), (all, live, recent))| {
        let name = root.rsplit('/').next().unwrap_or(&root).to_string();
        let home = app.homes.get(&machine).cloned().unwrap_or_else(|| std::env::var("HOME").unwrap_or_default());
        let short = if !home.is_empty() && root.starts_with(&home) { format!("~{}", &root[home.len()..]) } else { root.clone() };
        // Its harnesses in counts (who needs you there), then how many.
        let counts = state_counts(app, app.fleet.agents.values().filter(|a| a.machine_id == machine && a.project_root == root));
        let right = format!("{}{}{} harness{}{}", if many { format!("{}  ", app.fleet.machine_name(&machine)) } else { String::new() }, if counts.is_empty() { String::new() } else { format!("{counts}  ") }, all, if all == 1 { "" } else { "es" }, if live > 0 { format!(" · {live} live") } else { String::new() });
        (recent, Row::new(format!("proj:{machine}\t{root}"), name).extra(format!("{short} {}", app.fleet.machine_name(&machine)))
            .lead(vec![span(if live > 0 { "● " } else { "○ " }, fg(if live > 0 { theme::ONLINE } else { theme::MUTED }))])
            .detail(vec![span(short, fg(theme::MUTED))]).right(right).boost(if live > 0 { 30 } else { 0 }))
    }).collect();
    rows.sort_by(|a, b| b.0.cmp(&a.0));
    rows.into_iter().map(|(_, r)| r).collect()
}

/// `:`: the focused harness's models, the one it runs marked.
pub fn model_rows(app: &App) -> Vec<Row> {
    let Some((machine, agent)) = app.focused().and_then(|f| app.panes.get(&f)).map(|p| (p.machine_id.clone(), p.agent_id.clone())) else { return vec![] };
    let current = app.fleet.agent(&machine, &agent).map(|a| a.model.clone()).unwrap_or_default();
    let list = app.models.get(&(machine, agent)).cloned().unwrap_or_default();
    list.iter().filter_map(|m| {
        let id = m.get("id")?.as_str()?.to_string();
        let name = m.get("displayName").and_then(Value::as_str).unwrap_or(&id).to_string();
        let (family, effort) = name.split_once(" / ").map(|(a, b)| (a.to_string(), b.to_string())).unwrap_or((name.clone(), String::new()));
        let on = id == current;
        Some(Row::new(id, name.clone()).group(family).extra(effort)
            .lead(vec![span(if on { "● " } else { "  " }, fg(theme::ONLINE))])
            .right(if on { "current".to_string() } else { String::new() }))
    }).collect()
}

/// The machine a `:` list is about: the focused pane's, else this computer.
pub fn models_machine(app: &App) -> String {
    app.focused().and_then(|f| app.panes.get(&f)).map(|p| p.machine_id.clone()).unwrap_or_else(|| app.fleet.local_id.clone())
}

/// `:`, part two: the machine's local models — start one that is downloaded, get one that is not.
pub fn local_model_rows(app: &App) -> Vec<Row> {
    let machine = models_machine(app);
    let name = app.fleet.machine_name(&machine);
    let Some(list) = app.local_models.get(&machine) else { return vec![] };
    let gb = |b: f64| if b >= 1e9 { format!("{:.1} GB", b / 1e9) } else { format!("{:.0} MB", b / 1e6) };
    let mut rows: Vec<(u8, Row)> = list.iter().filter_map(|m| {
        let id = m.get("id")?.as_str()?;
        let state = m.get("state").and_then(Value::as_str).unwrap_or("available");
        let label = m.get("name").and_then(Value::as_str).unwrap_or(id).to_string();
        let size = m.get("sizeBytes").and_then(Value::as_f64).map(gb).unwrap_or_default();
        let (dot, color, rank) = match state { "running" | "serving" => ("●", theme::ONLINE, 0), "downloaded" => ("○", theme::SOFT, 1), s if s.contains("load") || s.contains("start") => ("◌", theme::WARN, 0), _ => ("·", theme::MUTED, 2) };
        let action = match rank { 0 => "running · ^S stops", 1 => "enter starts", _ => "enter downloads" };
        let recommended = m.get("recommended").and_then(Value::as_bool).unwrap_or(false);
        Some((rank, Row::new(format!("grid:{machine}\t{id}"), label).group(format!("Local models · {name}"))
            .extra(format!("{id} {} {state}", m.get("quant").and_then(Value::as_str).unwrap_or("")))
            .lead(vec![span(format!("{dot} "), fg(color))])
            .detail(vec![span(format!("{state}{}", if recommended { " · recommended" } else { "" }), fg(theme::MUTED))])
            .right(format!("{size}  {action}"))))
    }).collect();
    rows.sort_by_key(|(rank, _)| *rank);
    rows.into_iter().map(|(_, r)| r).collect()
}

/// `?`: what the box does, one prefix per line, then every key.
pub fn mode_rows(app: &App) -> Vec<Row> {
    let hint = |c: &str| app.keymap.hint(c).unwrap_or_default();
    let modes = [(">", "commands", "every tmux command, by name", hint("command-prompt")), ("@", "machines", "a machine, then its harnesses", hint("choose-tree -m")),
        ("#", "projects", "a project folder, then its harnesses", String::new()), (":", "models", "this harness's model; local models", hint("choose-tree -i")),
        ("*", "store", "the Harness Store", hint("choose-tree -S"))];
    let mut rows: Vec<Row> = modes.iter().map(|(p, t, d, k)| Row::new(format!("mode:{p}"), format!("{p} {t}")).detail(vec![span(*d, Style::default().add_modifier(ratatui::style::Modifier::DIM))]).right(k.clone())).collect();
    let prefix = crate::keys::name(&app.keymap.prefix);
    // Each key as part of its line (as fzf would be given it): searched for as any word is
    // (`C-b z`, `PPage`), lit only where the query matches.
    rows.extend(app.keymap.prefix_table.iter().filter(|b| !b.note.is_empty()).map(|b| Row::new(format!("key:{}", b.command), format!("{prefix} {:<7} {}", crate::keys::name(&b.chord), b.note)).extra(b.command.clone())));
    rows
}

pub fn inbox_rows(app: &App) -> Vec<Row> {
    let mut agents: Vec<_> = app.fleet.agents.values().filter(|a| a.question.is_some() && a.status != "stopped").collect();
    agents.sort_by_key(|a| a.question.as_ref().map(|q| q.since));
    let mut rows = Vec::new();
    for a in agents {
        let q = a.question.as_ref().unwrap();
        // Who asks (the harness, its project, its machine), then its options by number — one row
        // a question, answered where it stands (M-1…9, M-a).
        let who = [a.name.clone(), a.project.clone(), app.fleet.machine_name(&a.machine_id)].into_iter().filter(|s| !s.is_empty()).collect::<Vec<_>>().join(" · ");
        let options = q.options.iter().enumerate().map(|(i, o)| format!("{} {o}", i + 1)).collect::<Vec<_>>().join(" · ");
        let (mark, mark_color) = engine_mark(&a.engine);
        let since = crate::fleet::now_ms().saturating_sub(q.since.elapsed().as_millis() as u64);
        let mut detail = vec![span(who.clone(), fg(theme::MUTED))];
        if !options.is_empty() { detail.push(span(format!("  {options}"), fg(theme::accent()))) }
        rows.push(Row::new(format!("{}:{}#", a.machine_id, a.id), q.prompt.clone()).extra(format!("{who} {} {options}", a.branch))
            .lead(vec![span("? ", fg(theme::ATTENTION).add_modifier(ratatui::style::Modifier::BOLD)), span(mark, fg(mark_color)), span(" ", Style::default())])
            .detail(detail)
            .right(ago(since)));
    }
    rows
}

/// `>`: every tmux command there is, with the key that runs it.
pub fn palette_rows(app: &App) -> Vec<Row> {
    crate::commands::COMMANDS.iter().map(|(name, alias, about)| {
        let key = app.keymap.key_for_name(name).unwrap_or_default();
        Row::new(*name, *name).extra(format!("{alias} {about}")).detail(vec![span(*about, Style::default().add_modifier(ratatui::style::Modifier::DIM))]).right(key)
    }).collect()
}

/// Commands that mean nothing without words after them.
pub const NEEDS_ARGS: &[&str] = &["select-window", "rename-window", "move-window", "select-pane", "resize-pane", "swap-pane", "select-layout", "send-keys", "command-prompt", "confirm-before", "display-message", "send-message", "rename-harness", "send-task", "broadcast"];

pub fn machine_rows(app: &App) -> Vec<Row> {
    app.fleet.visible_machines().map(|m| {
        // Its harnesses by what they do: the fleet's counts, for this machine.
        let here: Vec<State> = app.fleet.agents.values().filter(|a| a.machine_id == m.id && a.engine != "terminal").map(|a| app.fleet.state_of(a)).collect();
        let n = |s: State| here.iter().filter(|x| **x == s).count();
        let (dot, color, word) = match &m.reach {
            _ if m.local && m.reach == Reach::Ready => ("●", theme::ONLINE, "this computer".to_string()),
            Reach::Ready => ("●", theme::ONLINE, "connected".into()),
            Reach::Connecting => ("◌", theme::WARN, "connecting…".into()),
            Reach::NeedsLink => ("●", theme::ATTENTION, "not linked — M-l links it".into()),
            Reach::Error(e) => ("●", theme::DANGER, e.chars().take(40).collect()),
            _ if m.online() => ("○", theme::SOFT, "online".into()),
            _ => ("○", theme::MUTED, "offline".into()),
        };
        let rtt = app.rtt.get(&m.id).filter(|_| m.usable()).map(|d| format!("{}ms  ", d.as_millis())).unwrap_or_default();
        let counts = [(State::NeedsInput, "waiting"), (State::Failed, "failed"), (State::Done, "done"), (State::Working, "working"), (State::Ready, "idle")]
            .iter().filter(|(s, _)| n(*s) > 0).map(|(s, w)| format!("{} {w}", n(*s))).collect::<Vec<_>>().join(" · ");
        let counts = format!("{rtt}{}", if counts.is_empty() { "no harnesses".into() } else { counts });
        Row::new(m.id.clone(), app.fleet.machine_name(&m.id)).extra(m.status.clone())
            .lead(vec![span(dot, fg(color)), span(" ", Style::default())])
            .detail(vec![span(word, fg(color))])
            .right(counts)
    }).collect()
}

pub fn layout_rows() -> Vec<Row> {
    Preset::ALL.iter().enumerate().map(|(i, (_, name, detail))| Row::new(i.to_string(), *name).detail(vec![span(*detail, fg(theme::MUTED))])).collect()
}


pub fn new_machine_rows(app: &App, prefer: &str) -> Vec<Row> {
    let prefer = app.fleet.launch_machine_id(prefer);
    let mut rows: Vec<Row> = app.fleet.visible_machines().filter(|m| m.usable()).map(|m| {
        let running = app.fleet.agents.values().filter(|a| a.machine_id == m.id && a.status == "active").count();
        Row::new(m.id.clone(), app.fleet.machine_name(&m.id))
            .lead(vec![span(if m.id == prefer { "● " } else { "○ " }, fg(if m.id == prefer { theme::accent() } else { theme::ONLINE }))])
            .detail(vec![span(format!("{}{running} running", if m.local { "this computer · " } else { "" }), fg(theme::MUTED))])
    }).collect();
    rows.sort_by_key(|r| r.id != prefer);
    rows
}

pub fn new_what_rows(catalog: &[Value]) -> Vec<Row> {
    let mut rows: Vec<Row> = ENGINES.iter().map(|e| {
        let (mark, color) = engine_mark(e);
        Row::new(format!("engine:{e}"), engine_label(e)).extra(*e).group("Agents")
            .lead(vec![span(mark, fg(color)), span(" ", Style::default())])
            .detail(vec![span(if *e == "terminal" { "a plain shell" } else { "" }, fg(theme::MUTED))])
    }).collect();
    for row in catalog {
        if row.get("installed").and_then(Value::as_bool) == Some(false) || row.get("kind").and_then(Value::as_str) == Some("viewer") { continue }
        let Some(id) = row.get("id").and_then(Value::as_str) else { continue };
        let name = row.get("name").and_then(Value::as_str).unwrap_or(id);
        let description = row.get("description").and_then(Value::as_str).unwrap_or("");
        let engine = row.get("engine").and_then(Value::as_str).unwrap_or("claude");
        rows.push(Row::new(format!("dsh:{id}:{engine}"), name).extra(format!("{id} {description}")).group("From the Store")
            .lead(vec![span("◆ ", fg(theme::TEAL))]).detail(vec![span(description.to_string(), fg(theme::MUTED))]));
    }
    rows
}

pub fn store_rows(catalog: &[Value]) -> Vec<Row> {
    catalog.iter().filter(|r| r.get("kind").and_then(Value::as_str) != Some("viewer")).filter_map(|row| {
        let id = row.get("id")?.as_str()?;
        let installed = row.get("installed").and_then(Value::as_bool) != Some(false);
        let name = row.get("name").and_then(Value::as_str).unwrap_or(id);
        let description = row.get("description").and_then(Value::as_str).unwrap_or("");
        let category = row.get("category").and_then(Value::as_str).unwrap_or(if installed { "Installed" } else { "Available" });
        Some(Row::new(id, name).extra(format!("{id} {description} {category}")).group(category.to_string())
            .lead(vec![span(if installed { "● " } else { "○ " }, fg(if installed { theme::ONLINE } else { theme::MUTED }))])
            .detail(vec![span(description.to_string(), fg(theme::MUTED))]))
    }).collect()
}

pub fn route_rows(reply: &Value) -> Vec<Row> {
    let best = reply.get("agentId").and_then(Value::as_str).unwrap_or("");
    let mut rows: Vec<Row> = reply.get("candidates").and_then(Value::as_array).cloned().unwrap_or_default().iter().filter_map(|c| {
        let agent = c.get("agentId")?.as_str()?;
        let machine = c.get("machineId")?.as_str()?;
        let (mark, color) = engine_mark(c.get("engine").and_then(Value::as_str).unwrap_or(""));
        let confidence = c.get("confidence").and_then(Value::as_f64).unwrap_or(0.0);
        Some(Row::new(format!("{machine}:{agent}"), c.get("name").and_then(Value::as_str).unwrap_or(agent).to_string())
            .lead(vec![span(mark, fg(color)), span(" ", Style::default())])
            .detail(vec![span(c.get("recent").and_then(Value::as_str).unwrap_or("").to_string(), fg(theme::MUTED))])
            .right(format!("{}  {}", c.get("machine").and_then(Value::as_str).unwrap_or(""), if confidence > 0.0 { format!("{}%", (confidence * 100.0) as u32) } else { String::new() })))
    }).collect();
    rows.sort_by_key(|r| !r.id.ends_with(best) || best.is_empty());
    rows
}
