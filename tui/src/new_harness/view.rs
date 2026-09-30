//! Terminal rendering of the compact desktop form.
use super::*;

fn put(buf: &mut Buffer, x: u16, y: u16, width: u16, text: &str, style: Style) {
    if width == 0 {
        return;
    }
    let mut out = String::new();
    let mut used = 0;
    let limit = width as usize;
    let trunc = text.width() > limit;
    for ch in text.chars().filter(|c| !c.is_control()) {
        let w = ch.width().unwrap_or(0);
        if used + w > limit.saturating_sub(usize::from(trunc)) {
            break;
        }
        out.push(ch);
        used += w;
    }
    if trunc {
        out.push('…');
    }
    buf.set_stringn(x, y, out, width as usize, style);
}

fn panel(buf: &mut Buffer, r: Rect, title: &str, base: Style, border: Style) {
    crate::term_out::clear_extras(r);
    for y in r.y..r.bottom() {
        for x in r.x..r.right() {
            if let Some(c) = buf.cell_mut((x, y)) {
                c.reset();
                c.set_style(base);
            }
        }
    }
    Block::default()
        .borders(Borders::ALL)
        .border_type(BorderType::Rounded)
        .border_style(border)
        .render(r, buf);
    let _ = title;
}

pub fn draw(buf: &mut Buffer, body: Rect, form: &mut Form) -> Option<Position> {
    form.hits.clear();
    form.area = Rect::default();
    form.child_area = Rect::default();
    if body.width < 22 || body.height < 5 {
        put(
            buf,
            body.x,
            body.y,
            body.width,
            "New Harness · resize or Esc",
            Style::default(),
        );
        return None;
    }
    let (_, foreground, light) = theme::palette();
    let base = if theme::no_color() {
        Style::default()
    } else {
        theme::fg(foreground).bg(theme::depth_fit(if light {
            Color::Rgb(247, 247, 247)
        } else {
            Color::Rgb(25, 25, 25)
        }))
    };
    let accent = base.patch(theme::bold(theme::accent()));
    let muted = base.patch(theme::fg(if light {
        Color::Rgb(92, 98, 104)
    } else {
        Color::Rgb(167, 173, 180)
    }));
    let border = base.patch(theme::fg(theme::pane_palette().active_foreground));
    // Keep the working panes visible under the form, with a quiet backdrop.
    crate::term_out::clear_extras(body);
    let backdrop = if theme::no_color() {
        Style::default().add_modifier(Modifier::DIM)
    } else {
        theme::fg(if light {
            Color::Rgb(185, 185, 185)
        } else {
            Color::Rgb(32, 32, 32)
        })
        .bg(theme::depth_fit(if light {
            Color::Rgb(230, 230, 230)
        } else {
            Color::Rgb(4, 4, 4)
        }))
        .remove_modifier(Modifier::BOLD | Modifier::REVERSED | Modifier::DIM | Modifier::UNDERLINED)
    };
    for y in body.y..body.bottom() {
        for x in body.x..body.right() {
            if let Some(c) = buf.cell_mut((x, y)) {
                c.set_style(backdrop);
            }
        }
    }
    // Center the compact form itself. Options grow down and choosers open in
    // the remaining space to its right, without moving the form's anchor.
    let form_w = body.width.saturating_sub(4).min(52);
    let compact_h = 11.min(body.height.saturating_sub(2).max(5));
    let x = body.x + (body.width - form_w) / 2;
    let y = body.y + (body.height - compact_h) / 2;
    let side_w = body
        .right()
        .saturating_sub(x + form_w)
        .saturating_sub(4)
        .min(60);
    let side = side_w >= 32;
    let child_w = if side { side_w } else { form_w };
    let fields = form.fields();
    let height = body.bottom().saturating_sub(y + 1).max(5);
    let form_h = (fields.len() as u16 * 2 + 3).min(height);
    let child_h = form
        .child
        .as_ref()
        .map(|c| if c.kind.editing() { 8 } else { 22 })
        .unwrap_or(0)
        .min(height);
    let r = Rect::new(x, y, form_w, form_h);
    form.area = r;
    if form.child.is_none() || side || !form.child_active {
        panel(buf, r, "New Harness", base, border);
        let gap = if form_h >= fields.len() as u16 * 2 + 3 {
            2
        } else {
            1
        };
        let capacity = ((form_h.saturating_sub(5) / gap) + 1) as usize;
        let focus = fields.iter().position(|f| *f == form.focus).unwrap_or(0);
        let skip = focus.saturating_sub(capacity - 1);
        for (row, field) in fields.iter().skip(skip).take(capacity).enumerate() {
            let fy = r.y + 2 + row as u16 * gap;
            if fy >= r.bottom() - 2 {
                break;
            }
            let active = *field == form.focus;
            let st = if form.blocked(*field).is_some() {
                muted
            } else if active {
                accent
            } else {
                base
            };
            let (label, value) = form.describe(*field);
            put(buf, r.x + 1, fy, 1, if active { "›" } else { " " }, accent);
            let label_w = if r.width < 45 { 10 } else { 12 };
            put(
                buf,
                r.x + 3,
                fy,
                label_w,
                label,
                if *field == Field::Create {
                    st.add_modifier(Modifier::BOLD)
                } else {
                    muted
                },
            );
            put(
                buf,
                r.x + 3 + label_w,
                fy,
                r.width.saturating_sub(6 + label_w),
                &value,
                st,
            );
            form.hits
                .push((Rect::new(r.x + 1, fy, r.width - 2, 1), *field));
        }
        put(
            buf,
            r.x + 2,
            r.bottom() - 2,
            r.width - 4,
            &form.error,
            if form.error.is_empty() {
                muted
            } else {
                base.patch(theme::fg(theme::DANGER))
            },
        );
    }
    if !side && !form.child_active {
        return None;
    }
    let Some(c) = &mut form.child else {
        return None;
    };
    let r = Rect::new(if side { x + form_w + 2 } else { x }, y, child_w, child_h);
    form.child_area = r;
    panel(buf, r, &c.picker.title, base, border);
    let query_x = r.x + 4;
    let query_y = r.y + 2;
    let query_w = r.width.saturating_sub(6) as usize;
    put(buf, r.x + 2, query_y, 1, "›", accent);
    let chars: Vec<_> = c.picker.query.chars().collect();
    let at = c.picker.qcursor.min(chars.len());
    let mut from = at;
    let mut width = 0;
    while from > 0 && width + chars[from - 1].width().unwrap_or(0) < query_w {
        from -= 1;
        width += chars[from].width().unwrap_or(0);
    }
    let query: String = chars[from..].iter().collect();
    put(
        buf,
        query_x,
        query_y,
        query_w as u16,
        if query.is_empty() {
            &c.picker.placeholder
        } else {
            &query
        },
        if query.is_empty() { muted } else { base },
    );
    c.picker.row_at.clear();
    if !c.kind.editing() {
        let rows = r.height.saturating_sub(6) as usize;
        c.picker.page_rows.set(rows as i64);
        c.picker.scroll = c
            .picker
            .scroll
            .min(c.picker.cursor)
            .max(c.picker.cursor.saturating_sub(rows.saturating_sub(1)));
        if c.picker.visible.is_empty() {
            put(
                buf,
                r.x + 3,
                r.y + 3,
                r.width - 6,
                c.picker.busy.as_deref().unwrap_or(&c.picker.empty),
                muted,
            );
        }
        let mut separator = 0;
        for (row, (index, _)) in c
            .picker
            .visible
            .iter()
            .enumerate()
            .skip(c.picker.scroll)
            .take(rows)
        {
            if c.kind == Choice::Project
                && c.picker.query.is_empty()
                && c.picker.rows[*index].id.starts_with("at:")
                && row > 0
                && !c.picker.rows[c.picker.visible[row - 1].0]
                    .id
                    .starts_with("at:")
            {
                separator = 1;
            }
            let at_y = r.y + 4 + (row - c.picker.scroll) as u16 + separator;
            if at_y >= r.bottom() - 2 {
                break;
            }
            let selected = row == c.picker.cursor;
            put(
                buf,
                r.x + 1,
                at_y,
                1,
                if selected { "›" } else { " " },
                accent,
            );
            put(
                buf,
                r.x + 3,
                at_y,
                r.width - 6,
                &c.picker.rows[*index].label,
                if c.picker.rows[*index].disabled {
                    muted
                } else if selected {
                    accent
                } else {
                    base
                },
            );
            c.picker.row_at.push((at_y, row));
        }
        let total = c.picker.visible.len();
        if total > rows && rows > 0 {
            let thumb = (rows * rows / total).max(1);
            let top = (rows - thumb) * c.picker.scroll / (total - rows);
            for dy in top..top + thumb {
                put(buf, r.right() - 2, r.y + 4 + dy as u16, 1, "│", muted);
            }
        }
    }
    let hint = if !form.error.is_empty() {
        &form.error
    } else {
        c.picker.busy.as_deref().unwrap_or("")
    };
    put(buf, r.x + 2, r.bottom() - 2, r.width - 4, hint, muted);
    form.child_active.then(|| {
        Position::new(
            query_x + (width as u16).min(r.width.saturating_sub(7)),
            query_y,
        )
    })
}
