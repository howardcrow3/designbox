# DesignBox app icon

The **High Turtle mark** (a smiling turtle, single ink) in the brand's reversed ink, centred on a
rounded ink tile.

## Palette

Exactly two colours, both from the High Turtle brand:

| Colour | Hex | Used for |
|---|---|---|
| Ink | `#17181a` | the tile |
| On-ink | `#f6f6f5` | the turtle |

## Geometry

A 512-unit tile (`viewBox="0 0 512 512"`), rounded square with `rx=112`, no border. The mark is
348 units wide and centred. The macOS renders pad the tile onto Apple's 824/1024 icon grid; Windows
and Linux use the tile edge to edge, with its rounded corners.

## Provenance

The mark comes from the High Turtle logo (`docs/brand/mark-reversed.svg`, traced from the supplied
artwork); the tile is drawn here. License: see `LICENSE.txt`.

## Files

- `designbox.svg`: canonical master. `designbox-small.svg`: the same drawing, the hicolor scalable icon.
- `designbox-<size>.png` (16-1024): renders on the macOS grid; `packaging/macos/package.sh` builds
  the `.icns` from them.
- `designbox.ico`: Windows icon, 16-256 px, embedded in the `.exe` by `apps/designbox/build.rs`.
- `hicolor/<size>/apps/studio.turtlebox.designbox.png` (16-512) and `hicolor/scalable/...svg`:
  Linux icon theme; the 256 px one is also the runtime window icon off macOS.

## Regenerate

Replace `designbox.svg` (and `designbox-small.svg`), then run `cargo xtask icon`. It needs `resvg`
(`cargo install resvg`).
