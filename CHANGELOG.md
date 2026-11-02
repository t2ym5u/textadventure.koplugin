# Changelog

## [1.0.1] - 2026-11-02

### Changed
- Listed under **Tools → Games**, grouped by category, instead of its own
  entry in the Tools menu (game-common 1.9.1).

## [1.0.0] - 2026-10-30

### Added
- First release: a Z-machine interpreter (versions 3, 4, 5, 7, 8) in pure Lua, passing the CZECH and
  Praxix compliance suites.
- Library of stories found in `koreader/data/textadventure/` and the plugin's `stories/` folder:
  plain Z-code files and Blorb files (title from their iFiction metadata), "in progress" marker,
  and a help screen explaining where to get stories when the library is empty.
- Reading screen: paged transcript (tap zones, swipes, page keys), status line / upper window as a
  fixed header, shortcut buttons for common commands in the story's language (English or French),
  keyboard input with history, "Repeat", single-key mode for menus, font size setting.
- Automatic save after every turn and on close, resumed on open; SAVE/RESTORE in Quetzal format;
  multi-level UNDO.
- "Where to find stories": a curated list of free English and French stories with their IF Archive
  files, from the library menu and the empty library.
- Interface in English, French, Spanish and German.
