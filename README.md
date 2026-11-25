<img src="docs/icon.png" width="128" alt="Profile Bubbles icon">

# Profile Bubbles

Small bubbles that always float at the edge of your Mac screen (left by default), one per
Google Chrome profile. Click a bubble (or press a hotkey) to jump to that profile's window.

Native macOS app: one Swift file, no dependencies, no network access.

## What it does

- One bubble per Chrome profile, with the profile's picture or its first letter.
- **Click** a bubble: brings that profile's open Chrome window to the front, tabs untouched.
  If the profile has no window, Chrome opens one.
- **Control+Option+1 … 9**: same as clicking bubble 1 … 9 (top to bottom).
- Hover shows the profile name and its hotkey.
- Choose where the bubbles sit: left edge, right edge, around the notch, bottom left or bottom right.
- Stays visible on every Space and over full-screen apps. No Dock icon.
- Right-click a bubble: settings, reload, edit the list, open at login, quit.

## Requirements

- macOS 13 or later, Google Chrome.
- Xcode Command Line Tools to build (`xcode-select --install`). Full Xcode is not needed.

## Build and run

```sh
./build.sh
open "build/Profile Bubbles.app"
```

There is no prebuilt download yet: the app is not notarized, so build it yourself.

## Settings

Right-click a bubble → **Settings…**

| Setting | Options |
|---|---|
| Position | Left edge, Right edge, Around the notch, Bottom left, Bottom right |
| Bubble size | Small, Medium, Large |
| Open at login | On / off |

- **Left / right edge:** a vertical column. Drag a bubble up or down to move the column.
- **Bottom left / right:** a horizontal row in the very corner of the screen, beside the Dock
  (on top of it if the Dock is wide enough to reach the corner).
- **Around the notch:** the bubbles sit inside the menu bar, half on each side of the notch, and
  take the menu bar's height (the size setting is ignored). They can cover menu titles or menu bar
  icons that reach the notch. On a Mac without a notch they form a centred row under the menu bar.

## Agent bubbles (Orca)

When [Orca](https://github.com/stablyai/orca) is running, a second row of bubbles sits in the
bottom-right corner, one per coding agent Orca runs (Claude Code, Codex, …). Settings has a
position for it apart from the Chrome profiles: bottom right or left, top right or left (under
the menu bar), in the menu bar left or right of the notch, or the right or left edge. **Long
badges** show each agent's title next to its icon. Either set of bubbles can be turned off.

- The ring shows the state: blue working (an arc runs around it), orange needs approval, yellow
  waiting for you, green done. One sound plays when an agent finishes and a different one when
  it needs an approval or an answer. Pick each in Settings from the bundled chimes (Sparkle,
  Kira Kira, Pikon, Level Up, Ta-da, …), the macOS system sounds, or your own files: **Add your
  own sounds…** opens a folder that takes wav, aiff, mp3 and m4a. For anime-style girl voice
  lines ("Yattaa!", "Chotto matte", "Yobimashita?", …) run `python3 scripts/get-voice-sounds.py`:
  it downloads 25 free lines recorded by a voice actress from 効果音ラボ (Sound Effect Lab) into
  that folder. For meme sounds (Vine boom, Bruh, Emotional damage, Metal Gear alert, Ối dồi ôi,
  Khá Bảnh, Nhạc xổ số, …) run `python3 scripts/get-meme-sounds.py`; it downloads them from the
  Myinstants soundboard. Any sound stops after 5 seconds.
  Finished agents leave the row after 30 minutes.
- Click a bubble to bring Orca forward on that agent's terminal tab.
- When an agent asks for an approval or a choice, a bar above the row shows the question with a
  button per option. A button presses that option in the agent's terminal; the menu is read again
  first, and if it changed the app jumps to the tab instead. Options that need typing have no button.

Hover a bubble for a card with the agent's last message (while it works: the last lines of its
terminal, refreshed live, so you can see what it is doing) and its suggested next actions:

- asking for approval or a choice: one button per option;
- working: **Interrupt** (sends Escape);
- idle with text in its input box (a draft, or the next prompt the agent suggests): **↵ text**
  presses Enter on it;
- idle with an empty input box: your quick prompts (`continue` and `commit` by default, edit them
  in Settings).

Clicking the bubble, or the card itself, opens the agent's tab in Orca.

A finished agent's card has a **✕ Remove** button that takes its bubble off the row. The bubble
comes back when that agent starts working again.

The card also has a reply box: type and press Return to send your own message to the agent (it is
queued when the agent is working, and goes through the menu's "Type something" option when a
question is open). Escape closes the card. If the screen changed before sending, the text is put on
the clipboard and the app jumps to the tab.

Each button reads the terminal again first and acts only when the screen still shows what the card
showed; otherwise it jumps to the tab.

The data comes from the `orca` command-line tool inside Orca.app (polled every 2 seconds), so
nothing is installed into the agents. Turn the row off in Settings.

### Claude Code outside Orca

Tick **Claude Code outside Orca** in Settings (or run
`python3 scripts/claude-hooks.py install "<path>/Profile Bubbles.app/Contents/MacOS/ProfileBubbles"`)
to also get a bubble for Claude Code sessions in Terminal, iTerm, an editor's terminal or the
Claude app. This adds hooks to `~/.claude/settings.json`; other hooks there are left alone and a
copy of the file is kept as `settings.json.profile-bubbles.bak`. Sessions started before that need
a restart to be seen.

- The bubble, the state ring, the finished sound and the last message work as for Orca agents. A
  permission request or a question shows on the bar as text.
- A click brings forward the app that holds the session, not the exact tab.
- There are no buttons and no reply box: without Orca the app has no way to type into the session.
- "Needs approval" stays on until the approved tool has finished, since Claude Code sends no event
  at the moment you approve.
- The hooks call the app's binary at the path it had when you ticked the box. If you move the app,
  untick and tick the box again.

## Permissions

| Permission | Why | Required? |
|---|---|---|
| Accessibility | Find and raise the Chrome window of a profile | Needed to focus an existing window. Without it every click opens a new window. |
| Full Disk Access | Read the profile list from Chrome's `Local State` file | Optional. Skip it by listing your profiles by hand (below). |

The app reads only the profile names, pictures and folder names. It never reads cookies,
history or passwords, and it sends nothing anywhere.

### Listing profiles by hand (no Full Disk Access)

Right-click a bubble → **Edit List**, or create
`~/Library/Application Support/ProfileBubbles/profiles.json`:

```json
[
  {"dir": "Default",   "name": "Personal", "color": "#1a73e8"},
  {"dir": "Profile 1", "name": "Work",     "color": "#e8710a", "image": "~/Pictures/work.png"}
]
```

- `dir` is the profile's folder name: open `chrome://version` in that profile and take the last
  part of **Profile Path**. Do not guess it: Chrome creates a new empty profile for an unknown name.
- `name` must match the profile's name in Chrome, because the app finds the window by that name.
- `color` and `image` are optional. When this file exists it replaces Chrome's own list, so it also
  lets you hide or reorder profiles.

### Keeping permissions across rebuilds

macOS ties a permission to the app's signature. An ad-hoc signature changes on every build, so the
grants are lost each time. To keep them, create a self-signed certificate once: **Keychain Access →
Certificate Assistant → Create a Certificate**, name `Local App Signing`, type **Code Signing**.
`build.sh` uses it automatically when it exists (set `SIGN_IDENTITY` to use another name).

## Known limits

- A profile window on another Space or in full screen is not found, so Chrome may open a new window.
- Works with Google Chrome only.
- Focusing relies on Chrome's window titles ending with the profile name, which Chrome does when
  more than one profile exists. A Chrome update can change this.

## Troubleshooting

Log file: `~/Library/Logs/ProfileBubbles.log`. Start with `--args --debug-menus` to log how the
app sees Chrome's menus. The log records profile names only, never page titles.

## License

MIT. Not affiliated with or endorsed by Google. Google Chrome is a trademark of Google LLC.
