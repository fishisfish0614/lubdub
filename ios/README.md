# lubdub / ios

The writer's side, as a SwiftUI reference client. This is a desensitized port of the UI the household version runs; the interaction design survives intact, the household's plumbing (names, push routes, chat stream, custom fonts) does not.

## What it looks like

The wall is a fogged-up window. Letters are panes of misted glass: you arrive to a closed pile, a tap fans it out along an arc you spin with inertia, and the centered card pulls out full-size. A **developed** letter is wiped clear with a finger — half the pane and the fog dissolves, and the letter reads like a page, replies following as their own short pages. A **locked** letter only lets you thin the fog for a moment before it settles back; there is nothing under it, and the only words it ever says are "not yet". Locked or due is told apart by exactly one thing: the wax seal. The wipe is remembered locally, so a letter you've read greets you clear.

Fog is never a color laid on top. The window, the fog and the clear face are the same scene — sharp, or blurred with a breath of white, grain and droplets. Both the window and the cards can take a photo of your own (the looks panel, top right); photos stay in the app's Documents and are never uploaded.

## Files

| File | What |
|---|---|
| `Lubdub/LubdubApp.swift` | App entry, settings (server + token), top-right buttons |
| `Lubdub/Letters.swift` | Models + the API client (`/letters`, Bearer writer token) |
| `Lubdub/FogScene.swift` | The scene pairs (sharp/fog), grain, mottle, droplets, veils |
| `Lubdub/LetterWall.swift` | The wall: pile ⇄ arc wheel (frame-stepped springs), fog cards, looks panel |
| `Lubdub/WipeOverlay.swift` | The pulled-out card: finger-wipe, re-fogging for locked letters |
| `Lubdub/Composer.swift` | Writing: `lock_for` quick picks or a `reveal_at` date picker |
| `Lubdub/ChatCards.swift` | Chat-side reference components: locked card, reveal card, reply row, tombstone, demo |

## Running it

1. Xcode → new iOS App project (SwiftUI, iOS 17+), drop the `Lubdub/` folder in, delete the template's `App`/`ContentView`. No Info.plist entries needed — the photo picker is the out-of-process one.
2. Run `server.py` somewhere, set `writer_token` in its `config.json`.
3. In the app's settings (gear, top right): the server address and that token. The server binds to localhost — put it behind your reverse proxy for a phone, or use `http://127.0.0.1:7272` from the simulator.

## What's different from the household version

- **No websocket, no push.** The open-source server notifies through hooks; the wall polls every 45 s while visible, re-asks when a countdown runs out, and reloads on foreground. Reveals and replies arrive a poll late at worst.
- **Chat cards are components, not a chat.** The household version renders them inside its own chat stream (the stream tags messages with a letter chip). Here they take a `Letter` and ship with a fixture-data demo — place them in your own conversation UI. The rules they encode are in the header comment of `ChatCards.swift`; the one that matters most: *the locked card never flips into content, because transcripts get replayed.*
- **Scenes are local.** The household version mirrors its chat wallpaper and syncs choices across devices; here the built-in scene is a rendered evening window, your photos stay on device, and looks live in UserDefaults.
- **System serif** stands in for the household's licensed handwriting face (`LetterFont` in `FogScene.swift` is the single swap point).
- **tlock letters** show as locked cards without content, matching what the server gives the writer back (nothing until the reveal).

The web version (`web/`, if it has landed by the time you read this) follows this directory as its blueprint — same numbers, same rules.
