# Changelog

## [1.1.1] - 2026-11-03

### Changed
- Picks up game-common 1.11.0: the shared on-screen keyboard (where used)
  gives every key the same letter size, and the no-repeat history helper.

## [1.1.0] - 2026-11-02

### Added
- Multiplayer mode: also listed as "Text Adventures · multiplayer" under
  Tools → Games → Party & quiz, and switchable in the game (menu → Mode).
  One player is the Commander — the status line shows who, and the keyboard
  asks "Alice, type a command" — and command passes to the next player after
  every command, or every 2, 3 or 5 commands (Commander changes); Next
  commander passes it by hand. Text is larger by default (26) for reading
  across a table. The table's story, autosave and font size are kept apart
  from the solo ones.
- Font sizes 32 and 36.
- Separate multiplayer help (Rules opens the help of the mode played, with
  a button to read the other mode's).

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
