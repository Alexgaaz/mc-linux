# shellcheck shell=bash
# shellcheck disable=SC2034  # variables de configuration utilisées par les autres scripts
# lib.sh — fonctions communes à tous les scripts MCShell (à sourcer, pas à exécuter).

MCSHELL_SHARE=/usr/local/share/mcshell

if [[ -t 2 ]]; then
    _MC_OK=$'\e[1;32m' _MC_WARN=$'\e[1;33m' _MC_ERR=$'\e[1;31m' _MC_OFF=$'\e[0m'
else
    _MC_OK='' _MC_WARN='' _MC_ERR='' _MC_OFF=''
fi
msg()  { printf '%s==>%s %s\n' "$_MC_OK" "$_MC_OFF" "$*" >&2; }
warn() { printf '%s !%s  %s\n' "$_MC_WARN" "$_MC_OFF" "$*" >&2; }
err()  { printf '%sERREUR :%s %s\n' "$_MC_ERR" "$_MC_OFF" "$*" >&2; }
die()  { err "$*"; exit 1; }

# Configuration : valeurs par défaut < /etc/mcshell.conf < ~/.config/mcshell/mcshell.conf
mcshell_load_config() {
    MCSHELL_MC_VERSION="26.1.2"
    MCSHELL_FABRIC_LOADER="0.19.5"
    MCSHELL_MODS_REQUIRED="fabric-api waylandcraft"
    MCSHELL_MODS_OPTIONAL="sodium lithium ferrite-core modmenu"
    MCSHELL_MODS_CHANNEL="beta"
    MCSHELL_INSTANCE="MCShell"
    MCSHELL_WORLD="MCShell"
    MCSHELL_RAM_MB="auto"
    MCSHELL_GAME_BACKEND="auto"
    MCSHELL_GAME_LANG="fr_fr"
    MCSHELL_PRISM_LANG="fr"
    MCSHELL_KEYBOARD_LAYOUT="fr"
    MCSHELL_KEYBOARD_VARIANT=""
    MCSHELL_KEYBOARD_OPTIONS=""
    MCSHELL_CONSOLE_KEYMAP="fr-latin9"
    MCSHELL_REFRESH="max"
    MCSHELL_ADAPTIVE_SYNC="on"
    MCSHELL_TERMINAL="alacritty"
    MCSHELL_TIMEZONE="Europe/Paris"
    MCSHELL_LOCALE="fr_FR.UTF-8"
    MCSHELL_LIVE_COW="4G"
    MCSHELL_GRUB_THEME="on"
    local f
    for f in /etc/mcshell.conf "${XDG_CONFIG_HOME:-$HOME/.config}/mcshell/mcshell.conf"; do
        if [[ -r $f ]]; then
            # shellcheck disable=SC1090
            . "$f"
        fi
    done
    MCSHELL_STATE_DIR="/tmp/mcshell-${UID}"
    MCSHELL_PRISM_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/PrismLauncher"
    MCSHELL_INSTANCE_DIR="$MCSHELL_PRISM_DIR/instances/$MCSHELL_INSTANCE"
    MCSHELL_GAME_DIR="$MCSHELL_INSTANCE_DIR/minecraft"
}

mcshell_is_live() { [[ -d /run/archiso ]]; }

# Internet utile = serveurs Mojang joignables (connexion + téléchargement du jeu)
mcshell_online() {
    curl -fsS --max-time 5 -o /dev/null \
        https://piston-meta.mojang.com/mc/game/version_manifest_v2.json 2>/dev/null
}

mcshell_has_account() {
    local f=$MCSHELL_PRISM_DIR/accounts.json
    [[ -s $f ]] && jq -e '(.accounts // []) | length > 0' "$f" >/dev/null 2>&1
}

# mcshell_ini_set FICHIER CLÉ VALEUR [force|default]
# Écrit une clé dans un INI de Prism (section [General]). « default » = seulement si absente.
mcshell_ini_set() {
    local file=$1 key=$2 value=$3 mode=${4:-force} tmp
    [[ -f $file ]] || printf '[General]\n' >"$file"
    tmp=$(mktemp) || return 1
    awk -v k="$key" -v v="$value" -v mode="$mode" '
        BEGIN { done = 0; ingen = 0; general = 0 }
        /^\[General\][[:space:]]*$/ { print; ingen = 1; general = 1; next }
        /^\[/ { if (ingen && !done) { print k "=" v; done = 1 }; ingen = 0; print; next }
        !done && index($0, k "=") == 1 { print (mode == "default" ? $0 : k "=" v); done = 1; next }
        { print }
        END { if (!done) { if (!general) print "[General]"; print k "=" v } }
    ' "$file" >"$tmp" && cat "$tmp" >"$file"
    rm -f "$tmp"
}

# Mémoire max de Minecraft selon la RAM (Mo)
mcshell_auto_ram() {
    local kb gb
    kb=$(awk '/^MemTotal:/ { print $2 }' /proc/meminfo)
    gb=$((kb / 1048576))
    if ((gb >= 15)); then
        echo 6144
    elif ((gb >= 7)); then
        echo 4096
    else
        echo 2560
    fi
}

mcshell_pack_ok() {
    local pack=$MCSHELL_INSTANCE_DIR/mmc-pack.json
    [[ -f $pack ]] && jq -e --arg mc "$MCSHELL_MC_VERSION" --arg fl "$MCSHELL_FABRIC_LOADER" '
        ([.components[] | select(.uid == "net.minecraft") | .version] == [$mc])
        and ([.components[] | select(.uid == "net.fabricmc.fabric-loader") | .version] == [$fl])
    ' "$pack" >/dev/null 2>&1
}

# Composants Prism : Minecraft + Fabric (Prism complète LWJGL tout seul)
mcshell_write_pack() {
    mcshell_pack_ok && return 0
    cat >"$MCSHELL_INSTANCE_DIR/mmc-pack.json" <<EOF
{
    "components": [
        {
            "important": true,
            "uid": "net.minecraft",
            "version": "$MCSHELL_MC_VERSION"
        },
        {
            "dependencyOnly": true,
            "uid": "net.fabricmc.intermediary",
            "version": "$MCSHELL_MC_VERSION"
        },
        {
            "uid": "net.fabricmc.fabric-loader",
            "version": "$MCSHELL_FABRIC_LOADER"
        }
    ],
    "formatVersion": 1
}
EOF
}

# Prépare (ou répare) le profil Prism de l'utilisateur : réglages, instance, mods.
# Idempotent : ne remplace jamais les choix faits ensuite dans Prism ou dans le jeu.
mcshell_user_init() {
    local tpl=$MCSHELL_SHARE/prism cfg=$MCSHELL_PRISM_DIR/prismlauncher.cfg jar
    mkdir -p "$MCSHELL_PRISM_DIR" "$MCSHELL_GAME_DIR/mods" "$MCSHELL_GAME_DIR/waylandcraft" || return 1

    [[ -f $cfg ]] || cp "$tpl/prismlauncher.cfg" "$cfg"
    # Indispensables au mode « bureau » : Prism se ferme avec le jeu
    mcshell_ini_set "$cfg" CloseAfterLaunch true
    mcshell_ini_set "$cfg" QuitAfterGameStop true
    # Préférences initiales (modifiables ensuite dans Prism)
    mcshell_ini_set "$cfg" Language "$MCSHELL_PRISM_LANG" default
    mcshell_ini_set "$cfg" AutomaticJavaSwitch true default
    mcshell_ini_set "$cfg" AutomaticJavaDownload true default
    mcshell_ini_set "$cfg" UserAskedAboutAutomaticJavaDownload true default
    if [[ $MCSHELL_RAM_MB == auto ]]; then
        mcshell_ini_set "$cfg" MaxMemAlloc "$(mcshell_auto_ram)" default
    else
        mcshell_ini_set "$cfg" MaxMemAlloc "$MCSHELL_RAM_MB"
    fi

    if [[ ! -f $MCSHELL_INSTANCE_DIR/instance.cfg ]]; then
        sed "s|@NAME@|${MCSHELL_INSTANCE}|" "$tpl/instance.cfg" >"$MCSHELL_INSTANCE_DIR/instance.cfg"
        [[ -f $MCSHELL_GAME_DIR/options.txt ]] ||
            sed "s|@LANG@|${MCSHELL_GAME_LANG}|" "$tpl/options.txt" >"$MCSHELL_GAME_DIR/options.txt"
        for jar in "$MCSHELL_SHARE"/mods/*.jar; do
            if [[ -e $jar && ! -e $MCSHELL_GAME_DIR/mods/${jar##*/} ]]; then
                cp "$jar" "$MCSHELL_GAME_DIR/mods/"
            fi
        done
        if [[ -f $MCSHELL_SHARE/mods/.mcshell-managed.json ]]; then
            cp "$MCSHELL_SHARE/mods/.mcshell-managed.json" "$MCSHELL_GAME_DIR/mods/"
        fi
    fi
    # La version de Minecraft / Fabric suit toujours /etc/mcshell.conf
    mcshell_write_pack

    local wlc=$MCSHELL_GAME_DIR/waylandcraft/settings.json
    [[ -f $wlc ]] || sed "s|@TERMINAL@|${MCSHELL_TERMINAL}|" "$tpl/waylandcraft-settings.json" >"$wlc"
    return 0
}

# Génère la config sway du jour (base + clavier + écran) et affiche son chemin
mcshell_render_sway_config() {
    local out=$MCSHELL_STATE_DIR/sway.conf
    install -d -m 700 "$MCSHELL_STATE_DIR"
    {
        cat "$MCSHELL_SHARE/sway.conf"
        echo
        echo "# --- généré depuis /etc/mcshell.conf ---"
        echo "input type:keyboard {"
        printf '    xkb_layout "%s"\n' "$MCSHELL_KEYBOARD_LAYOUT"
        if [[ -n $MCSHELL_KEYBOARD_VARIANT ]]; then printf '    xkb_variant "%s"\n' "$MCSHELL_KEYBOARD_VARIANT"; fi
        if [[ -n $MCSHELL_KEYBOARD_OPTIONS ]]; then printf '    xkb_options "%s"\n' "$MCSHELL_KEYBOARD_OPTIONS"; fi
        echo "}"
        if [[ $MCSHELL_ADAPTIVE_SYNC == on ]]; then echo "output * adaptive_sync on"; fi
        case $MCSHELL_REFRESH in
            max | default | "") ;;
            *) printf 'output * mode %s\n' "$MCSHELL_REFRESH" ;;
        esac
    } >"$out"
    printf '%s\n' "$out"
}

# swaymsg qui retrouve la session sway même depuis une appli lancée par Waylandcraft
mcshell_swaymsg() {
    if [[ -z ${SWAYSOCK:-} || ! -S ${SWAYSOCK:-} ]]; then
        local s
        for s in "/run/user/$UID/sway-ipc.$UID".*.sock; do
            if [[ -S $s ]]; then
                export SWAYSOCK=$s
                break
            fi
        done
    fi
    swaymsg "$@"
}
