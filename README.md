# TabWM

Tabs for any window on your Mac. Put windows from different apps into one group and switch between them like browser tabs.

- Every group fills the screen, below the menu bar and above the Dock, inside one frame: a tab strip on top and a thin border around the rest.
- Liquid Glass frames, or solid colors from the [Catppuccin](https://catppuccin.com) palette (Latte in light mode, Mocha in dark mode).
- Keyboard-first: one leader key (🌐 Globe by default) for every shortcut.
- One plain-text settings file you can edit, sync, or keep in your dotfiles.

Requires macOS 15 or later. Liquid Glass needs macOS 26; earlier versions get a material look.

## Install

Build it from source (see [Building](#building)), then move `dist/TabWM.app` to `/Applications` and open it.

On first launch, open **Settings → General** and allow:

| Permission | Why |
| --- | --- |
| Accessibility | Required. Lets TabWM see, arrange, focus, and close the windows you group. |
| Input Monitoring | Required for keyboard shortcuts. |
| Screen Recording | Optional. Shows window previews in tab search. |

Turn off Stage Manager: grouping pauses while it is on. If you use 🌐 as the leader, set **System Settings → Keyboard → Press 🌐 key to → Do Nothing**.

## Using TabWM

**Make a group**

- Hold 🌐 and drag a window onto another. Release when the blue “Release to group” highlight appears.
- Press 🌐 G to group every window on the current desktop.
- Use **Group Windows…** in the menu bar to pick windows from a list.
- New windows join the group you were working in (you can turn this off).

**Work with tabs**

- Click a tab, or press 🌐 ← / 🌐 →, to switch.
- Drag a tab to reorder it, onto another group's strip to move it, or off the strip to detach it.
- Press 🌐 T or the + button to add ungrouped windows to the group.
- Press 🌐 S or the search button to find any tab by name, with a large live preview.

**How groups behave**

- Groups never move or resize; every window that joins takes the group's size.
- Moving or resizing a grouped window yourself (title bar, edges, zoom, tiling or window-manager shortcuts) takes it out of the group. An app resizing itself is put back.
- Inactive tabs wait behind the visible one. Full-screen windows and windows moved to another desktop either stay as paused tabs or leave the group, as you choose.
- The menu bar menu lists your groups by the desktop they're on.
- Groups come back after you relaunch TabWM, until the Mac restarts.

## Shortcuts

| Shortcut | Action |
| --- | --- |
| 🌐 G | Group every window on the current desktop |
| 🌐 T | Add ungrouped windows to the current group |
| 🌐 U | Ungroup the current group |
| 🌐 S | Search tabs |
| 🌐 ← / 🌐 → | Previous / next tab |

Hold the leader and press the key, or tap the leader and press the key within a second. Change the leader once (Globe, a right-hand modifier, or a chord such as ⌃⌥) and every shortcut follows. Any shortcut can use its own combo instead, or be turned off.

## Settings file

All settings live in one file: `~/.config/TabWM/settings.toml` (or `$XDG_CONFIG_HOME/TabWM/settings.toml`). The Settings window, Export, and Import all use it, and TabWM applies changes as soon as you save the file.

It holds only your choices, grouped like the Settings window, with the allowed values next to each setting:

```toml
leader     = "globe"   # globe | right-cmd | right-opt | right-ctrl | ctrl+opt | ctrl+opt+cmd | hyper | off
tap-leader = true      # true | false

[shortcuts]
group-all   = "leader+G"   # "leader+KEY" | "MODIFIERS+KEY" | "off"
search      = "leader+S"   # "leader+KEY" | "MODIFIERS+KEY" | "off"

[appearance]
style        = "glass"   # glass | color
border-width = 2         # 0 – 10
```

Anything you leave out uses its default; **Settings → General → Restore Defaults** resets everything. Your open groups are kept separately, in `~/Library/Application Support/TabWM`.

## Building

```sh
./scripts/create-signing-identity.sh   # once: a local signing certificate (see below)
./scripts/build-app.sh                 # builds and signs dist/TabWM.app, including the icon
./scripts/test-core.sh                 # runs the core tests
```

The build uses the Xcode Command Line Tools and installs nothing. The signing script creates a self-signed certificate, “TabWM Local Signing”, in your login keychain. Without it each build is signed ad hoc, and macOS asks for Accessibility and Input Monitoring again after every build.

`dist/TabWM.app/Contents/MacOS/TabWM --smoke-output .build/ui-smoke` renders the main windows offscreen to PNG files, without touching any real windows.

TabWM uses a few private macOS window-server functions (window events and positions). They need no special permissions and work with System Integrity Protection on, but they rule out the Mac App Store.

## License

[MIT](LICENSE)
