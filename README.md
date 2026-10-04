# Claude Dock Clean

A tiny macOS menu bar app that clears the extra Claude icons a subagent swarm leaves in the Dock.

The pinned Claude icon stays. This app has no Dock icon of its own. No settings window, no network access, no dependencies. One Swift file.

## Features

- Menu bar icon shows how many Claude Dock icons are stuck past the first one
- Clean up drops the duplicate recent-app entries, then restarts the Dock so the ghost tiles go away
- The pinned Claude icon is left where it is
- Open at Login toggle in the menu

## Install

### Download

1. Grab `ClaudeDockClean.zip` from the [latest release](https://github.com/AndreCamm/ClaudeDockClean/releases/latest) and unzip it.
2. Move `ClaudeDockClean.app` to your Applications folder.
3. Open it. The app isn't notarised by Apple, so the first time macOS will block it. Go to **System Settings, Privacy & Security**, scroll down and click **Open Anyway**. Alternatively, run:

   ```
   xattr -dr com.apple.quarantine /Applications/ClaudeDockClean.app
   ```

### Build from source

You need Xcode or the Command Line Tools (`xcode-select --install`).

```
git clone https://github.com/AndreCamm/ClaudeDockClean.git
cd ClaudeDockClean
./build.sh
cp -r build/ClaudeDockClean.app /Applications/
open /Applications/ClaudeDockClean.app
```

Apps you build yourself aren't quarantined, so there's no Gatekeeper prompt.

## Using it

Click the **C** in the menu bar, then **Clean up**. The Dock disappears for a moment and comes back with one Claude icon.

**The number.** It is the count of Claude icons after the first one. That count needs Accessibility access. Cleanup works without it. The first time, choose **Allow Dock counting…** and turn the app on under System Settings, Privacy & Security, Accessibility. If the switch is already on and the menu still says access is off, turn it off and on again, then choose **Relaunch to apply access**. macOS ties that permission to the app's signature, and a rebuild changes an ad-hoc signature.

**Open at login.** Click the item and tick **Open at Login** (macOS 13 or later).

**Quit.** Click the item and choose Quit.

## Why the icons stick

A Claude subagent swarm registers a Dock tile for each agent. The processes quit. The Dock keeps the tiles and still marks them as running. They are not part of the saved Dock layout. Restarting the Dock drops them.

A normal Dock restart can write those ghost tiles into the layout before it quits. Clean up deletes the duplicate recent-app entries first, then restarts the Dock with `killall -9` so it cannot save them.

## Requirements

- macOS 13 Ventura or later

## Contributing

Issues and pull requests are welcome. The whole app lives in [`Sources/ClaudeDockClean.swift`](Sources/ClaudeDockClean.swift), and the aim is to keep it small and single purpose.

## License

[MIT](LICENSE)
