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
