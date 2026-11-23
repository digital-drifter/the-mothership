# The Mothership

A native macOS app (SwiftUI, macOS 15+) that manages project terminals via a private tmux server.

## Build

    ./scripts/build-app.sh

Produces `build/Mothership.app`.

## Run

    open build/Mothership.app

## Test

    swift test

## Config

Projects are defined in `~/.config/mothership/projects.yml`. If the file is missing, the app creates it with a commented example. Edit it in any editor and reload.

Format (the same example the app writes, commented out, into a new file):

    projects:
      - name: Acme
        path: ~/Code/acme
        commands:
          - name: Vite
            run: npm run dev
            autostart: true
          - name: Queue
            run: php artisan queue:work
        agents:
          - name: Claude
            run: claude
          - name: Codex
            run: codex

Commands with `autostart: true` start when the app launches. Agents are templates: each "+" next to Agents starts a new session from one.

## Shortcuts

| Shortcut | Action |
| --- | --- |
| ⌘1 … ⌘9 | Select the first item of the Nth project and expand it |
| ⌘T | New terminal in the selected item's project (the first project if nothing is selected) |
| ⌘, | Open Config (File menu) |
| ⌘Q | Quit, leaving every session running |
| ⌥⌘Q | Stop All and Quit: asks to confirm, then ends the tmux server and every session |

## tmux

Sessions live on a private tmux server (socket `mothership`) that uses an app-owned config at `~/Library/Application Support/Mothership/tmux.conf`. Your own tmux and `~/.tmux.conf` are never touched. From a normal shell, list the sessions with:

    tmux -L mothership ls

## Launch overrides

Pass these as launch arguments, e.g. `open build/Mothership.app --args -configPath /tmp/x.yml -tmuxSocket ms-dev`:

- `-configPath <file>`: use this projects.yml instead of the default.
- `-tmuxSocket <name>`: use this tmux socket name instead of `mothership`.
- `-forceTmuxMissing YES`: pretend tmux is not installed, to see the missing-tmux screen.
