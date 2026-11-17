# bootstrap

Sets up a new machine with my usual tools, then pulls my dotfiles with chezmoi.

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/kimusan/bootstrap/main/bootstrap.sh)"
```

Use `bash -c "$(curl ...)"`, not `curl ... | bash`: chezmoi asks once for the age passphrase and `chsh` asks for your password, and both need the terminal.

Needs a GitHub SSH key on the machine first, since the dotfiles repo is private. Safe to re-run; anything already installed is skipped.

## Encrypted dotfiles

A few dotfiles are encrypted with [age](https://age-encryption.org): `config.fish`, `.git-credentials`, `~/.bin/wtf` and the ChatGPT token. They're encrypted to an age key pair, not to a passphrase, so chezmoi decrypts them without prompting.

- The private key lives in the dotfiles repo as `key.txt.age`, protected by the passphrase. That's the only passphrase-encrypted file.
- On first `chezmoi init --apply`, the repo's `run_onchange_before_decrypt-private-key.sh` asks for the passphrase once and writes the key to `~/.config/chezmoi/key.txt` (mode 600). It does nothing on later runs.
- The age settings (identity file and public key) come from the repo's `.chezmoi.toml.tmpl`, so a new machine gets them on `chezmoi init`.

To encrypt another file: `chezmoi add --encrypt <file>`. To change an encrypted file: `chezmoi edit --apply <file>`. Neither asks for the passphrase once the key is in place.

## What it installs

On Ubuntu, packages come from apt when the archive has a usable version. Everything else comes from Homebrew (installed if missing). On any other OS, everything comes from Homebrew.

### Shell and core

| Tool | Source | Why |
|---|---|---|
| fish | apt | Login shell; `chsh` is set to it at the end |
| git, curl, wget | apt | Fetching dotfiles and the installers below |
| build-essential, clang, make | apt | Neovim plugins that compile (treesitter parsers, avante.nvim's `make` build) |
| unzip | apt | Mason (LazyVim) unpacks language servers with it |
| age | apt | chezmoi decrypts the encrypted dotfiles (`config.fish`, git credentials) with it |
| tmux | apt | `.tmux.conf` is still synced, kept as a fallback to Zellij |

### Terminal workflow

| Tool | Source | Why |
|---|---|---|
| zellij | Homebrew | Terminal multiplexer, started automatically by `conf.d/zellij.fish` |
| fzf | apt | fzf.fish plugin and the `Ctrl-o` file picker in fish |
| eza | apt | The `ls` fish function wraps it |
| bat | apt | The `bat` fish function (Ubuntu names it `batcat`), the `Ctrl-o` preview, lf text previews |
| tree | apt | The `tree` fish function wraps it |
| lf | apt | File manager, `lfcd` function |
| tig, lazygit | apt, Homebrew | Git UIs; `.tigrc` is synced, lazygit opens from LazyVim with `<leader>gg` |
| jq | apt | Zellij tab auto-naming (`zellij-tabname.fish`) and `ask_gpt` |
| wl-clipboard | apt | Zellij copies to the clipboard with `wl-copy` |
| xclip | apt | tmux copy mode copies with it |
| autojump, grc | apt | Oh My Fish packages in the bundle need the binaries |

### Less obvious ones (used by fish functions and scripts)

| Tool | Source | Used by |
|---|---|---|
| perl | apt | `local-ip` parses `ifconfig` output with it |
| net-tools | apt | `ifconfig` for `local-ip`, `route`/`arp` for `netpeek` |
| dnsutils | apt | `dig` for `remote-ip`, `host`/`nslookup` for `netpeek` |
| cowsay | apt | `dadjoke` |
| python3-poetry | apt | `vbump` bumps versions with `poetry version` |
| python3-pip, python3-venv | apt | Python tooling; the hishtory installer runs with python3 |
| poppler-utils | apt | lf previews PDFs with `pdftotext` |
| p7zip-full | apt | lf previews 7z and rar archives |
| libimage-exiftool-perl | apt | lf shows metadata for binary files with `exiftool` |
| kitty | apt | Provides `kitten`, which lf uses to draw image previews (kitty graphics protocol, works in Ghostty and Zellij). On macOS install the kitty app instead. |

### Editor

| Tool | Source | Why |
|---|---|---|
| neovim | `ppa:neovim-ppa/unstable` | The Ubuntu 24.04 archive has 0.9, LazyVim needs newer |
| ripgrep, fd-find | apt | LazyVim's search and file pickers |
| Rust (rustup) | rustup.rs | avante.nvim builds its native libraries with cargo and needs a current toolchain (apt's is too old) |
| node | nvm.fish | `config.fish` runs `nvm use latest`; Mason needs node/npm for many language servers |

### Installed by script

| Tool | Source | Why |
|---|---|---|
| Homebrew | brew.sh installer | For zellij and lazygit, which apt doesn't have |
| hishtory | hishtory.dev installer | Shell history search; `config.fish` sources it. Run `hishtory init <secret>` to sync with other machines |
| Oh My Fish | upstream installer | Theme (elderitch) and the packages in `~/.config/omf/bundle`. Installed before chezmoi, because the installer refuses to run if `~/.local/share/omf` already exists |
| chezmoi | get.chezmoi.io, into `~/.bin` | Pulls and applies the dotfiles |

### After the dotfiles are in place

- `fisher update`: fzf.fish, fc-fish and nvm.fish from `fish_plugins`
- `omf install`: everything in the Oh My Fish bundle
- `nvm install latest`: node
- `nvim --headless "+Lazy! sync"`: LazyVim plugins, including the avante.nvim build
