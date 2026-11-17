# bootstrap

Sets up a new machine with my usual tools, then pulls my dotfiles with chezmoi.

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/kimusan/bootstrap/main/bootstrap.sh)"
```

On Ubuntu it installs from apt where possible (neovim from the unstable PPA) and uses Homebrew for the rest. On anything else it uses Homebrew for everything. Safe to re-run.

Needs a GitHub SSH key on the machine first, since the dotfiles repo is private.
