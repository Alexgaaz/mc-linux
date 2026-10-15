#!/usr/bin/env bash
# build.sh — construit l'ISO MCShell sur Arch Linux avec archiso.
#   sudo ./build.sh                → out/mcshell-AAAA.MM.JJ-x86_64.iso (+ .sha256)
#   ./build.sh --prepare-only      prépare seulement le profil archiso (test, sans root)
# Options : --releng DIR (profil de base), --api-base URL (API Modrinth), --keep-work
set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
BUILD=$ROOT/build
OUT=$ROOT/out
RELENG=/usr/share/archiso/configs/releng
MCSHELL_RELEASE=1.0
PREPARE_ONLY=0 KEEP_WORK=0 API_BASE=""

while (($#)); do
    case $1 in
        --prepare-only) PREPARE_ONLY=1 ;;
        --keep-work) KEEP_WORK=1 ;;
        --releng) RELENG=$2; shift ;;
        --api-base) API_BASE=$2; shift ;;
        -h | --help) sed -n '2,5p' "$0"; exit 0 ;;
        *) echo "Option inconnue : $1" >&2; exit 2 ;;
    esac
    shift
done

msg() { printf '\e[1;32m==>\e[0m %s\n' "$*"; }
die() { printf '\e[1;31mERREUR :\e[0m %s\n' "$*" >&2; exit 1; }

# shellcheck source=mcshell.conf
. "$ROOT/mcshell.conf"

((PREPARE_ONLY)) || [[ $EUID -eq 0 ]] || die "Lance la construction en root : sudo ./build.sh"
((PREPARE_ONLY)) || command -v mkarchiso >/dev/null || die "archiso manquant : sudo pacman -S archiso"
command -v python3 >/dev/null || die "python3 manquant"
[[ -f $RELENG/profiledef.sh ]] || die "Profil archiso introuvable : $RELENG"

P=$BUILD/profile
A=$P/airootfs
msg "Profil archiso de base : $RELENG"
rm -rf "$P"
mkdir -p "$BUILD"
cp -a "$RELENG" "$P"

msg "Couche MCShell"
cp -a "$ROOT/overlay/." "$A/"
install -Dm644 "$ROOT/mcshell.conf" "$A/etc/mcshell.conf"
install -Dm644 "$ROOT/packages.txt" "$A/usr/local/share/mcshell/packages.txt"
install -Dm644 "$ROOT/tools/mcshell-mods.py" "$A/usr/local/share/mcshell/mcshell-mods.py"
printf 'MCShell %s (construit le %s)\n' "$MCSHELL_RELEASE" "$(date +%F)" >"$A/usr/local/share/mcshell/VERSION"

msg "Mods depuis Modrinth (Minecraft $MCSHELL_MC_VERSION)"
mod_args=(sync --mc "$MCSHELL_MC_VERSION" --loader fabric --dest "$BUILD/mods"
    --required "$MCSHELL_MODS_REQUIRED" --optional "$MCSHELL_MODS_OPTIONAL"
    --channel "${MCSHELL_MODS_CHANNEL:-beta}")
[[ -n $API_BASE ]] && mod_args+=(--api-base "$API_BASE")
python3 "$ROOT/tools/mcshell-mods.py" "${mod_args[@]}"
mkdir -p "$A/usr/local/share/mcshell/mods"
cp -a "$BUILD/mods/." "$A/usr/local/share/mcshell/mods/"

msg "Paquets"
{
    cat "$P/packages.x86_64"
    echo "# --- MCShell ---"
    grep -vE '^[[:space:]]*(#|$)' "$ROOT/packages.txt"
} | awk '/^[[:space:]]*(#|$)/ { print; next } !seen[$1]++ { print $1 }' >"$P/packages.new"
mv "$P/packages.new" "$P/packages.x86_64"

msg "Services : NetworkManager et utilisateur live"
W=$A/etc/systemd/system
rm -f "$W"/multi-user.target.wants/{iwd,systemd-networkd,sshd}.service \
    "$W"/sockets.target.wants/systemd-networkd.socket \
    "$W"/network-online.target.wants/systemd-networkd-wait-online.service \
    "$W"/dbus-org.freedesktop.network1.service
rm -rf "$W/cloud-init.target.wants"
mkdir -p "$W/multi-user.target.wants"
ln -sfn /usr/lib/systemd/system/NetworkManager.service "$W/multi-user.target.wants/NetworkManager.service"
ln -sfn /usr/lib/systemd/system/NetworkManager-dispatcher.service "$W/dbus-org.freedesktop.nm-dispatcher.service"
ln -sfn ../mcshell-live.service "$W/multi-user.target.wants/mcshell-live.service"

msg "Nom, menus de démarrage, clavier"
echo mcshell-live >"$A/etc/hostname"
printf 'KEYMAP=%s\n' "$MCSHELL_CONSOLE_KEYMAP" >"$A/etc/vconsole.conf"
for f in "$P"/efiboot/loader/entries/*.conf "$P"/syslinux/*.cfg "$P"/grub/*.cfg; do
    [[ -f $f ]] && sed -i 's/Arch Linux install medium/MCShell live/g' "$f"
done
cat >>"$P/profiledef.sh" <<'EOF'

# --- MCShell ---
iso_name="mcshell"
iso_label="MCSHELL_$(date --date="@${SOURCE_DATE_EPOCH:-$(date +%s)}" +%Y%m)"
iso_publisher="MCShell (projet personnel)"
iso_application="MCShell : Minecraft comme bureau"
file_permissions["/usr/local/bin/"]="0:0:755"
EOF
printf 'kernel_params_x86_64="cow_spacesize=%s"\n' "$MCSHELL_LIVE_COW" >>"$P/profiledef.sh"

if ((PREPARE_ONLY)); then
    msg "Profil prêt : $P"
    exit 0
fi

msg "Construction de l'ISO avec mkarchiso (10 à 30 min)"
rm -rf "$BUILD/work"
mkdir -p "$OUT"
mk_args=(-v -w "$BUILD/work" -o "$OUT")
((KEEP_WORK)) || mk_args+=(-r)
mkarchiso "${mk_args[@]}" "$P"
iso=$(find "$OUT" -maxdepth 1 -name 'mcshell-*.iso' -newer "$P/profiledef.sh" | head -n1)
[[ -n $iso ]] || die "ISO introuvable dans $OUT"
(cd "$OUT" && sha256sum "${iso##*/}" >"${iso##*/}.sha256")
msg "ISO prête : $iso"
