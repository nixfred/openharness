//! Presentation insets live outside the tmux layout tree. Its splits and named layouts
//! remain unchanged; the terminal, cursor, copy mode and mouse share this content rectangle.

use ratatui::layout::Rect;
use crate::layout::Status;

#[derive(Clone, Copy, Debug)]
pub struct Frame { pub surface: Rect, pub content: Rect, pub title: Option<Rect> }

pub fn frame(tile: Rect, canvas: Rect, status: Status) -> Frame {
    let mut outer = tile;
    // A small pane gives its cells to the program. Larger panes keep one-cell outer space.
    if tile.width >= 12 && canvas.width >= 40 {
        if tile.x == canvas.x { outer.x += 1; outer.width -= 1; }
        if tile.right() == canvas.right() { outer.width = outer.width.saturating_sub(1); }
    }
    if tile.height >= 8 && canvas.height >= 12 {
        // With top/bottom status, tmux borrows the divider row for a pane title. Leave
        // that row as a gutter and draw the title inside the surface instead.
        if tile.y == canvas.y || status == Status::Top { outer.y += 1; outer.height -= 1; }
        if tile.bottom() == canvas.bottom() || status == Status::Bottom { outer.height = outer.height.saturating_sub(1); }
    }
    // Fill the entire pane. The former outline cells are now blank padding, keeping
    // title/content coordinates stable while focus is shown by the background alone.
    let surface = outer;
    let roomy = tile != canvas && tile.width >= 12 && canvas.width >= 40
        && tile.height >= 8 && canvas.height >= 12;
    let inner = if roomy {
        Rect::new(surface.x + 1, surface.y + 1, surface.width - 2, surface.height - 2)
    } else { surface };
    let title = (inner.height > 1 && status != Status::Off).then(|| Rect::new(inner.x,
        if status == Status::Bottom { inner.bottom() - 1 } else { inner.y }, inner.width, 1));
    let mut content = inner;
    if title.is_some() {
        if status == Status::Top { content.y += 1; }
        content.height -= 1;
    }
    if content.width >= 12 { content.x += 1; content.width -= 2; }
    if content.height >= 10 { content.y += 1; content.height -= 2; }
    Frame { surface, content, title }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn small_panes_keep_usable_cells_and_every_rect_stays_inside() {
        for w in 1..=100 { for h in 1..=40 { for status in [Status::Off, Status::Top, Status::Bottom] {
            let tile = Rect::new(3, 2, w, h);
            let canvas = Rect::new(0, 0, w + 8, h + 6);
            let f = frame(tile, canvas, status);
            assert_eq!(f.surface.intersection(tile), f.surface);
            assert_eq!(f.content.intersection(f.surface), f.content);
            assert!(f.content.width > 0 && f.content.height > 0);
            if let Some(title) = f.title { assert_eq!(title.intersection(f.content).height, 0); }

        } } }
    }

    #[test]
    fn stacked_and_side_by_side_surfaces_leave_divider_gaps() {
        let canvas = Rect::new(0, 0, 120, 40);
        let left = frame(Rect::new(0, 0, 59, 40), canvas, Status::Top);
        let right = frame(Rect::new(60, 0, 60, 40), canvas, Status::Top);
        assert_eq!(right.surface.x - left.surface.right(), 1);
        assert_eq!(left.surface.intersection(right.surface).width, 0);
        let top = frame(Rect::new(0, 0, 120, 20), canvas, Status::Top);
        let bottom = frame(Rect::new(0, 20, 120, 20), canvas, Status::Top);
        assert_eq!(bottom.surface.y - top.surface.bottom(), 1);
        assert_eq!(top.surface.intersection(bottom.surface).height, 0);
        assert!(top.content.y > top.title.unwrap().y);
        let single = frame(canvas, canvas, Status::Top);
        assert_eq!(single.title.unwrap().y, single.surface.y);
        // Compact and single panes give the extra padding back to their content.
        let compact = frame(Rect::new(20, 20, 40, 5), canvas, Status::Top);
        assert_eq!(compact.title.unwrap().y, compact.surface.y);
    }
}
