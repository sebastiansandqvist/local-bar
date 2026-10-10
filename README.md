# Local Bar

A small macOS menu bar app to manage your local servers.

Requirements:

- MacOS 13+
- Xcode command-line tools
- Homebrew

From the repo folder:

```sh
brew install caddy
bash scripts/build-app.sh
open "build/Local Bar.app"
bash scripts/setup-caddy.sh
```

If you already have Caddy running, pass the path to your Caddyfile to the setup script the first time. Local Bar will save a backup of the Caddyfile and add its routes without changing your other routes. After a reboot, run the script again to start Caddy.

For a Caddyfile in Homebrew's default location:

```sh
bash scripts/setup-caddy.sh "$(brew --prefix)/etc/Caddyfile"
```

If a server is already running in your terminal, you will need to stop it from the terminal before starting it in Local Bar.

## Updating

Quit Local Bar, then run this from the repo folder on each Mac. Your servers keep running while the app is closed.

```sh
git pull --ff-only
bash scripts/build-app.sh
open "build/Local Bar.app"
```
