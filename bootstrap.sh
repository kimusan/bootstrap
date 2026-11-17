#!/usr/bin/env bash
# Set up a new machine: install the tools the dotfiles use, then pull the
# dotfiles with chezmoi. Safe to re-run; anything already installed is skipped.
#
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/kimusan/bootstrap/main/bootstrap.sh)"
#
# Use that form, not `curl | bash`: chezmoi asks for the age passphrase and
# chsh asks for your password, and both need the terminal on stdin.
set -euo pipefail

DOTFILES_REPO="${DOTFILES_REPO:-git@github.com:kimusan/dotfiles.git}"

# Ubuntu: from apt (neovim from the unstable PPA, the archive one is too old
# for LazyVim). Everything apt doesn't have comes from Homebrew.
APT_PACKAGES=(
  fish git curl wget unzip build-essential clang make perl
  fzf ripgrep fd-find bat eza jq lf tig tree cowsay
  wl-clipboard xclip net-tools dnsutils
  autojump grc age
  python3-pip python3-venv python3-poetry
  tmux
  # lf previews: pdf, 7z/rar, file metadata, images (kitten ships with kitty)
  poppler-utils p7zip-full libimage-exiftool-perl kitty
)
BREW_ON_UBUNTU=(zellij lazygit)

# Any other OS: everything from Homebrew.
BREW_PACKAGES=(
  fish git curl wget neovim
  fzf ripgrep fd bat eza jq lf tig tree cowsay
  autojump grc age poetry
  tmux zellij lazygit
  # lf previews (no kitten here: on macOS install the kitty app for image previews)
  poppler p7zip exiftool
)

log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m!! %s\033[0m\n' "$*" >&2; }
have() { command -v "$1" >/dev/null 2>&1; }

if [ "$(id -u)" -eq 0 ]; then
  echo "Run this as your normal user, not root. It uses sudo where needed." >&2
  exit 1
fi

OS_ID=unknown
[ -r /etc/os-release ] && OS_ID="$(. /etc/os-release && echo "${ID:-unknown}")"

ensure_brew() {
  if ! have brew; then
    for b in /home/linuxbrew/.linuxbrew/bin/brew /opt/homebrew/bin/brew /usr/local/bin/brew; do
      [ -x "$b" ] && eval "$("$b" shellenv)" && break
    done
  fi
  if ! have brew; then
    log "Installing Homebrew"
    NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    for b in /home/linuxbrew/.linuxbrew/bin/brew /opt/homebrew/bin/brew /usr/local/bin/brew; do
      [ -x "$b" ] && eval "$("$b" shellenv)" && break
    done
  fi
}

brew_install() {
  local missing=()
  for p in "$@"; do brew list --formula "$p" >/dev/null 2>&1 || missing+=("$p"); done
  if [ ${#missing[@]} -gt 0 ]; then
    log "brew install ${missing[*]}"
    brew install "${missing[@]}"
  fi
}

install_packages_ubuntu() {
  log "apt packages"
  sudo apt-get update -qq
  sudo apt-get install -y software-properties-common
  if ! grep -rqs "neovim-ppa/unstable" /etc/apt/sources.list.d/; then
    sudo add-apt-repository -y ppa:neovim-ppa/unstable
    sudo apt-get update -qq
  fi
  sudo apt-get install -y "${APT_PACKAGES[@]}" neovim

  ensure_brew
  brew_install "${BREW_ON_UBUNTU[@]}"
}

install_rust() {
  if [ ! -x "$HOME/.cargo/bin/rustup" ]; then
    log "Installing Rust (rustup), needed to build avante.nvim"
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --no-modify-path
  else
    "$HOME/.cargo/bin/rustup" update stable
  fi
}

install_hishtory() {
  if [ ! -x "$HOME/.hishtory/hishtory" ]; then
    log "Installing hishtory"
    curl -fsSL https://hishtory.dev/install.py | python3 -
  fi
}

# Must run before chezmoi: the installer refuses to touch an existing
# ~/.local/share/omf, and chezmoi puts the elderitch theme there.
install_omf() {
  if [ ! -d "$HOME/.local/share/omf/.git" ]; then
    log "Installing Oh My Fish"
    if [ -d "$HOME/.local/share/omf" ]; then
      mv "$HOME/.local/share/omf" "$HOME/.local/share/omf.pre-bootstrap"
    fi
    local tmp
    tmp="$(mktemp)"
    curl -fsSL https://raw.githubusercontent.com/oh-my-fish/oh-my-fish/master/bin/install -o "$tmp"
    fish "$tmp" --noninteractive --yes
    rm -f "$tmp"
    if [ -d "$HOME/.local/share/omf.pre-bootstrap" ]; then
      cp -rn "$HOME/.local/share/omf.pre-bootstrap/." "$HOME/.local/share/omf/"
      rm -rf "$HOME/.local/share/omf.pre-bootstrap"
    fi
  fi
}

install_chezmoi_and_dotfiles() {
  mkdir -p "$HOME/.bin"
  if ! have chezmoi && [ ! -x "$HOME/.bin/chezmoi" ]; then
    log "Installing chezmoi"
    sh -c "$(curl -fsLS get.chezmoi.io)" -- -b "$HOME/.bin"
  fi
  export PATH="$HOME/.bin:$PATH"

  if [ ! -d "$HOME/.local/share/chezmoi/.git" ]; then
    log "Fetching dotfiles from $DOTFILES_REPO"
    local ssh_out
    ssh_out="$(ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -T git@github.com 2>&1 || true)"
    if [[ "$DOTFILES_REPO" == git@github.com:* ]] && [[ "$ssh_out" != *"successfully authenticated"* ]]; then
      warn "No GitHub SSH access. Add this machine's SSH key to GitHub, then re-run."
      warn "  ssh-keygen -t ed25519 && cat ~/.ssh/id_ed25519.pub"
      exit 1
    fi
    chezmoi init --apply "$DOTFILES_REPO"
  else
    log "Updating dotfiles"
    chezmoi update
  fi
}

setup_fish() {
  log "fish plugins (fisher, Oh My Fish bundle, node via nvm.fish)"
  fish -c 'fisher update' || warn "fisher update failed"
  fish -c 'omf install' || warn "omf install failed"
  fish -c 'nvm install latest' || warn "nvm install failed"

  local fish_path
  fish_path="$(command -v fish)"
  local login_shell
  login_shell="$(getent passwd "$USER" 2>/dev/null | cut -d: -f7 || true)"
  if [ "${login_shell:-$SHELL}" != "$fish_path" ]; then
    log "Making fish the login shell"
    grep -qx "$fish_path" /etc/shells || echo "$fish_path" | sudo tee -a /etc/shells >/dev/null
    chsh -s "$fish_path" || warn "chsh failed, run: chsh -s $fish_path"
  fi
}

setup_nvim() {
  log "Installing Neovim plugins (LazyVim)"
  PATH="$HOME/.cargo/bin:$PATH" nvim --headless "+Lazy! sync" +qa || warn "Lazy sync reported errors, open nvim and run :Lazy"
}

main() {
  case "$OS_ID" in
    ubuntu) install_packages_ubuntu ;;
    *)      ensure_brew; brew_install "${BREW_PACKAGES[@]}" ;;
  esac
  install_rust
  install_hishtory
  install_omf
  install_chezmoi_and_dotfiles
  setup_fish
  setup_nvim
  log "Done. Open a new terminal to start fish and Zellij."
}

main "$@"
