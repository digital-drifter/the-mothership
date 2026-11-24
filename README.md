# The Mothership

A native macOS app (SwiftUI, macOS 15+) that manages project terminals via a private tmux server.

## Build

    ./scripts/build-app.sh

Produces `build/Mothership.app`.

## Run

    open build/Mothership.app

## Test

    swift test

## Projects and data

Projects are added in the app. Everything (projects, commands, the saved agent list) lives in `~/Library/Application Support/Mothership/projects.json`, which the app manages for you. If that file can't be read, the app keeps it as `projects.json.unreadable-<timestamp>` and starts fresh.

- **Add Project** (⌘O, or the button at the bottom of the sidebar): pick a folder. Its name becomes the project name.
- **Project menu** (right-click a project name): Rename, Change Folder, Remove. Removing stops the project's sessions and never touches the folder on disk.
- **Agents `+`**: starts an agent from the saved list. **Custom…** runs a one-off command, and can save it to the list. **Manage List…** removes saved agents.
- **Commands `+`**: add a command (name, command, and whether to start it automatically when Mothership opens). Right-click a command for Start, Stop, Restart, Edit… and Delete…. A command can also have a working directory, relative to the project folder (or an absolute path); blank means the project folder. A changed command or directory applies on the next Start or Restart.

## Shortcuts

| Shortcut | Action |
| --- | --- |
| ⌘1 … ⌘9 | Select the first item of the Nth project and expand it |
| ⌘O | Add Project |
| ⌘T | New terminal in the selected item's project (the first project if nothing is selected) |
| ⌘Q | Quit, leaving every session running |
| ⌥⌘Q | Stop All and Quit: asks to confirm, then ends the tmux server and every session |

## tmux

Sessions live on a private tmux server (socket `mothership`) that uses an app-owned config at `~/Library/Application Support/Mothership/tmux.conf`. Your own tmux and `~/.tmux.conf` are never touched. From a normal shell, list the sessions with:

    tmux -L mothership ls

## Launch overrides

Pass these as launch arguments, e.g. `open build/Mothership.app --args -dataPath /tmp/x.json -tmuxSocket ms-dev`:

- `-dataPath <file>`: use this projects.json instead of the default.
- `-tmuxSocket <name>`: use this tmux socket name instead of `mothership`.
- `-forceTmuxMissing YES`: pretend tmux is not installed, to see the missing-tmux screen.
