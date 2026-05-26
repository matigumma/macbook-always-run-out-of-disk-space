#!/bin/bash
# ============================================================================
# diskclean.sh — Interactive Mac Disk Cleanup Tool
# ============================================================================
# Scans for reclaimable space, categorizes by risk, lets you choose what to
# delete with double confirmation for sensitive items.
# ============================================================================

set -euo pipefail

# ── Colors & Formatting ─────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

# ── Globals ──────────────────────────────────────────────────────────────────
declare -a ITEM_IDS=()
declare -a ITEM_NAMES=()
declare -a ITEM_SIZES=()
declare -a ITEM_SIZES_HR=()
declare -a ITEM_RISKS=()
declare -a ITEM_PATHS=()
declare -a ITEM_CMDS=()
declare -a ITEM_DESCRIPTIONS=()
declare -a ITEM_TRASHABLE=()   # "yes" if it's a path we can move to trash, "no" for tool commands
ITEM_COUNT=0

HOME_DIR="$HOME"
TOTAL_RECLAIMABLE=0
JSON_MODE=false

# ── Helpers ──────────────────────────────────────────────────────────────────

hr() {
    printf "${DIM}%.0s─${NC}" {1..70}
    echo
}

banner() {
    clear
    echo
    printf "${BOLD}${CYAN}"
    echo "  ╔══════════════════════════════════════════════════════════════╗"
    echo "  ║              🧹  Mac Disk Cleanup Tool                     ║"
    echo "  ╚══════════════════════════════════════════════════════════════╝"
    printf "${NC}\n"
}

# Get directory size in bytes (returns 0 if not found)
dir_size_bytes() {
    local path="$1"
    if [[ -d "$path" || -f "$path" ]]; then
        local raw
        raw=$(du -sk "$path" 2>/dev/null || true)
        echo "$raw" | awk '{total += $1} END {print (total+0) * 1024}'
    else
        echo 0
    fi
}

# Human readable size from bytes
human_size() {
    local bytes=$1
    if (( bytes >= 1073741824 )); then
        printf "%.1f GB" "$(echo "scale=1; $bytes / 1073741824" | bc)"
    elif (( bytes >= 1048576 )); then
        printf "%.0f MB" "$(echo "scale=0; $bytes / 1048576" | bc)"
    elif (( bytes >= 1024 )); then
        printf "%.0f KB" "$(echo "scale=0; $bytes / 1024" | bc)"
    else
        printf "%d B" "$bytes"
    fi
}

# Move a path to Trash (macOS) with timestamp to avoid collisions
move_to_trash() {
    local src="$1"
    local basename
    basename=$(basename "$src")
    local ts
    ts=$(date +%Y%m%d_%H%M%S)
    local dest="$HOME_DIR/.Trash/${basename}__${ts}"

    if [[ -e "$src" ]]; then
        mv "$src" "$dest" 2>/dev/null && return 0
        # If mv fails (cross-volume, permissions), try with sudo
        sudo mv "$src" "$dest" 2>/dev/null && return 0
    fi
    return 1
}

# Register a cleanup item
# trashable: "yes" = path can be moved to trash, "no" = uses a tool command
register_item() {
    local name="$1"
    local size_bytes="$2"
    local risk="$3"        # safe, moderate, risky
    local path="$4"
    local cmd="$5"
    local description="$6"
    local trashable="${7:-yes}"

    # Skip items under 10MB
    if (( size_bytes < 10485760 )); then
        return
    fi

    # Derive a stable ID slug, disambiguating collisions
    local slug
    slug=$(slugify "$name")
    if [[ -z "$slug" ]]; then
        slug="item-$((ITEM_COUNT + 1))"
    fi
    local final_slug="$slug"
    local n=2
    if (( ${#ITEM_IDS[@]} > 0 )); then
        while [[ " ${ITEM_IDS[*]} " == *" $final_slug "* ]]; do
            final_slug="${slug}-${n}"
            n=$((n + 1))
        done
    fi

    ITEM_IDS+=("$final_slug")
    ITEM_NAMES+=("$name")
    ITEM_SIZES+=("$size_bytes")
    ITEM_SIZES_HR+=("$(human_size "$size_bytes")")
    ITEM_RISKS+=("$risk")
    ITEM_PATHS+=("$path")
    ITEM_CMDS+=("$cmd")
    ITEM_DESCRIPTIONS+=("$description")
    ITEM_TRASHABLE+=("$trashable")
    ITEM_COUNT=${#ITEM_NAMES[@]}
    TOTAL_RECLAIMABLE=$((TOTAL_RECLAIMABLE + size_bytes))
}

# Prompt yes/no
ask_yn() {
    local prompt="$1"
    local answer
    printf "${BOLD}$prompt${NC} [y/N]: "
    read -r answer
    [[ "$answer" =~ ^[yYsS]$ ]]
}

# Double confirmation for risky items
ask_double_confirm() {
    local name="$1"
    local path="$2"
    echo
    printf "${RED}${BOLD}  ⚠️  ATENCIÓN: Estás a punto de eliminar:${NC}\n"
    printf "     ${BOLD}%s${NC}\n" "$name"
    printf "     ${DIM}%s${NC}\n" "$path"
    echo
    if ! ask_yn "  ¿Estás seguro? (1ra confirmación)"; then
        return 1
    fi
    printf "${RED}"
    if ! ask_yn "  ¿REALMENTE seguro? Esta acción NO se puede deshacer (2da confirmación)"; then
        return 1
    fi
    printf "${NC}"
    return 0
}

# ── Scanner Functions ────────────────────────────────────────────────────────

scan_spinner() {
    if [[ "$JSON_MODE" == "true" ]]; then return; fi
    local msg="$1"
    printf "\r  ${DIM}🔍 Escaneando: %-50s${NC}" "$msg"
}

# Convert a human-readable name to a stable slug for use as an ID
slugify() {
    local s="$1"
    s="${s//á/a}"; s="${s//é/e}"; s="${s//í/i}"; s="${s//ó/o}"; s="${s//ú/u}"
    s="${s//Á/A}"; s="${s//É/E}"; s="${s//Í/I}"; s="${s//Ó/O}"; s="${s//Ú/U}"
    s="${s//ñ/n}"; s="${s//Ñ/N}"
    s=$(printf '%s' "$s" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//')
    printf '%s' "$s"
}

# Escape a string for safe inclusion in a JSON value
json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/\\r}"
    s="${s//$'\t'/\\t}"
    printf '%s' "$s"
}

scan_system_caches() {
    scan_spinner "Caches del sistema..."
    local size

    # User caches
    size=$(dir_size_bytes "$HOME_DIR/Library/Caches")
    register_item \
        "Caches de usuario (~/Library/Caches)" \
        "$size" "safe" \
        "$HOME_DIR/Library/Caches" \
        "rm -rf \"$HOME_DIR/Library/Caches\"/*" \
        "Caches de aplicaciones. Se regeneran automáticamente."

    # System caches
    size=$(dir_size_bytes "/Library/Caches")
    register_item \
        "Caches del sistema (/Library/Caches)" \
        "$size" "moderate" \
        "/Library/Caches" \
        "sudo rm -rf /Library/Caches/*" \
        "Caches a nivel de sistema. Requiere sudo."
}

scan_logs() {
    scan_spinner "Logs del sistema..."
    local size

    size=$(dir_size_bytes "$HOME_DIR/Library/Logs")
    register_item \
        "Logs de usuario (~/Library/Logs)" \
        "$size" "safe" \
        "$HOME_DIR/Library/Logs" \
        "rm -rf \"$HOME_DIR/Library/Logs\"/*" \
        "Archivos de log de aplicaciones."

    size=$(dir_size_bytes "/Library/Logs")
    register_item \
        "Logs del sistema (/Library/Logs)" \
        "$size" "safe" \
        "/Library/Logs" \
        "sudo rm -rf /Library/Logs/*" \
        "Logs del sistema. Requiere sudo."

    # System log files
    local syslog_size=0
    for f in /var/log/*.log /var/log/*.gz /var/log/asl/*.asl; do
        if [[ -f "$f" ]]; then
            local fsize
            fsize=$(stat -f%z "$f" 2>/dev/null || echo 0)
            syslog_size=$((syslog_size + fsize))
        fi
    done
    register_item \
        "Logs de /var/log" \
        "$syslog_size" "moderate" \
        "/var/log" \
        "sudo rm -f /var/log/*.log.* /var/log/*.gz /var/log/asl/*.asl 2>/dev/null" \
        "Logs rotados del sistema."
}

scan_apple_media_analysis() {
    scan_spinner "Apple Media Analysis..."
    local path="$HOME_DIR/Library/Containers/com.apple.mediaanalysisd"
    local size
    size=$(dir_size_bytes "$path")
    register_item \
        "Apple Media Analysis (reconocimiento de fotos)" \
        "$size" "moderate" \
        "$path" \
        "rm -rf \"$path/Data\"" \
        "Cache de análisis de fotos/videos de macOS. Se reconstruye gradualmente."
}

scan_xcode() {
    scan_spinner "Xcode y simuladores..."

    local path="$HOME_DIR/Library/Developer/CoreSimulator"
    local size
    size=$(dir_size_bytes "$path")
    register_item \
        "Xcode Simuladores iOS" \
        "$size" "moderate" \
        "$path" \
        "xcrun simctl delete unavailable 2>/dev/null; rm -rf \"$HOME_DIR/Library/Developer/CoreSimulator/Caches\"" \
        "Simuladores iOS no disponibles y sus caches." \
        "no"

    path="$HOME_DIR/Library/Developer/Xcode/DerivedData"
    size=$(dir_size_bytes "$path")
    register_item \
        "Xcode DerivedData" \
        "$size" "safe" \
        "$path" \
        "rm -rf \"$path\"" \
        "Datos de compilación de Xcode. Se regeneran al compilar."

    path="$HOME_DIR/Library/Developer/Xcode/Archives"
    size=$(dir_size_bytes "$path")
    register_item \
        "Xcode Archives" \
        "$size" "risky" \
        "$path" \
        "rm -rf \"$path\"" \
        "Archivos de distribución de apps. Necesarios para symbolication de crashes."
}

scan_android() {
    scan_spinner "Android SDK y emuladores..."

    local path="$HOME_DIR/Library/Android/sdk"
    local size
    size=$(dir_size_bytes "$path")
    register_item \
        "Android SDK" \
        "$size" "risky" \
        "$path" \
        "rm -rf \"$path\"" \
        "SDK completo de Android. Necesario si desarrollas Android."

    path="$HOME_DIR/.android"
    size=$(dir_size_bytes "$path")
    register_item \
        "Android emuladores y config (~/.android)" \
        "$size" "risky" \
        "$path" \
        "rm -rf \"$path/avd\" \"$path/cache\"" \
        "AVDs y caches del emulador Android."
}

scan_docker() {
    scan_spinner "Docker y contenedores..."

    local path="$HOME_DIR/Library/Containers/com.docker.docker"
    local size
    size=$(dir_size_bytes "$path")
    register_item \
        "Docker Desktop (datos locales)" \
        "$size" "moderate" \
        "$path" \
        "docker system prune -a -f 2>/dev/null || echo 'Docker no está corriendo, limpia manualmente desde Docker Desktop'" \
        "Imágenes, contenedores y volumes de Docker." \
        "no"

    path="$HOME_DIR/.docker"
    size=$(dir_size_bytes "$path")
    register_item \
        "Docker config (~/.docker)" \
        "$size" "safe" \
        "$path" \
        "rm -rf \"$path/buildx\" \"$path/scout\" 2>/dev/null" \
        "Caches de Docker buildx y scout."

    # OrbStack
    for d in "$HOME_DIR/Library/Group Containers/"*orbstack*; do
        if [[ -d "$d" ]]; then
            size=$(dir_size_bytes "$d")
            register_item \
                "OrbStack (VMs y contenedores)" \
                "$size" "moderate" \
                "$d" \
                "echo 'Limpia desde la app OrbStack > Settings > Cleanup'" \
                "Datos de OrbStack. Limpia desde la app para evitar corrupción." \
                "no"
        fi
    done
}

scan_package_managers() {
    scan_spinner "Package managers (npm, pnpm, pip, brew)..."

    local size

    # npm cache
    size=$(dir_size_bytes "$HOME_DIR/.npm")
    register_item \
        "npm cache (~/.npm)" \
        "$size" "safe" \
        "$HOME_DIR/.npm" \
        "npm cache clean --force 2>/dev/null" \
        "Cache de paquetes npm. Se regenera al instalar." \
        "no"

    # pnpm store
    local pnpm_store="$HOME_DIR/Library/pnpm"
    size=$(dir_size_bytes "$pnpm_store")
    register_item \
        "pnpm store" \
        "$size" "safe" \
        "$pnpm_store" \
        "pnpm store prune 2>/dev/null" \
        "Paquetes huérfanos del store de pnpm." \
        "no"

    # Homebrew cache
    local brew_cache
    brew_cache="$(brew --cache 2>/dev/null || echo "$HOME_DIR/Library/Caches/Homebrew")"
    size=$(dir_size_bytes "$brew_cache")
    register_item \
        "Homebrew cache" \
        "$size" "safe" \
        "$brew_cache" \
        "brew cleanup --prune=all 2>/dev/null" \
        "Descargas y versiones viejas de Homebrew." \
        "no"

    # pip cache
    local pip_cache="$HOME_DIR/Library/Caches/pip"
    size=$(dir_size_bytes "$pip_cache")
    register_item \
        "pip cache" \
        "$size" "safe" \
        "$pip_cache" \
        "pip cache purge 2>/dev/null" \
        "Cache de paquetes Python." \
        "no"

    # Go module cache
    local gopath="${GOPATH:-$HOME_DIR/go}"
    local gomod_cache="$gopath/pkg/mod/cache"
    size=$(dir_size_bytes "$gomod_cache")
    register_item \
        "Go module cache" \
        "$size" "safe" \
        "$gomod_cache" \
        "go clean -modcache 2>/dev/null" \
        "Cache de módulos Go. Se regenera al compilar." \
        "no"

    # Cargo cache
    local cargo_cache="$HOME_DIR/.cargo/registry"
    size=$(dir_size_bytes "$cargo_cache")
    register_item \
        "Cargo/Rust cache (~/.cargo/registry)" \
        "$size" "safe" \
        "$cargo_cache" \
        "rm -rf \"$HOME_DIR/.cargo/registry/cache\" \"$HOME_DIR/.cargo/registry/src\"" \
        "Cache de crates de Rust. Se regenera al compilar."
}

scan_runtimes() {
    scan_spinner "Runtime managers (nvm, pyenv, rustup)..."

    local size

    size=$(dir_size_bytes "$HOME_DIR/.nvm")
    register_item \
        "nvm — versiones de Node (~/.nvm)" \
        "$size" "moderate" \
        "$HOME_DIR/.nvm" \
        "echo 'Usa: nvm ls && nvm uninstall <version> para cada versión que no necesites'" \
        "Múltiples versiones de Node.js instaladas." \
        "no"

    size=$(dir_size_bytes "$HOME_DIR/.pyenv")
    register_item \
        "pyenv — versiones de Python (~/.pyenv)" \
        "$size" "moderate" \
        "$HOME_DIR/.pyenv" \
        "echo 'Usa: pyenv versions && pyenv uninstall <version> para cada versión que no necesites'" \
        "Múltiples versiones de Python instaladas." \
        "no"

    size=$(dir_size_bytes "$HOME_DIR/.rustup")
    register_item \
        "rustup — toolchains de Rust (~/.rustup)" \
        "$size" "moderate" \
        "$HOME_DIR/.rustup" \
        "rustup toolchain list | grep -v default | xargs -I{} rustup toolchain uninstall {} 2>/dev/null; echo 'Limpiado toolchains no-default'" \
        "Toolchains de Rust no usados." \
        "no"

    # .reflex (Python Reflex framework)
    size=$(dir_size_bytes "$HOME_DIR/.reflex")
    register_item \
        "Reflex framework cache (~/.reflex)" \
        "$size" "safe" \
        "$HOME_DIR/.reflex" \
        "rm -rf \"$HOME_DIR/.reflex\"" \
        "Cache del framework Reflex (Python). Se regenera."
}

scan_ide_editors() {
    scan_spinner "IDEs y editores..."

    local size

    # VS Code
    size=$(dir_size_bytes "$HOME_DIR/.vscode")
    register_item \
        "VS Code extensiones (~/.vscode)" \
        "$size" "moderate" \
        "$HOME_DIR/.vscode" \
        "echo 'Revisa extensiones no usadas en VS Code > Extensions'" \
        "Extensiones de VS Code." \
        "no"

    local vscode_support="$HOME_DIR/Library/Application Support/Code"
    size=$(dir_size_bytes "$vscode_support")
    register_item \
        "VS Code datos (Application Support)" \
        "$size" "moderate" \
        "$vscode_support" \
        "rm -rf \"$vscode_support/Cache\" \"$vscode_support/CachedData\" \"$vscode_support/CachedExtensions\" 2>/dev/null" \
        "Caches internos de VS Code."

    # Cursor
    size=$(dir_size_bytes "$HOME_DIR/.cursor")
    register_item \
        "Cursor editor (~/.cursor)" \
        "$size" "moderate" \
        "$HOME_DIR/.cursor" \
        "rm -rf \"$HOME_DIR/.cursor/extensions/\"*/node_modules 2>/dev/null" \
        "Extensiones y datos de Cursor."

    local cursor_support="$HOME_DIR/Library/Application Support/Cursor"
    size=$(dir_size_bytes "$cursor_support")
    register_item \
        "Cursor datos (Application Support)" \
        "$size" "moderate" \
        "$cursor_support" \
        "rm -rf \"$cursor_support/Cache\" \"$cursor_support/CachedData\" 2>/dev/null" \
        "Caches internos de Cursor."

    # Windsurf
    size=$(dir_size_bytes "$HOME_DIR/.windsurf")
    register_item \
        "Windsurf editor (~/.windsurf)" \
        "$size" "moderate" \
        "$HOME_DIR/.windsurf" \
        "rm -rf \"$HOME_DIR/.windsurf/extensions/\"*/node_modules 2>/dev/null" \
        "Extensiones y datos de Windsurf."

    local windsurf_support="$HOME_DIR/Library/Application Support/Windsurf"
    size=$(dir_size_bytes "$windsurf_support")
    register_item \
        "Windsurf datos (Application Support)" \
        "$size" "moderate" \
        "$windsurf_support" \
        "rm -rf \"$windsurf_support/Cache\" \"$windsurf_support/CachedData\" 2>/dev/null" \
        "Caches internos de Windsurf."

    # Codeium
    size=$(dir_size_bytes "$HOME_DIR/.codeium")
    register_item \
        "Codeium AI (~/.codeium)" \
        "$size" "safe" \
        "$HOME_DIR/.codeium" \
        "rm -rf \"$HOME_DIR/.codeium\"" \
        "Modelos y caches de Codeium. Se regenera."

    # LM Studio
    size=$(dir_size_bytes "$HOME_DIR/.lmstudio")
    register_item \
        "LM Studio modelos (~/.lmstudio)" \
        "$size" "moderate" \
        "$HOME_DIR/.lmstudio" \
        "echo 'Elimina modelos no usados desde LM Studio > Models'" \
        "Modelos de LLM descargados localmente." \
        "no"

    # TabNine
    local tabnine="$HOME_DIR/Library/Application Support/TabNine"
    size=$(dir_size_bytes "$tabnine")
    register_item \
        "TabNine AI completions" \
        "$size" "safe" \
        "$tabnine" \
        "rm -rf \"$tabnine\"" \
        "Modelos y cache de TabNine."
}

scan_app_caches() {
    scan_spinner "Caches de aplicaciones..."

    local size

    # Claude Desktop
    local claude_support="$HOME_DIR/Library/Application Support/Claude"
    size=$(dir_size_bytes "$claude_support")
    register_item \
        "Claude Desktop (Application Support)" \
        "$size" "moderate" \
        "$claude_support" \
        "rm -rf \"$claude_support/Cache\" \"$claude_support/GPUCache\" \"$claude_support/Code Cache\" \"$claude_support/DawnGraphiteCache\" 2>/dev/null" \
        "Caches de la app Claude Desktop. Las conversaciones se mantienen en la nube."

    # Discord
    local discord="$HOME_DIR/Library/Application Support/discord"
    size=$(dir_size_bytes "$discord")
    register_item \
        "Discord cache" \
        "$size" "safe" \
        "$discord" \
        "rm -rf \"$discord/Cache\" \"$discord/Code Cache\" \"$discord/GPUCache\" 2>/dev/null" \
        "Caches de Discord."

    # Brave
    local brave="$HOME_DIR/Library/Application Support/BraveSoftware"
    size=$(dir_size_bytes "$brave")
    register_item \
        "Brave Browser datos" \
        "$size" "risky" \
        "$brave" \
        "echo 'Limpia desde Brave > Settings > Privacy > Clear browsing data'" \
        "Datos del navegador Brave. Limpia desde la app para no perder passwords/bookmarks." \
        "no"

    # Arc
    local arc="$HOME_DIR/Library/Application Support/Arc"
    size=$(dir_size_bytes "$arc")
    register_item \
        "Arc Browser datos" \
        "$size" "risky" \
        "$arc" \
        "echo 'Limpia desde Arc > Settings > Advanced > Clear browsing data'" \
        "Datos del navegador Arc. Limpia desde la app para no perder datos." \
        "no"

    # Warp terminal
    local warp="$HOME_DIR/Library/Application Support/dev.warp.Warp-Stable"
    size=$(dir_size_bytes "$warp")
    register_item \
        "Warp terminal datos" \
        "$size" "moderate" \
        "$warp" \
        "rm -rf \"$warp/cache\" 2>/dev/null" \
        "Caches de Warp terminal."

    # Telegram
    for d in "$HOME_DIR/Library/Containers/"*telegram* "$HOME_DIR/Library/Group Containers/"*Telegram*; do
        if [[ -d "$d" ]]; then
            size=$(dir_size_bytes "$d")
            register_item \
                "Telegram cache ($(basename "$d"))" \
                "$size" "moderate" \
                "$d" \
                "echo 'Limpia desde Telegram > Settings > Data and Storage > Storage Usage'" \
                "Cache de media de Telegram. Limpia desde la app." \
                "no"
        fi
    done

    # WhatsApp
    for d in "$HOME_DIR/Library/Group Containers/"*WhatsApp*; do
        if [[ -d "$d" ]]; then
            size=$(dir_size_bytes "$d")
            register_item \
                "WhatsApp datos ($(basename "$d"))" \
                "$size" "risky" \
                "$d" \
                "echo 'NO eliminar directamente. Limpia desde WhatsApp > Settings > Storage'" \
                "Datos de WhatsApp incluyendo media y mensajes." \
                "no"
        fi
    done

    # Gradle
    size=$(dir_size_bytes "$HOME_DIR/.gradle")
    register_item \
        "Gradle cache (~/.gradle)" \
        "$size" "safe" \
        "$HOME_DIR/.gradle" \
        "rm -rf \"$HOME_DIR/.gradle/caches\" \"$HOME_DIR/.gradle/wrapper/dists\" 2>/dev/null" \
        "Cache de builds Gradle. Se regenera al compilar."
}

scan_downloads() {
    scan_spinner "Descargas..."

    local size
    size=$(dir_size_bytes "$HOME_DIR/Downloads")
    register_item \
        "Carpeta de Descargas (~/Downloads)" \
        "$size" "risky" \
        "$HOME_DIR/Downloads" \
        "echo 'Revisa manualmente ~/Downloads y elimina lo que no necesites'" \
        "Archivos descargados. Revisa manualmente antes de eliminar." \
        "no"
}

scan_trash() {
    scan_spinner "Papelera..."

    local size
    size=$(dir_size_bytes "$HOME_DIR/.Trash")
    register_item \
        "Papelera (~/.Trash)" \
        "$size" "safe" \
        "$HOME_DIR/.Trash" \
        "rm -rf \"$HOME_DIR/.Trash\"/*" \
        "Archivos en la papelera esperando ser eliminados."
}

scan_misc() {
    scan_spinner "Otros..."

    local size

    # Virtual envs
    size=$(dir_size_bytes "$HOME_DIR/.venv")
    register_item \
        "Python venv global (~/.venv)" \
        "$size" "moderate" \
        "$HOME_DIR/.venv" \
        "rm -rf \"$HOME_DIR/.venv\"" \
        "Entorno virtual Python global."

    # interpreter (Open Interpreter)
    local interp="$HOME_DIR/Library/Application Support/interpreter"
    size=$(dir_size_bytes "$interp")
    register_item \
        "Open Interpreter data" \
        "$size" "safe" \
        "$interp" \
        "rm -rf \"$interp\"" \
        "Datos de Open Interpreter."

    # Azure Data Studio
    size=$(dir_size_bytes "$HOME_DIR/.azuredatastudio")
    register_item \
        "Azure Data Studio (~/.azuredatastudio)" \
        "$size" "moderate" \
        "$HOME_DIR/.azuredatastudio" \
        "rm -rf \"$HOME_DIR/.azuredatastudio/extensions/\"*/node_modules 2>/dev/null" \
        "Extensiones de Azure Data Studio."

    # Apple system update downloads
    size=$(dir_size_bytes "/Library/Updates")
    register_item \
        "Apple Updates descargados (/Library/Updates)" \
        "$size" "safe" \
        "/Library/Updates" \
        "sudo rm -rf /Library/Updates/*" \
        "Updates de macOS ya aplicados o descartados."
}

# ── Display Functions ────────────────────────────────────────────────────────

risk_color() {
    case "$1" in
        safe)     echo "${GREEN}" ;;
        moderate) echo "${YELLOW}" ;;
        risky)    echo "${RED}" ;;
    esac
}

risk_label() {
    case "$1" in
        safe)     echo "🟢 SEGURO" ;;
        moderate) echo "🟡 MODERADO" ;;
        risky)    echo "🔴 RIESGOSO" ;;
    esac
}

risk_explanation() {
    echo
    printf "  ${GREEN}🟢 SEGURO${NC}     — Caches y temporales. Se regeneran solos. Sin riesgo.\n"
    printf "  ${YELLOW}🟡 MODERADO${NC}  — Se puede recuperar, pero puede requerir reconfiguración.\n"
    printf "  ${RED}🔴 RIESGOSO${NC}  — Datos que podrían perderse. Doble confirmación requerida.\n"
    echo
}

display_summary() {
    banner
    local disk_total disk_used disk_avail
    disk_total=$(df -h / | awk 'NR==2{print $2}')
    disk_used=$(df -h / | awk 'NR==2{print $3}')
    disk_avail=$(df -h / | awk 'NR==2{print $4}')

    printf "  ${BOLD}Estado del disco:${NC}\n"
    printf "    Total: ${BOLD}%s${NC}  |  Usado: ${RED}${BOLD}%s${NC}  |  Libre: ${GREEN}${BOLD}%s${NC}\n" \
        "$disk_total" "$disk_used" "$disk_avail"
    printf "    Espacio recuperable encontrado: ${CYAN}${BOLD}%s${NC}\n" "$(human_size $TOTAL_RECLAIMABLE)"
    echo
    hr

    risk_explanation
    hr

    # Group by risk
    local idx=0
    for risk_level in safe moderate risky; do
        local color
        color=$(risk_color "$risk_level")
        local label
        label=$(risk_label "$risk_level")
        local has_items=false
        local group_total=0

        # Check if there are items in this group
        for ((i=0; i<ITEM_COUNT; i++)); do
            if [[ "${ITEM_RISKS[$i]}" == "$risk_level" ]]; then
                has_items=true
                group_total=$((group_total + ITEM_SIZES[$i]))
            fi
        done

        if ! $has_items; then
            continue
        fi

        printf "\n  ${color}${BOLD}━━━ %s ━━━  (Total: %s)${NC}\n\n" "$label" "$(human_size $group_total)"

        for ((i=0; i<ITEM_COUNT; i++)); do
            if [[ "${ITEM_RISKS[$i]}" == "$risk_level" ]]; then
                idx=$((idx + 1))
                local trash_tag=""
                if [[ "${ITEM_TRASHABLE[$i]}" == "yes" ]]; then
                    trash_tag=" ${DIM}[🗑️ papelera disponible]${NC}"
                fi
                printf "  ${color}[%2d]${NC} ${BOLD}%-45s${NC} %10s%b\n" \
                    "$((i+1))" "${ITEM_NAMES[$i]}" "${ITEM_SIZES_HR[$i]}" "$trash_tag"
                printf "       ${DIM}%s${NC}\n" "${ITEM_DESCRIPTIONS[$i]}"
                printf "       ${DIM}📁 %s${NC}\n" "${ITEM_PATHS[$i]}"
                echo
            fi
        done
    done

    hr
}

# ── Interactive Selection ────────────────────────────────────────────────────

interactive_menu() {
    echo
    printf "  ${BOLD}¿Qué deseas hacer?${NC}\n\n"
    printf "    ${GREEN}a${NC} — Limpiar TODO lo ${GREEN}SEGURO${NC} automáticamente\n"
    printf "    ${YELLOW}m${NC} — Limpiar todo lo ${GREEN}SEGURO${NC} + ${YELLOW}MODERADO${NC}\n"
    printf "    ${CYAN}s${NC} — Seleccionar items individuales por número\n"
    printf "    ${RED}q${NC} — Salir sin hacer nada\n"
    echo
    printf "  ${BOLD}Tu elección: ${NC}"
    read -r choice

    case "$choice" in
        a|A) cleanup_by_risk "safe" ;;
        m|M) cleanup_by_risk "safe" "moderate" ;;
        s|S) cleanup_selective ;;
        q|Q)
            echo
            printf "  ${DIM}No se realizó ningún cambio. ¡Hasta luego!${NC}\n\n"
            exit 0
            ;;
        *)
            printf "  ${RED}Opción no válida.${NC}\n"
            interactive_menu
            ;;
    esac
}

cleanup_by_risk() {
    local risks=("$@")
    local selected=()
    local total_selected=0

    for ((i=0; i<ITEM_COUNT; i++)); do
        for risk in "${risks[@]}"; do
            if [[ "${ITEM_RISKS[$i]}" == "$risk" ]]; then
                selected+=("$i")
                total_selected=$((total_selected + ITEM_SIZES[$i]))
            fi
        done
    done

    if [[ ${#selected[@]} -eq 0 ]]; then
        printf "\n  ${DIM}No hay items en esa categoría.${NC}\n"
        return
    fi

    echo
    hr
    printf "\n  ${BOLD}Items a limpiar (${#selected[@]} items, %s):${NC}\n\n" "$(human_size $total_selected)"

    for idx in "${selected[@]}"; do
        local color
        color=$(risk_color "${ITEM_RISKS[$idx]}")
        printf "    ${color}●${NC} %s — ${BOLD}%s${NC}\n" "${ITEM_NAMES[$idx]}" "${ITEM_SIZES_HR[$idx]}"
    done

    echo
    if ! ask_yn "  ¿Proceder con la limpieza?"; then
        printf "\n  ${DIM}Cancelado.${NC}\n"
        interactive_menu
        return
    fi

    execute_cleanup "${selected[@]}"
}

cleanup_selective() {
    echo
    printf "  ${BOLD}Ingresa los números separados por espacio (ej: 1 3 5):${NC}\n"
    printf "  > "
    read -r numbers

    local selected=()
    local total_selected=0

    for num in $numbers; do
        local idx=$((num - 1))
        if (( idx >= 0 && idx < ITEM_COUNT )); then
            selected+=("$idx")
            total_selected=$((total_selected + ITEM_SIZES[$idx]))
        else
            printf "  ${YELLOW}⚠ Número %s ignorado (fuera de rango)${NC}\n" "$num"
        fi
    done

    if [[ ${#selected[@]} -eq 0 ]]; then
        printf "\n  ${RED}No se seleccionó ningún item válido.${NC}\n"
        interactive_menu
        return
    fi

    echo
    hr
    printf "\n  ${BOLD}Items seleccionados (${#selected[@]} items, %s):${NC}\n\n" "$(human_size $total_selected)"

    for idx in "${selected[@]}"; do
        local color
        color=$(risk_color "${ITEM_RISKS[$idx]}")
        printf "    ${color}●${NC} %s — ${BOLD}%s${NC}\n" "${ITEM_NAMES[$idx]}" "${ITEM_SIZES_HR[$idx]}"
    done

    echo
    if ! ask_yn "  ¿Proceder con la limpieza?"; then
        printf "\n  ${DIM}Cancelado.${NC}\n"
        interactive_menu
        return
    fi

    execute_cleanup "${selected[@]}"
}

execute_cleanup() {
    local indices=("$@")
    local cleaned=0
    local failed=0
    local skipped=0
    local trashed=0
    local space_freed=0

    echo
    hr
    printf "\n  ${BOLD}${CYAN}Ejecutando limpieza...${NC}\n\n"

    for idx in "${indices[@]}"; do
        local name="${ITEM_NAMES[$idx]}"
        local risk="${ITEM_RISKS[$idx]}"
        local cmd="${ITEM_CMDS[$idx]}"
        local size="${ITEM_SIZES[$idx]}"
        local path="${ITEM_PATHS[$idx]}"
        local trashable="${ITEM_TRASHABLE[$idx]}"

        # Double confirmation for risky items
        if [[ "$risk" == "risky" ]]; then
            if ! ask_double_confirm "$name" "$path"; then
                printf "  ${DIM}⏭  Saltado: %s${NC}\n" "$name"
                skipped=$((skipped + 1))
                continue
            fi
        fi

        # Ask: Trash or permanent delete?
        local use_trash=false
        if [[ "$trashable" == "yes" ]]; then
            echo
            printf "  ${BOLD}%s${NC} (%s)\n" "$name" "${ITEM_SIZES_HR[$idx]}"
            printf "    ${GREEN}t${NC} — Mover a la Papelera (recuperable)\n"
            printf "    ${RED}d${NC} — Eliminar definitivamente\n"
            printf "    ${DIM}s${NC} — Saltar este item\n"
            printf "    Elección [t/d/s]: "
            read -r td_choice
            case "$td_choice" in
                t|T) use_trash=true ;;
                d|D) use_trash=false ;;
                s|S)
                    printf "  ${DIM}⏭  Saltado: %s${NC}\n" "$name"
                    skipped=$((skipped + 1))
                    continue
                    ;;
                *)  # Default on empty/unknown input → Trash (safer than permanent delete).
                    # Previous behavior was: SAFE items default to delete. That meant a
                    # distracted user hitting Enter could lose data permanently. Trash is
                    # recoverable; the user can always type `d` if they want delete.
                    use_trash=true
                    ;;
            esac
        fi

        printf "  ${CYAN}⏳${NC} %s: %s..." \
            "$( $use_trash && echo "Moviendo a Papelera" || echo "Limpiando" )" "$name"

        local success=false
        if $use_trash; then
            if move_to_trash "$path"; then
                success=true
                printf "\r  ${GREEN}🗑️${NC}  Papelera:  %s (${BOLD}%s${NC})\n" "$name" "${ITEM_SIZES_HR[$idx]}"
                trashed=$((trashed + 1))
            fi
        else
            if eval "$cmd" 2>/dev/null; then
                success=true
                printf "\r  ${GREEN}✅${NC} Limpiado:  %s (${BOLD}%s${NC})\n" "$name" "${ITEM_SIZES_HR[$idx]}"
                cleaned=$((cleaned + 1))
            fi
        fi

        if $success; then
            space_freed=$((space_freed + size))
        else
            printf "\r  ${RED}❌${NC} Error:     %s\n" "$name"
            failed=$((failed + 1))
        fi
    done

    # Final report
    echo
    hr
    echo
    printf "  ${BOLD}${GREEN}Limpieza completada${NC}\n\n"
    if (( cleaned > 0 )); then
        printf "    ✅ Eliminados:  ${GREEN}${BOLD}%d${NC} items\n" "$cleaned"
    fi
    if (( trashed > 0 )); then
        printf "    🗑️  En Papelera: ${CYAN}${BOLD}%d${NC} items ${DIM}(vacía la papelera para liberar espacio real)${NC}\n" "$trashed"
    fi
    if (( skipped > 0 )); then
        printf "    ⏭  Saltados:   ${YELLOW}%d${NC} items\n" "$skipped"
    fi
    if (( failed > 0 )); then
        printf "    ❌ Fallidos:   ${RED}%d${NC} items\n" "$failed"
    fi
    printf "    💾 Espacio recuperable: ${CYAN}${BOLD}~%s${NC}\n" "$(human_size $space_freed)"
    if (( trashed > 0 )); then
        printf "\n    ${YELLOW}${BOLD}Nota:${NC} Los items en la Papelera aún ocupan espacio.\n"
        printf "    Para liberar el espacio real: ${BOLD}Finder > Vaciar Papelera${NC}\n"
        printf "    O ejecuta: ${DIM}rm -rf ~/.Trash/*${NC}\n"
    fi
    echo

    # Show new disk state
    local new_avail
    new_avail=$(df -h / | awk 'NR==2{print $4}')
    printf "    Espacio libre ahora: ${GREEN}${BOLD}%s${NC}\n\n" "$new_avail"
}

# ── Non-Interactive (JSON) Mode ──────────────────────────────────────────────

output_json_scan() {
    local disk_total disk_used disk_avail
    disk_total=$(df -h / | awk 'NR==2{print $2}')
    disk_used=$(df -h / | awk 'NR==2{print $3}')
    disk_avail=$(df -h / | awk 'NR==2{print $4}')

    printf '{\n'
    printf '  "disk": {\n'
    printf '    "total": "%s",\n' "$(json_escape "$disk_total")"
    printf '    "used": "%s",\n' "$(json_escape "$disk_used")"
    printf '    "available": "%s",\n' "$(json_escape "$disk_avail")"
    printf '    "reclaimable_bytes": %d,\n' "$TOTAL_RECLAIMABLE"
    printf '    "reclaimable_human": "%s"\n' "$(json_escape "$(human_size "$TOTAL_RECLAIMABLE")")"
    printf '  },\n'
    printf '  "items": ['

    local i first=true
    for ((i=0; i<ITEM_COUNT; i++)); do
        if $first; then
            printf '\n'
            first=false
        else
            printf ',\n'
        fi
        local trashable_json="false"
        [[ "${ITEM_TRASHABLE[$i]}" == "yes" ]] && trashable_json="true"
        printf '    {'
        printf '"id":"%s",' "$(json_escape "${ITEM_IDS[$i]}")"
        printf '"index":%d,' $((i + 1))
        printf '"name":"%s",' "$(json_escape "${ITEM_NAMES[$i]}")"
        printf '"size_bytes":%d,' "${ITEM_SIZES[$i]}"
        printf '"size_human":"%s",' "$(json_escape "${ITEM_SIZES_HR[$i]}")"
        printf '"risk":"%s",' "${ITEM_RISKS[$i]}"
        printf '"path":"%s",' "$(json_escape "${ITEM_PATHS[$i]}")"
        printf '"command":"%s",' "$(json_escape "${ITEM_CMDS[$i]}")"
        printf '"description":"%s",' "$(json_escape "${ITEM_DESCRIPTIONS[$i]}")"
        printf '"trashable":%s' "$trashable_json"
        printf '}'
    done

    if ! $first; then printf '\n  '; fi
    printf ']\n'
    printf '}\n'
}

# Append a result entry to the in-flight results array
_append_result() {
    EXEC_RESULTS+=("$1")
}

execute_by_ids() {
    local ids_csv="$1"
    local mode="${2:-trash}"        # trash or delete
    local confirm_risky="${3:-false}"

    declare -a EXEC_RESULTS=()
    local succeeded=0 failed=0 skipped=0 space_freed=0

    # Split IDs by comma
    local IFS=','
    local -a ids
    read -ra ids <<< "$ids_csv"
    unset IFS

    for raw_id in "${ids[@]}"; do
        # Trim whitespace
        local requested_id="${raw_id#"${raw_id%%[![:space:]]*}"}"
        requested_id="${requested_id%"${requested_id##*[![:space:]]}"}"
        [[ -z "$requested_id" ]] && continue

        # Find index by ID
        local found=-1
        local i
        for ((i=0; i<ITEM_COUNT; i++)); do
            if [[ "${ITEM_IDS[$i]}" == "$requested_id" ]]; then
                found=$i
                break
            fi
        done

        if (( found < 0 )); then
            _append_result "$(printf '{"id":"%s","success":false,"action":"not_found","message":"ID not present in current scan"}' "$(json_escape "$requested_id")")"
            skipped=$((skipped + 1))
            continue
        fi

        local idx=$found
        local id="${ITEM_IDS[$idx]}"
        local risk="${ITEM_RISKS[$idx]}"
        local trashable="${ITEM_TRASHABLE[$idx]}"
        local path="${ITEM_PATHS[$idx]}"
        local cmd="${ITEM_CMDS[$idx]}"
        local size="${ITEM_SIZES[$idx]}"

        # Risky guard
        if [[ "$risk" == "risky" && "$confirm_risky" != "true" ]]; then
            _append_result "$(printf '{"id":"%s","success":false,"action":"skipped","message":"Risky item requires --confirm-risky"}' "$(json_escape "$id")")"
            skipped=$((skipped + 1))
            continue
        fi

        local action_taken=""
        local success=false

        if [[ "$trashable" == "yes" && "$mode" == "trash" ]]; then
            if move_to_trash "$path"; then
                success=true
                action_taken="trashed"
            fi
        else
            if eval "$cmd" >/dev/null 2>&1; then
                success=true
                if [[ "$trashable" == "yes" ]]; then
                    action_taken="deleted"
                else
                    action_taken="cleaned"
                fi
            fi
        fi

        if $success; then
            succeeded=$((succeeded + 1))
            space_freed=$((space_freed + size))
            _append_result "$(printf '{"id":"%s","success":true,"action":"%s","size_bytes":%d}' "$(json_escape "$id")" "$action_taken" "$size")"
        else
            failed=$((failed + 1))
            _append_result "$(printf '{"id":"%s","success":false,"action":"failed","message":"Cleanup command failed (may require sudo or app not running)"}' "$(json_escape "$id")")"
        fi
    done

    # Emit JSON
    printf '{\n'
    printf '  "results": ['
    local total="${#EXEC_RESULTS[@]}"
    local j first=true
    for ((j=0; j<total; j++)); do
        if $first; then
            printf '\n'
            first=false
        else
            printf ',\n'
        fi
        printf '    %s' "${EXEC_RESULTS[$j]}"
    done
    if ! $first; then printf '\n  '; fi
    printf '],\n'
    printf '  "summary": {\n'
    printf '    "succeeded": %d,\n' "$succeeded"
    printf '    "failed": %d,\n' "$failed"
    printf '    "skipped": %d,\n' "$skipped"
    printf '    "space_freed_bytes": %d\n' "$space_freed"
    printf '  }\n'
    printf '}\n'
}

usage() {
    cat <<'EOF'
diskclean.sh — Interactive Mac Disk Cleanup Tool

USAGE:
  diskclean.sh                              Interactive mode (default)
  diskclean.sh --json                       Scan and print results as JSON
  diskclean.sh --execute <ids> [opts]       Execute cleanup for given IDs
  diskclean.sh --help                       Show this message

EXECUTE OPTIONS:
  --execute <id1,id2,...>     Comma-separated item IDs (from --json output)
  --mode <trash|delete>       Default: trash (where supported)
  --confirm-risky             Required to execute items marked "risky"

EXAMPLES:
  diskclean.sh --json | jq '.items[] | select(.risk=="safe")'
  diskclean.sh --execute xcode-deriveddata,homebrew-cache --mode delete
  diskclean.sh --execute android-sdk --confirm-risky

JSON/execute modes are non-interactive and produce no prompts. Items
requiring sudo will fail in non-interactive mode — run those manually.
EOF
}

# ── Main ─────────────────────────────────────────────────────────────────────

main() {
    local action="interactive"
    local execute_ids=""
    local exec_mode="trash"
    local confirm_risky="false"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --json)
                action="json"
                JSON_MODE=true
                shift
                ;;
            --execute)
                action="execute"
                JSON_MODE=true
                execute_ids="${2:-}"
                if [[ -z "$execute_ids" || "$execute_ids" == --* ]]; then
                    echo "Error: --execute requires comma-separated IDs" >&2
                    exit 2
                fi
                shift 2
                ;;
            --mode)
                exec_mode="${2:-}"
                if [[ "$exec_mode" != "trash" && "$exec_mode" != "delete" ]]; then
                    echo "Error: --mode must be 'trash' or 'delete'" >&2
                    exit 2
                fi
                shift 2
                ;;
            --confirm-risky)
                confirm_risky="true"
                shift
                ;;
            --help|-h)
                usage
                exit 0
                ;;
            *)
                echo "Error: unknown option '$1'" >&2
                usage >&2
                exit 2
                ;;
        esac
    done

    if [[ "$JSON_MODE" != "true" ]]; then
        banner
        printf "  ${BOLD}Escaneando tu disco...${NC}\n\n"
    fi

    scan_trash
    scan_system_caches
    scan_logs
    scan_apple_media_analysis
    scan_xcode
    scan_android
    scan_docker
    scan_package_managers
    scan_runtimes
    scan_ide_editors
    scan_app_caches
    scan_downloads
    scan_misc

    if [[ "$JSON_MODE" != "true" ]]; then
        printf "\r%-70s\n" " "  # Clear spinner line
    fi

    case "$action" in
        json)
            output_json_scan
            exit 0
            ;;
        execute)
            execute_by_ids "$execute_ids" "$exec_mode" "$confirm_risky"
            exit 0
            ;;
        interactive)
            if (( ITEM_COUNT == 0 )); then
                printf "  ${GREEN}${BOLD}¡Tu disco está limpio! No se encontraron items significativos.${NC}\n\n"
                exit 0
            fi
            display_summary
            interactive_menu
            ;;
    esac
}

main "$@"
