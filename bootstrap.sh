#!/usr/bin/env bash
# Set up a new machine: install the tools the dotfiles use, then pull the
# dotfiles with chezmoi. Safe to re-run; anything already installed is skipped.
#
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/kimusan/bootstrap/main/bootstrap.sh)"
#
# On networks that block raw.githubusercontent.com, clone and run it instead:
#   git clone --depth 1 https://github.com/kimusan/bootstrap /tmp/bootstrap \
#     && bash /tmp/bootstrap/bootstrap.sh
#
# Use the bash -c form, not `curl | bash`: chezmoi asks for the age passphrase
# and chsh asks for your password, and both need the terminal on stdin.
#
# Installer output goes to a log file (path printed at start and end).
# VERBOSE=1 shows it on screen as well.
set -euo pipefail

DOTFILES_REPO="${DOTFILES_REPO:-git@github.com:kimusan/dotfiles.git}"
VERBOSE="${VERBOSE:-0}"
LOG_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/bootstrap"
LOG="$LOG_DIR/bootstrap-$(date +%Y%m%d-%H%M%S).log"

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
BREW_ON_UBUNTU=(gh zellij lazygit)

# Any other OS: everything from Homebrew.
BREW_PACKAGES=(
  fish git gh curl wget neovim
  fzf ripgrep fd bat eza jq lf tig tree cowsay
  autojump grc age poetry
  tmux zellij lazygit
  # lf previews (no kitten here: on macOS install the kitty app for image previews)
  poppler p7zip exiftool
)

# ---------------------------------------------------------------- output

if [ -t 1 ]; then
  C_BOLD=$'\033[1m' C_DIM=$'\033[2m' C_BLUE=$'\033[1;34m' C_GREEN=$'\033[32m'
  C_YELLOW=$'\033[33m' C_RED=$'\033[31m' C_OFF=$'\033[0m' CLR=$'\r\033[K' TTY=1
else
  C_BOLD='' C_DIM='' C_BLUE='' C_GREEN='' C_YELLOW='' C_RED='' C_OFF='' CLR='' TTY=0
fi

SECTION=0
SECTIONS=7
WARNINGS=()

section() {
  SECTION=$((SECTION + 1))
  printf '\n%s[%d/%d] %s%s\n' "$C_BLUE" "$SECTION" "$SECTIONS" "$*" "$C_OFF"
  printf '\n===== [%d/%d] %s =====\n' "$SECTION" "$SECTIONS" "$*" >>"$LOG"
}
ok()      { printf '%s  %s✓%s %s %s\n' "$CLR" "$C_GREEN" "$C_OFF" "$1" "${2:+$C_DIM$2$C_OFF}"; }
skip()    { ok "$1" "(already done)"; }
note()    { printf '  %s%s%s\n' "$C_DIM" "$*" "$C_OFF"; }
warn()    { printf '%s  %s!%s %s\n' "$CLR" "$C_YELLOW" "$C_OFF" "$*"; WARNINGS+=("$*"); }
die()     { printf '\n%s✗ %s%s\n' "$C_RED" "$*" "$C_OFF" >&2; exit 1; }
have()    { command -v "$1" >/dev/null 2>&1; }

# _run DESC CMD...: runs CMD with output in the log and a spinner on screen.
_run() {
  local desc=$1; shift
  STEP_LOG_LINE=$(($(wc -l <"$LOG") + 2))
  printf '\n--- %s\n$ %s\n' "$desc" "$*" >>"$LOG"
  local start=$SECONDS rc=0
  if [ "$VERBOSE" = 1 ]; then
    printf '  %s›%s %s\n' "$C_BLUE" "$C_OFF" "$desc"
    { "$@" 2>&1 </dev/null | tee -a "$LOG"; } || rc=$?
  else
    "$@" >>"$LOG" 2>&1 </dev/null &
    local pid=$! i=0 frames=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)
    if [ "$TTY" = 1 ]; then
      while kill -0 "$pid" 2>/dev/null; do
        printf '%s  %s%s%s %s %s(%ds)%s' "$CLR" "$C_BLUE" "${frames[i++ % 10]}" "$C_OFF" \
          "$desc" "$C_DIM" $((SECONDS - start)) "$C_OFF"
        sleep 0.1
      done
    fi
    wait "$pid" || rc=$?
  fi
  [ "$rc" -eq 0 ] && ok "$desc" "($((SECONDS - start))s)"
  return "$rc"
}

_show_failure() {
  printf '%s  %s✗%s %s\n' "$CLR" "$C_RED" "$C_OFF" "$1"
  if [ "$VERBOSE" != 1 ]; then
    note "its output (last 15 lines):"
    tail -n "+$STEP_LOG_LINE" "$LOG" | tail -n 15 | sed 's/^/      /'
  fi
}

# step: must succeed, stops the script otherwise.
step() {
  local desc=$1
  _run "$@" && return 0
  _show_failure "$desc"
  die "$desc failed. Full log: $LOG"
}

# try: may fail; the run goes on and the failure is listed at the end.
try() {
  local desc=$1
  _run "$@" && return 0
  _show_failure "$desc"
  WARNINGS+=("$desc failed")
}

# interactive: needs the terminal (passwords, passphrases), so no spinner.
interactive() {
  local desc=$1; shift
  printf '\n--- %s (interactive, output not logged)\n$ %s\n' "$desc" "$*" >>"$LOG"
  printf '  %s›%s %s %s(needs your input)%s\n' "$C_BLUE" "$C_OFF" "$desc" "$C_DIM" "$C_OFF"
  "$@"
}

# ask_yes PROMPT: y/n question on the terminal. Anything not starting with
# y/Y (including a bare Enter or a failed read) means no.
ask_yes() {
  local answer
  printf '  %s %s[y/N]%s ' "$*" "$C_DIM" "$C_OFF"
  read -r answer
  [[ "$answer" == [Yy]* ]]
}

# ---------------------------------------------------------------- fetch

# fetch_raw URL DEST: like `curl -fsSL URL -o DEST` for a
# raw.githubusercontent.com file, but if that is blocked, fall back to a
# shallow clone (last commit only) of the repo behind the URL, copy the file
# out of it, and delete the clone again.
fetch_raw() {
  local url=$1 dest=$2
  # --connect-timeout: blocked networks often blackhole the connection, so
  # don't sit through curl's long default timeout before falling back.
  if curl -fsSL --connect-timeout 15 "$url" -o "$dest"; then
    return 0
  fi

  # https://raw.githubusercontent.com/OWNER/REPO/REF/PATH
  local owner repo ref path
  [[ "$url" =~ ^https://raw\.githubusercontent\.com/([^/]+)/([^/]+)/([^/]+)/(.+)$ ]] || return 1
  owner=${BASH_REMATCH[1]} repo=${BASH_REMATCH[2]} ref=${BASH_REMATCH[3]} path=${BASH_REMATCH[4]}

  note "raw.githubusercontent.com unreachable, cloning github.com/$owner/$repo instead"
  local clone rc=0
  clone="$(mktemp -d)" || return 1
  local -a clone_args=(--quiet --depth 1)
  if [ "$ref" != HEAD ]; then
    clone_args+=(--branch "$ref")
  fi
  git clone "${clone_args[@]}" "https://github.com/$owner/$repo.git" "$clone" &&
    cp "$clone/$path" "$dest" || rc=$?
  rm -rf "$clone"
  return "$rc"
}

# ---------------------------------------------------------------- setup

if [ "$(id -u)" -eq 0 ]; then
  echo "Run this as your normal user, not root. It uses sudo where needed." >&2
  exit 1
fi

mkdir -p "$LOG_DIR"
: >"$LOG"
trap 'kill $(jobs -p) 2>/dev/null || true' EXIT

OS_ID=unknown
[ -r /etc/os-release ] && OS_ID="$(. /etc/os-release && echo "${ID:-unknown}")"

# Ask for the sudo password once, then keep the ticket fresh so quiet steps
# never stop at a hidden prompt.
start_sudo() {
  printf '%sbootstrap%s on %s (%s)\n' "$C_BOLD" "$C_OFF" "$(hostname -s 2>/dev/null || hostname)" "$OS_ID"
  note "log: $LOG"
  sudo -v -p "  sudo password for %u: "
  while true; do sudo -n true; sleep 50; kill -0 "$$" || exit; done 2>/dev/null &
}

# ---------------------------------------------------------------- packages

brew_shellenv() {
  have brew && return 0
  local b
  for b in /home/linuxbrew/.linuxbrew/bin/brew /opt/homebrew/bin/brew /usr/local/bin/brew; do
    [ -x "$b" ] && eval "$("$b" shellenv)" && return 0
  done
  return 1
}

install_brew() {
  local tmp rc=0
  tmp="$(mktemp)"
  fetch_raw https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh "$tmp" &&
    NONINTERACTIVE=1 /bin/bash "$tmp" || rc=$?
  rm -f "$tmp"
  return "$rc"
}

ensure_brew() {
  if brew_shellenv; then
    skip "Homebrew"
  else
    step "Install Homebrew" install_brew
    brew_shellenv || die "Homebrew installed but brew not found"
  fi
}

brew_install() {
  local missing=() p
  for p in "$@"; do brew list --formula "$p" >/dev/null 2>&1 || missing+=("$p"); done
  if [ ${#missing[@]} -gt 0 ]; then
    step "brew install ${missing[*]}" brew install "${missing[@]}"
  else
    skip "Homebrew packages ($*)"
  fi
}

apt_get() { sudo DEBIAN_FRONTEND=noninteractive apt-get "$@"; }

add_neovim_ppa() {
  sudo add-apt-repository -y ppa:neovim-ppa/unstable
  apt_get update -qq
}

install_packages_ubuntu() {
  step "apt update" apt_get update -qq
  step "Install software-properties-common" apt_get install -y software-properties-common
  if grep -rqs "neovim-ppa/unstable" /etc/apt/sources.list.d/; then
    skip "Neovim PPA"
  else
    step "Add Neovim PPA" add_neovim_ppa
  fi
  step "apt install ${#APT_PACKAGES[@]} packages + neovim" apt_get install -y "${APT_PACKAGES[@]}" neovim
  ensure_brew
  brew_install "${BREW_ON_UBUNTU[@]}"
}

# ---------------------------------------------------------------- tools

rustup_install() {
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --no-modify-path
}

install_rust() {
  if [ -x "$HOME/.cargo/bin/rustup" ]; then
    step "Update Rust stable" "$HOME/.cargo/bin/rustup" update stable
  else
    step "Install Rust (avante.nvim builds with cargo)" rustup_install
  fi
}

hishtory_install() { curl -fsSL https://hishtory.dev/install.py | python3 -; }

install_hishtory() {
  if [ -x "$HOME/.hishtory/hishtory" ]; then
    skip "hishtory"
  else
    step "Install hishtory" hishtory_install
  fi
}

# Must run before chezmoi: the installer refuses to touch an existing
# ~/.local/share/omf, and chezmoi puts the elderitch theme there.
omf_install() {
  if [ -d "$HOME/.local/share/omf" ]; then
    mv "$HOME/.local/share/omf" "$HOME/.local/share/omf.pre-bootstrap"
  fi
  local tmp
  tmp="$(mktemp)"
  fetch_raw https://raw.githubusercontent.com/oh-my-fish/oh-my-fish/master/bin/install "$tmp" ||
    { rm -f "$tmp"; return 1; }
  fish "$tmp" --noninteractive --yes || { rm -f "$tmp"; return 1; }
  rm -f "$tmp"
  if [ -d "$HOME/.local/share/omf.pre-bootstrap" ]; then
    cp -rn "$HOME/.local/share/omf.pre-bootstrap/." "$HOME/.local/share/omf/"
    rm -rf "$HOME/.local/share/omf.pre-bootstrap"
  fi
}

install_omf() {
  if [ -d "$HOME/.local/share/omf/.git" ]; then
    skip "Oh My Fish"
  else
    step "Install Oh My Fish" omf_install
  fi
}

# ---------------------------------------------------------------- dotfiles

chezmoi_install() {
  local script
  script="$(curl -fsLS get.chezmoi.io)" || return
  sh -c "$script" -- -b "$HOME/.bin"
}

# Authenticate to GitHub with the gh CLI: no SSH key or PAT setup needed,
# the device flow just asks for a one-time code at github.com/login/device
# (shown in the terminal, can be entered from any device with a browser).
# gh auth setup-git then makes git use gh as its credential helper, so the
# private dotfiles repo clones over HTTPS without any further setup.
ensure_github_auth() {
  if gh auth status >/dev/null 2>&1; then
    skip "GitHub auth (gh)"
  else
    interactive "gh auth login (one-time code at github.com/login/device)" \
      gh auth login --hostname github.com --git-protocol https --web \
      || die "gh auth login failed"
  fi
  gh auth setup-git >/dev/null 2>&1 || true
}

# git@github.com:OWNER/REPO(.git) -> https://github.com/OWNER/REPO.git
github_https_url() {
  local url=$1 repo
  repo="${url#git@github.com:}"; repo="${repo%.git}"
  printf 'https://github.com/%s.git' "$repo"
}

# The dotfiles repo is private: git pulls it with gh's credentials, which
# only work over HTTPS. Switch an old SSH remote (from the SSH-key days)
# over; HTTPS remotes already work once gh auth setup-git has run.
fix_chezmoi_remote() {
  local dir=$HOME/.local/share/chezmoi url
  url="$(git -C "$dir" remote get-url origin 2>/dev/null || true)"
  case "$url" in
    git@github.com:*)
      git -C "$dir" remote set-url origin "$(github_https_url "$url")"
      ok "chezmoi source repo switched to HTTPS" "(gh supplies the credentials)"
      ;;
  esac
}

# A failed chezmoi update on a machine where chezmoi ran before usually means
# the source repo has conflicting local changes (autostash conflicts) or the
# machine still carries a config file and age key from an earlier setup that
# no longer match the repo's recipients ("config file template has changed",
# "no identity matched any of the recipients"). reset_chezmoi moves all of
# that into a timestamped backup, so a clean `chezmoi init --apply` can
# regenerate the config, key and working tree.
reset_chezmoi() {
  local backup="$HOME/.local/share/chezmoi.backup-$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$backup"
  mv "$HOME/.local/share/chezmoi" "$backup/source-repo"
  if [ -d "$HOME/.config/chezmoi" ]; then
    mv "$HOME/.config/chezmoi" "$backup/config"
  fi
  note "old chezmoi state backed up in $backup"
}

install_chezmoi_and_dotfiles() {
  mkdir -p "$HOME/.bin"
  export PATH="$HOME/.bin:$PATH"
  if have chezmoi; then
    skip "chezmoi"
  else
    step "Install chezmoi to ~/.bin" chezmoi_install
  fi

  ensure_github_auth

  if [ -d "$HOME/.local/share/chezmoi/.git" ]; then
    fix_chezmoi_remote
    if interactive "chezmoi update" chezmoi update; then
      ok "Dotfiles updated"
      return
    fi
    warn "chezmoi update failed (conflicting local changes, or an outdated config/age key)"
    ask_yes "Reset chezmoi and re-apply the dotfiles from scratch? The old source repo, config and age key are backed up first" \
      || die "chezmoi update failed. Full log: $LOG"
    reset_chezmoi
  fi

  local repo_url=$DOTFILES_REPO
  [[ "$repo_url" == git@github.com:* ]] && repo_url="$(github_https_url "$repo_url")"
  interactive "chezmoi init --apply (asks once for the age key passphrase)" \
    chezmoi init --apply "$repo_url" || die "chezmoi init failed"
  ok "Dotfiles applied"
}

# ---------------------------------------------------------------- fish

setup_fish() {
  try "fisher update (fzf.fish, fc-fish, nvm.fish)" fish -c 'fisher update'
  try "omf install (Oh My Fish bundle)" fish -c 'omf install'
  try "nvm install latest (node)" fish -c 'nvm install latest'

  # Older setups: tmux-zen started tmux on every shell, Zellij replaces it.
  if fish -c 'omf list' 2>/dev/null | grep -qw tmux-zen; then
    try "Remove tmux-zen (Zellij replaces it)" fish -c 'omf remove tmux-zen'
  fi
  # PATH lives in conf.d/paths.fish now; an old universal fish_user_paths
  # can hold another machine's home paths.
  if fish -c 'set -q fish_user_paths'; then
    try "Clear old fish_user_paths" fish -c 'set -Ue fish_user_paths'
  fi

  local fish_path login_shell
  fish_path="$(command -v fish)"
  login_shell="$(getent passwd "$USER" 2>/dev/null | cut -d: -f7 || true)"
  if [ "${login_shell:-$SHELL}" = "$fish_path" ]; then
    skip "fish is the login shell"
    return
  fi
  grep -qx "$fish_path" /etc/shells || echo "$fish_path" | sudo tee -a /etc/shells >/dev/null
  if interactive "Make fish the login shell (chsh asks for your password)" chsh -s "$fish_path"; then
    ok "Login shell is fish"
  else
    warn "chsh failed, run: chsh -s $fish_path"
  fi
}

# ---------------------------------------------------------------- nvim

setup_nvim() {
  try "LazyVim plugins (Lazy sync, builds avante.nvim)" \
    env PATH="$HOME/.cargo/bin:$PATH" nvim --headless "+Lazy! sync" +qa
}

# ---------------------------------------------------------------- main

main() {
  start_sudo
  local start=$SECONDS

  section "Packages"
  case "$OS_ID" in
    ubuntu) install_packages_ubuntu ;;
    *)      ensure_brew; brew_install "${BREW_PACKAGES[@]}" ;;
  esac
  section "Rust";        install_rust
  section "hishtory";    install_hishtory
  section "Oh My Fish";  install_omf
  section "Dotfiles";    install_chezmoi_and_dotfiles
  section "fish";        setup_fish
  section "Neovim";      setup_nvim

  local mins=$(((SECONDS - start) / 60)) secs=$(((SECONDS - start) % 60))
  printf '\n%sDone in %dm%02ds.%s Open a new terminal to start fish and Zellij.\n' \
    "$C_GREEN$C_BOLD" "$mins" "$secs" "$C_OFF"
  if [ ${#WARNINGS[@]} -gt 0 ]; then
    printf '\n%s%d warning(s):%s\n' "$C_YELLOW" "${#WARNINGS[@]}" "$C_OFF"
    printf '  - %s\n' "${WARNINGS[@]}"
  fi
  note "Zellij asks once for plugin permissions (zjstatus, zellij-attention): press y in each prompt."
  note "If Zellij was already running, restart it so the new config and plugins load."
  note "Full log: $LOG"
}

main "$@"
