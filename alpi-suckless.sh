#!/usr/bin/env bash
# =============================================================================
#  alpi-suckless.sh — Arch Linux Post Install (NIRUCON Suckless Edition)
#  Author: Nicklas Rudolfsson (nirucon)
#
#  Single-file, single-user script. No prompts, no choices — this is MY setup.
#
#  Phases (run in order):
#    core        — upgrade system, btrfs/snapper, base packages, services
#    suckless    — clone/build dwm, st, dmenu, slock, slstatus
#    lookandfeel — clone dotfiles/configs/scripts from lookandfeel repo
#    apps        — pacman + AUR packages
#    optimize    — zram, sysctl, journald, pacman, makepkg tuning
#
#  Usage:
#    ./alpi-suckless.sh                          # full install
#    ./alpi-suckless.sh --only suckless          # rebuild suckless only
#    ./alpi-suckless.sh --only lookandfeel       # refresh dotfiles only
#    ./alpi-suckless.sh --skip optimize          # skip system tuning
#    ./alpi-suckless.sh --dry-run                # preview without changes
#    ./alpi-suckless.sh --verify                 # check installation
# =============================================================================

set -Eeuo pipefail
IFS=$'\n\t'

# ─────────────────────────────────────────────────────────────────────────────
# CONFIG — edit these to change repos or paths
# ─────────────────────────────────────────────────────────────────────────────

readonly SUCKLESS_REPO="https://github.com/nirucon/suckless"
readonly LOOKANDFEEL_REPO="https://github.com/nirucon/suckless_lookandfeel"
readonly LOOKANDFEEL_BRANCH="main"

readonly SUCKLESS_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/suckless"
readonly LOOKANDFEEL_DIR="$HOME/.cache/alpi/lookandfeel"
readonly LOCAL_BIN="$HOME/.local/bin"
readonly XINITRC_HOOKS="$HOME/.config/xinitrc.d"
readonly SUCKLESS_PREFIX="/usr/local"

readonly SUCKLESS_COMPONENTS=(dwm st dmenu slock slstatus)

# ─────────────────────────────────────────────────────────────────────────────
# PACKAGES — edit to add/remove packages
# ─────────────────────────────────────────────────────────────────────────────

PACMAN_CORE=(
    # Base
    base base-devel git make gcc pkgconf curl wget unzip zip tar rsync
    grep sed findutils coreutils which diffutils gawk
    htop less nano tree imlib2 bash-completion

    # Network
    networkmanager openssh inetutils bind-tools iproute2
    wireless_tools iw tailscale

    # Keyboard (correct package name — setxkbmap is wrong)
    xorg-setxkbmap

    # Audio (PipeWire)
    pipewire pipewire-alsa pipewire-pulse pipewire-jack wireplumber pavucontrol

    # Xorg
    xorg-server xorg-xinit xorg-xsetroot xorg-xrandr xorg-xset xorg-xinput

    # Fonts (minimal)
    ttf-dejavu noto-fonts ttf-nerd-fonts-symbols-mono

    # Security
    ufw

    # Btrfs
    btrfs-progs
)

PACMAN_APPS=(
    # Desktop utilities
    feh arandr pcmanfm gvfs gvfs-mtp gvfs-gphoto2 gvfs-afc udisks2 udiskie

    # Compositor & WM extras
    picom

    # Launcher
    rofi

    # Screenshots
    flameshot maim slop

    # Terminal
    alacritty

    # Notifications
    dunst libnotify

    # Theming
    lxappearance materia-gtk-theme papirus-icon-theme
    qt5ct kvantum-qt5 qt5-base qt6ct qt6-base

    # Fonts
    noto-fonts-emoji

    # Media
    mpv cmus cava gimp sxiv imagemagick resvg playerctl

    # Files & archives
    7zip poppler yazi filezilla

    # Monitoring
    btop fastfetch

    # Bluetooth
    blueman

    # Clipboard & utilities
    xclip brightnessctl bc

    # Cloud
    nextcloud-client

    # Dev tools
    neovim lazygit ripgrep fd fzf jq zoxide

    # Neovim deps
    python-pynvim nodejs npm

    # GTK
    gtk3 gtk4
)

AUR_APPS=(
    ttf-jetbrains-mono-nerd   # programming font with icons
    brave-bin                  # privacy browser
    spotify                    # music streaming
    xautolock                  # auto screen lock on idle
    localsend-bin              # local file sharing
    reversal-icon-theme-git    # icon theme
    fresh-editor-bin           # text editor (binary — avoids Rust build issues of fresh-editor)
)

# ─────────────────────────────────────────────────────────────────────────────
# LOGGING
# ─────────────────────────────────────────────────────────────────────────────

NC="\033[0m"
GRN="\033[1;32m"
RED="\033[1;31m"
YLW="\033[1;33m"
BLU="\033[1;34m"
CYN="\033[1;36m"
MAG="\033[1;35m"

say()  { printf "${BLU}[ALPI]${NC} %s\n" "$*"; }
step() { printf "${MAG}[====]${NC} %s\n" "$*"; }
ok()   { printf "${GRN}[ OK ]${NC} %s\n" "$*"; }
warn() { printf "${YLW}[WARN]${NC} %s\n" "$*"; }
fail() { printf "${RED}[FAIL]${NC} %s\n" "$*" >&2; }
info() { printf "${CYN}[INFO]${NC} %s\n" "$*"; }
die()  { fail "$@"; exit 1; }

trap 'fail "Aborted at line $LINENO — command: ${BASH_COMMAND:-?}"' ERR

# ─────────────────────────────────────────────────────────────────────────────
# FLAGS
# ─────────────────────────────────────────────────────────────────────────────

DRY_RUN=0
JOBS="$(nproc 2>/dev/null || echo 2)"
ONLY_STEPS=()
SKIP_STEPS=()
DO_VERIFY=0

usage() {
    cat <<'EOF'
alpi-suckless.sh — NIRUCON Suckless Edition

USAGE:
  ./alpi-suckless.sh [flags]

FLAGS:
  --only <list>   Run only these phases (comma-separated)
  --skip <list>   Skip these phases (comma-separated)
  --jobs N        Parallel make jobs (default: nproc)
  --dry-run       Print actions, make no changes
  --verify        Check installation status and exit
  -h|--help       Show this help

PHASES:
  core, suckless, lookandfeel, apps, optimize

EXAMPLES:
  ./alpi-suckless.sh                           # Full install
  ./alpi-suckless.sh --only suckless           # Rebuild dwm/st/etc
  ./alpi-suckless.sh --only lookandfeel        # Refresh dotfiles & scripts
  ./alpi-suckless.sh --skip optimize           # Skip system tuning
  ./alpi-suckless.sh --verify                  # Verify installation
  ./alpi-suckless.sh --dry-run                 # Preview everything
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --only)   shift; IFS=',' read -r -a ONLY_STEPS <<< "$1"; shift ;;
        --skip)   shift; IFS=',' read -r -a SKIP_STEPS <<< "$1"; shift ;;
        --jobs)   shift; JOBS="$1"; shift ;;
        --dry-run) DRY_RUN=1; shift ;;
        --verify)  DO_VERIFY=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "Unknown flag: $1 (see --help)" ;;
    esac
done

# ─────────────────────────────────────────────────────────────────────────────
# HELPERS
# ─────────────────────────────────────────────────────────────────────────────

# Safety: must not run as root
[[ ${EUID:-$(id -u)} -ne 0 ]] || die "Do not run as root. Run as your normal user."

run() {
    if [[ $DRY_RUN -eq 1 ]]; then
        say "[dry-run] $*"
    else
        "$@"
    fi
}

# run_sh: for commands that need shell evaluation (pipes, expansions)
run_sh() {
    if [[ $DRY_RUN -eq 1 ]]; then
        say "[dry-run] $*"
    else
        bash -c "$*"
    fi
}

should_run() {
    local phase="$1"
    if (( ${#ONLY_STEPS[@]} > 0 )); then
        for s in "${ONLY_STEPS[@]}"; do [[ "$s" == "$phase" ]] && return 0; done
        return 1
    fi
    for s in "${SKIP_STEPS[@]}"; do [[ "$s" == "$phase" ]] && return 1; done
    return 0
}

ensure_dir() { mkdir -p "$@"; }

# Clone fresh or pull latest
git_sync() {
    local url="$1" dir="$2" branch="${3:-}"
    if [[ -d "$dir/.git" ]]; then
        say "Updating $(basename "$dir")..."
        run git -C "$dir" fetch --all --prune
        if [[ -n "$branch" ]]; then
            run git -C "$dir" checkout "$branch" 2>/dev/null || true
        fi
        run git -C "$dir" pull --ff-only || warn "git pull failed — keeping existing tree"
    else
        ensure_dir "$(dirname "$dir")"
        say "Cloning $(basename "$dir")..."
        if [[ -n "$branch" ]]; then
            run git clone --branch "$branch" "$url" "$dir"
        else
            run git clone "$url" "$dir"
        fi
    fi
}

# Install yay if missing
ensure_yay() {
    if ! command -v yay >/dev/null 2>&1; then
        step "Installing yay (AUR helper)"
        local tmp
        tmp="$(mktemp -d)"
        run git clone https://aur.archlinux.org/yay-bin.git "$tmp/yay-bin"
        (cd "$tmp/yay-bin" && run makepkg -si --noconfirm)
        rm -rf "$tmp"
        ok "yay installed"
    else
        info "yay already installed"
    fi
}

# Install file with mode, creating parent dirs
install_file() {
    local src="$1" dst="$2" mode="${3:-644}"
    if [[ ! -f "$src" ]]; then
        warn "Source not found: $src — skipping"
        return 0
    fi
    run install -Dm"$mode" "$src" "$dst"
}

# Copy dir contents recursively (cp -rT equivalent but safer)
copy_dir() {
    local src="$1" dst="$2"
    [[ -d "$src" ]] || { warn "Source dir not found: $src — skipping"; return 0; }
    ensure_dir "$dst"
    run cp -rf "$src/." "$dst/"
}

# ─────────────────────────────────────────────────────────────────────────────
# VERIFY
# ─────────────────────────────────────────────────────────────────────────────

phase_verify() {
    local failures=0 warnings=0

    chk_cmd() {
        local cmd="$1" label="${2:-$1}"
        if command -v "$cmd" >/dev/null 2>&1; then
            ok "$label: $(command -v "$cmd")"
        else
            fail "$label: NOT FOUND"; ((failures++)) || true
        fi
    }
    chk_file() {
        local f="$1" label="${2:-$1}"
        if [[ -f "$f" ]]; then ok "$label"; else fail "$label: NOT FOUND"; ((failures++)) || true; fi
    }
    chk_dir() {
        local d="$1" label="${2:-$1}"
        if [[ -d "$d" ]]; then ok "$label"; else fail "$label: NOT FOUND"; ((failures++)) || true; fi
    }
    chk_svc() {
        local svc="$1"
        if systemctl is-enabled --quiet "$svc" 2>/dev/null; then
            ok "Service $svc: enabled"
        else
            warn "Service $svc: not enabled"; ((warnings++)) || true
        fi
    }
    chk_font() {
        local name="$1"
        if fc-list | grep -qi "$name"; then ok "Font: $name"
        else warn "Font not found: $name"; ((warnings++)) || true; fi
    }

    echo "════════════════════════════════════════"
    echo "  ALPI-SUCKLESS — Installation Verify"
    echo "════════════════════════════════════════"

    echo; info "Suckless tools"
    for cmd in dwm st dmenu slock slstatus; do chk_cmd "$cmd"; done

    echo; info "Essential tools"
    for cmd in git make gcc picom rofi feh alacritty nvim; do chk_cmd "$cmd"; done
    chk_cmd tailscale "Tailscale"

    echo; info "Configuration"
    chk_file "$HOME/.xinitrc" "~/.xinitrc"
    chk_dir  "$XINITRC_HOOKS" "~/.config/xinitrc.d/"
    chk_file "$XINITRC_HOOKS/20-lookandfeel.sh" "hook: 20-lookandfeel.sh"
    chk_file "$XINITRC_HOOKS/30-statusbar.sh"   "hook: 30-statusbar.sh"
    chk_file "$XINITRC_HOOKS/40-suckless.sh"    "hook: 40-suckless.sh"

    echo; info "Suckless sources"
    for c in dwm st dmenu; do chk_dir "$SUCKLESS_DIR/$c" "source: $c"; done

    echo; info "Scripts"
    chk_file "$LOCAL_BIN/dwm-status.sh"       "dwm-status.sh"
    chk_file "$LOCAL_BIN/wallrotate.sh"        "wallrotate.sh"
    chk_file "$LOCAL_BIN/screenshot-select.sh" "screenshot-select.sh"

    echo; info "Services"
    chk_svc NetworkManager
    chk_svc tailscaled
    chk_svc "systemd-zram-setup@zram0"
    chk_svc paccache.timer
    chk_svc fstrim.timer

    echo; info "Fonts"
    chk_font "JetBrainsMono Nerd"
    chk_font "Symbols Nerd Font"

    echo
    echo "════════════════════════════════════════"
    if (( failures == 0 && warnings == 0 )); then
        ok "All checks passed — run: startx"
    elif (( failures == 0 )); then
        warn "Passed with $warnings warning(s) — should work fine"
    else
        fail "FAILED: $failures error(s), $warnings warning(s)"
        return 1
    fi
    echo "════════════════════════════════════════"
}

[[ $DO_VERIFY -eq 1 ]] && { phase_verify; exit $?; }

# ─────────────────────────────────────────────────────────────────────────────
# PHASE: CORE
# ─────────────────────────────────────────────────────────────────────────────

phase_core() {
    step "PHASE: core — system base"

    # Full system upgrade
    say "Syncing & upgrading system..."
    run sudo pacman -Syu --noconfirm

    # Core packages
    say "Installing core packages..."
    run sudo pacman -S --needed --noconfirm "${PACMAN_CORE[@]}"

    # Snapper / Btrfs snapshots
    local fstype
    fstype="$(findmnt -n -o FSTYPE / 2>/dev/null || echo unknown)"
    if [[ "$fstype" == "btrfs" ]]; then
        say "Btrfs detected — setting up Snapper..."
        run sudo pacman -S --needed --noconfirm snapper snap-pac

        if command -v grub-mkconfig >/dev/null 2>&1; then
            run sudo pacman -S --needed --noconfirm grub-btrfs
        fi

        if [[ ! -d "/.snapshots" ]]; then
            run sudo snapper -c root create-config /
            # Conservative retention: 3 daily, 1 weekly
            for pair in \
                "TIMELINE_LIMIT_HOURLY=0" \
                "TIMELINE_LIMIT_DAILY=3" \
                "TIMELINE_LIMIT_WEEKLY=1" \
                "TIMELINE_LIMIT_MONTHLY=0" \
                "TIMELINE_LIMIT_YEARLY=0"
            do
                local key="${pair%%=*}" val="${pair##*=}"
                run sudo sed -i "s/^${key}=.*/${key}=\"${val}\"/" \
                    /etc/snapper/configs/root 2>/dev/null || true
            done
        else
            info "Snapper root config already exists"
        fi

        if command -v grub-mkconfig >/dev/null 2>&1; then
            run sudo systemctl enable --now grub-btrfsd.service 2>/dev/null || true
            run sudo grub-mkconfig -o /boot/grub/grub.cfg 2>/dev/null || \
                warn "grub-mkconfig failed (non-fatal)"
        fi
        ok "Snapper configured (3 daily, 1 weekly snapshots)"
    else
        warn "Root is not Btrfs ($fstype) — skipping Snapper"
    fi

    # Services
    say "Enabling services..."
    run sudo systemctl enable --now NetworkManager
    run sudo systemctl enable --now tailscaled || warn "tailscaled enable failed"
    run sudo systemctl enable --now ufw || true

    # UFW defaults
    if command -v ufw >/dev/null 2>&1; then
        run sudo ufw default deny incoming  || true
        run sudo ufw default allow outgoing || true
        run sudo ufw enable || true
    fi

    ok "Phase core done"
}

# ─────────────────────────────────────────────────────────────────────────────
# PHASE: SUCKLESS
# ─────────────────────────────────────────────────────────────────────────────

phase_suckless() {
    step "PHASE: suckless — build & install"

    # Build dependencies
    local build_deps=(
        base-devel libx11 libxft libxinerama libxrandr libxext
        libxrender libxfixes freetype2 fontconfig xorg-xsetroot xorg-xinit
    )
    run sudo pacman -S --needed --noconfirm "${build_deps[@]}"

    # Clone/update mono-repo
    git_sync "$SUCKLESS_REPO" "$SUCKLESS_DIR"

    # Build & install each component
    for comp in "${SUCKLESS_COMPONENTS[@]}"; do
        if [[ -d "$SUCKLESS_DIR/$comp" ]]; then
            say "Building $comp..."
            if [[ $DRY_RUN -eq 0 ]]; then
                (
                    cd "$SUCKLESS_DIR/$comp"
                    make clean
                    make -j"$JOBS"
                    sudo make PREFIX="$SUCKLESS_PREFIX" install
                )
            else
                say "[dry-run] Would build $comp in $SUCKLESS_DIR/$comp"
            fi
            ok "$comp installed"
        else
            warn "$comp not found in $SUCKLESS_DIR — skipping"
        fi
    done

    # Create dirs
    ensure_dir "$XINITRC_HOOKS"

    # Write .xinitrc ONLY if it doesn't exist yet
    # (the real one is deployed by phase_lookandfeel from the repo)
    if [[ ! -f "$HOME/.xinitrc" ]]; then
        warn "~/.xinitrc not found — writing minimal bootstrap"
        warn "Run phase_lookandfeel to deploy the real one from your repo"
        cat > "$HOME/.xinitrc" <<'XINITEOF'
#!/bin/sh
# Minimal bootstrap — replace by running: ./alpi-suckless.sh --only lookandfeel
cd "$HOME"
if [ -z "${DBUS_SESSION_BUS_ADDRESS-}" ] && command -v dbus-run-session >/dev/null 2>&1; then
  exec dbus-run-session "$0" "$@"
fi
[ -r "$HOME/.Xresources" ] && xrdb -merge "$HOME/.Xresources"
command -v setxkbmap >/dev/null 2>&1 && setxkbmap se
command -v xsetroot  >/dev/null 2>&1 && xsetroot -solid "#111111"
if [ -d "$HOME/.config/xinitrc.d" ]; then
  for hook in "$HOME/.config/xinitrc.d"/*.sh; do
    [ -x "$hook" ] && . "$hook"
  done
fi
trap 'kill -- -$$' EXIT
while true; do /usr/local/bin/dwm 2>/tmp/dwm.log; done
XINITEOF
        chmod 644 "$HOME/.xinitrc"
    else
        info "~/.xinitrc exists — not touched"
    fi

    # xinitrc hook: screen locker
    say "Writing xinitrc hook 40-suckless.sh..."
    run install -Dm755 /dev/stdin "$XINITRC_HOOKS/40-suckless.sh" <<'HOOK'
#!/bin/sh
# Suckless hook — xautolock screen locker
if command -v xautolock >/dev/null 2>&1 && command -v slock >/dev/null 2>&1; then
    xautolock -time 10 -locker slock &
fi
HOOK

    ok "Phase suckless done"
}

# ─────────────────────────────────────────────────────────────────────────────
# PHASE: LOOKANDFEEL
# ─────────────────────────────────────────────────────────────────────────────

phase_lookandfeel() {
    step "PHASE: lookandfeel — dotfiles, configs, scripts"

    ensure_dir "$LOOKANDFEEL_DIR"
    ensure_dir "$LOCAL_BIN"
    ensure_dir "$XINITRC_HOOKS"

    # Clone/update lookandfeel repo
    git_sync "$LOOKANDFEEL_REPO" "$LOOKANDFEEL_DIR" "$LOOKANDFEEL_BRANCH"

    local lf="$LOOKANDFEEL_DIR"

    # ── dotfiles → $HOME ──────────────────────────────────────────────────────
    say "Deploying dotfiles..."
    for f in .xinitrc .bashrc .bash_aliases .inputrc .Xresources; do
        if [[ -f "$lf/dotfiles/$f" ]]; then
            # Backup existing if it differs
            if [[ -f "$HOME/$f" ]] && ! diff -q "$HOME/$f" "$lf/dotfiles/$f" >/dev/null 2>&1; then
                run cp "$HOME/$f" "$HOME/${f}.bak.$(date +%Y%m%d)"
                say "Backed up ~/$f"
            fi
            run install -Dm644 "$lf/dotfiles/$f" "$HOME/$f"
            ok "~/$f"
        else
            warn "dotfiles/$f not found in repo — skipping"
        fi
    done

    # ── config → ~/.config ────────────────────────────────────────────────────
    say "Deploying config files..."
    for d in alacritty cmus dunst gtk-3.0 picom rofi; do
        if [[ -d "$lf/config/$d" ]]; then
            ensure_dir "$HOME/.config/$d"
            copy_dir "$lf/config/$d" "$HOME/.config/$d"
            ok "~/.config/$d/"
        else
            warn "config/$d not found in repo — skipping"
        fi
    done

    # ── local/bin → ~/.local/bin ──────────────────────────────────────────────
    say "Deploying scripts to ~/.local/bin..."
    if [[ -d "$lf/local/bin" ]]; then
        for script in "$lf/local/bin/"*.sh; do
            [[ -f "$script" ]] || continue
            run install -Dm755 "$script" "$LOCAL_BIN/$(basename "$script")"
            ok "~/.local/bin/$(basename "$script")"
        done
    else
        warn "local/bin not found in repo — skipping scripts"
    fi

    # ── local/share → ~/.local/share ──────────────────────────────────────────
    if [[ -d "$lf/local/share" ]]; then
        say "Deploying local/share..."
        copy_dir "$lf/local/share" "$HOME/.local/share"
        ok "~/.local/share/ (rofi themes etc)"
    fi

    # ── Ensure ~/.local/bin is on PATH ────────────────────────────────────────
    local profile="$HOME/.bash_profile"
    [[ -f "$profile" ]] || touch "$profile"
    grep -qxF 'export PATH="$HOME/.local/bin:$PATH"' "$profile" || \
        run_sh "echo 'export PATH=\"\$HOME/.local/bin:\$PATH\"' >> \"$profile\""
    grep -qxF 'export EDITOR=nvim' "$profile" || \
        run_sh "echo 'export EDITOR=nvim' >> \"$profile\""
    grep -qxF 'export VISUAL=nvim' "$profile" || \
        run_sh "echo 'export VISUAL=nvim' >> \"$profile\""

    # ── xinitrc hook: look & feel ─────────────────────────────────────────────
    say "Writing xinitrc hook 20-lookandfeel.sh..."
    run install -Dm755 /dev/stdin "$XINITRC_HOOKS/20-lookandfeel.sh" <<'HOOK'
#!/bin/sh
# Look & feel hook — compositor, wallpaper, notifications, Bluetooth tray

# Compositor
command -v picom >/dev/null 2>&1 && picom --config "$HOME/.config/picom/picom.conf" --daemon

# Wallpaper (random from ~/Wallpapers if wallrotate.sh exists, else static feh)
if [ -x "$HOME/.local/bin/wallrotate.sh" ]; then
    "$HOME/.local/bin/wallrotate.sh" &
elif command -v feh >/dev/null 2>&1 && [ -d "$HOME/Wallpapers" ]; then
    feh --randomize --bg-fill "$HOME/Wallpapers" &
fi

# Notification daemon
command -v dunst >/dev/null 2>&1 && dunst &

# Bluetooth tray applet
command -v blueman-applet >/dev/null 2>&1 && blueman-applet &

# Disk automounter
command -v udiskie >/dev/null 2>&1 && udiskie --tray &

# Nextcloud sync
command -v nextcloud >/dev/null 2>&1 && nextcloud --background &
HOOK

    # ── xinitrc hook: status bar ──────────────────────────────────────────────
    say "Writing xinitrc hook 30-statusbar.sh..."
    run install -Dm755 /dev/stdin "$XINITRC_HOOKS/30-statusbar.sh" <<'HOOK'
#!/bin/sh
# Status bar hook
[ -x "$HOME/.local/bin/dwm-status.sh" ] && "$HOME/.local/bin/dwm-status.sh" &
HOOK

    ok "Phase lookandfeel done"
}

# ─────────────────────────────────────────────────────────────────────────────
# PHASE: APPS
# ─────────────────────────────────────────────────────────────────────────────

phase_apps() {
    step "PHASE: apps — desktop & dev tools"

    # pacman apps
    say "Installing pacman packages (${#PACMAN_APPS[@]} total)..."
    run sudo pacman -S --needed --noconfirm "${PACMAN_APPS[@]}"

    # AUR via yay
    ensure_yay
    say "Installing AUR packages (${#AUR_APPS[@]} total)..."
    run yay -S --needed --noconfirm "${AUR_APPS[@]}"

    # LazyVim bootstrap
    local nvim_dir="$HOME/.config/nvim"
    if command -v nvim >/dev/null 2>&1 && [[ ! -d "$nvim_dir" ]]; then
        step "Bootstrapping LazyVim..."
        run git clone --depth=1 https://github.com/LazyVim/starter "$nvim_dir"
        (cd "$nvim_dir" && run rm -rf .git)
        run nvim --headless "+Lazy! sync" +qa || true
        ok "LazyVim installed"
    elif [[ -d "$nvim_dir" ]]; then
        info "Neovim config exists — leaving as-is"
    fi

    ok "Phase apps done"
}

# ─────────────────────────────────────────────────────────────────────────────
# PHASE: OPTIMIZE
# ─────────────────────────────────────────────────────────────────────────────

phase_optimize() {
    step "PHASE: optimize — system tuning"

    # This phase writes to system paths — all commands use sudo
    local cores
    cores="$(nproc)"

    # ── CPU Microcode ─────────────────────────────────────────────────────────
    local vendor
    vendor="$(lscpu | awk -F: '/Vendor ID/{gsub(/^[ \t]+/,"",$2); print $2}' || echo unknown)"
    case "$vendor" in
        *Intel*) run sudo pacman -S --needed --noconfirm intel-ucode ;;
        *AMD*)   run sudo pacman -S --needed --noconfirm amd-ucode ;;
        *)       warn "Unknown CPU vendor '$vendor' — skipping microcode" ;;
    esac
    run sudo pacman -S --needed --noconfirm linux-firmware

    # ── ZRAM ──────────────────────────────────────────────────────────────────
    run sudo pacman -S --needed --noconfirm zram-generator
    if [[ $DRY_RUN -eq 0 ]]; then
        sudo mkdir -p /etc/systemd/zram-generator.conf.d
        sudo tee /etc/systemd/zram-generator.conf.d/90-alpi.conf >/dev/null <<'EOF'
[zram0]
zram-size = ram / 2
compression-algorithm = zstd
swap-priority = 100
EOF
    else
        say "[dry-run] Would write /etc/systemd/zram-generator.conf.d/90-alpi.conf"
    fi
    run sudo systemctl enable --now systemd-zram-setup@zram0.service || true

    # ── Journald ──────────────────────────────────────────────────────────────
    if [[ $DRY_RUN -eq 0 ]]; then
        sudo mkdir -p /etc/systemd/journald.conf.d
        sudo tee /etc/systemd/journald.conf.d/90-alpi.conf >/dev/null <<'EOF'
[Journal]
Storage=persistent
SystemMaxUse=500M
RuntimeMaxUse=200M
MaxRetentionSec=1month
RateLimitIntervalSec=30s
RateLimitBurst=1000
EOF
        sudo systemctl restart systemd-journald
    else
        say "[dry-run] Would write /etc/systemd/journald.conf.d/90-alpi.conf"
    fi

    # ── sysctl ────────────────────────────────────────────────────────────────
    local qdisc="fq"
    tc qdisc show 2>/dev/null | grep -q cake && qdisc="cake" || true

    if [[ $DRY_RUN -eq 0 ]]; then
        sudo tee /etc/sysctl.d/90-alpi.conf >/dev/null <<EOF
# ALPI — conservative tunables
vm.swappiness = 60
vm.vfs_cache_pressure = 50
fs.inotify.max_user_watches = 1048576
fs.inotify.max_user_instances = 1024
net.core.default_qdisc = ${qdisc}
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_fastopen = 3
EOF
        sudo sysctl --system >/dev/null
    else
        say "[dry-run] Would write /etc/sysctl.d/90-alpi.conf"
    fi

    # ── pacman.conf ────────────────────────────────────────────────────────────
    if [[ $DRY_RUN -eq 0 ]]; then
        sudo sed -E -i 's/^#?Color$/Color/'           /etc/pacman.conf
        sudo sed -E -i 's/^#?VerbosePkgLists$/VerbosePkgLists/' /etc/pacman.conf
        sudo sed -E -i 's/^#?ParallelDownloads *= *.*/ParallelDownloads = 10/' \
            /etc/pacman.conf || \
            run_sh "echo 'ParallelDownloads = 10' | sudo tee -a /etc/pacman.conf"
    else
        say "[dry-run] Would enable Color, VerbosePkgLists, ParallelDownloads=10 in pacman.conf"
    fi

    # ── makepkg ───────────────────────────────────────────────────────────────
    if [[ $DRY_RUN -eq 0 ]]; then
        sudo sed -E -i "s|^#?MAKEFLAGS=.*|MAKEFLAGS=\"-j${cores}\"|" /etc/makepkg.conf
        sudo sed -E -i 's|^#?COMPRESSXZ=.*|COMPRESSXZ=(xz -c -T0 -z -)|'   /etc/makepkg.conf
        sudo sed -E -i 's|^#?COMPRESSZST=.*|COMPRESSZST=(zstd -c -T0 -z -q -19 -)|' /etc/makepkg.conf
    else
        say "[dry-run] Would tune makepkg.conf (MAKEFLAGS=-j${cores}, parallel compressors)"
    fi

    # ── Maintenance timers ─────────────────────────────────────────────────────
    run sudo pacman -S --needed --noconfirm pacman-contrib util-linux
    run sudo systemctl enable --now paccache.timer
    run sudo systemctl enable --now fstrim.timer

    # ── systemd-oomd ──────────────────────────────────────────────────────────
    if [[ $DRY_RUN -eq 0 ]]; then
        sudo mkdir -p /etc/systemd/oomd.conf.d
        sudo tee /etc/systemd/oomd.conf.d/90-alpi.conf >/dev/null <<'EOF'
[OOM]
DefaultMemoryPressureDurationSec=2min
DefaultMemoryPressureThreshold=70%
EOF
    fi
    run sudo systemctl enable --now systemd-oomd.service || true

    ok "Phase optimize done — reboot recommended"
}

# ─────────────────────────────────────────────────────────────────────────────
# MAIN — orchestrate phases in correct order
# ─────────────────────────────────────────────────────────────────────────────

main() {
    echo
    say "════════════════════════════════════════"
    say "  ALPI-SUCKLESS — NIRUCON Edition"
    say "  User:    $USER"
    say "  Jobs:    $JOBS"
    say "  Dry-run: $DRY_RUN"
    (( ${#ONLY_STEPS[@]} > 0 )) && say "  Only:    ${ONLY_STEPS[*]}"
    (( ${#SKIP_STEPS[@]}  > 0 )) && say "  Skip:    ${SKIP_STEPS[*]}"
    say "════════════════════════════════════════"
    echo

    should_run core        && phase_core
    should_run suckless    && phase_suckless
    should_run lookandfeel && phase_lookandfeel
    should_run apps        && phase_apps
    should_run optimize    && phase_optimize

    echo
    say "════════════════════════════════════════"
    ok  "All selected phases completed!"
    say "  → Reboot to apply all changes"
    say "  → Start X with: startx"
    say "  → Verify with:  ./alpi-suckless.sh --verify"
    say "════════════════════════════════════════"
}

main