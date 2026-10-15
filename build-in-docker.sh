#!/usr/bin/env bash
# build-in-docker.sh — construit l'ISO dans un conteneur Arch Linux.
# Pour Ubuntu, Fedora, WSL2 sous Windows… (Docker ou Podman requis).
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")"
engine=$(command -v docker || command -v podman || true)
[[ -n $engine ]] || { echo "Docker ou Podman est requis." >&2; exit 1; }
exec "$engine" run --rm --privileged -v "$PWD:/mcshell" -w /mcshell docker.io/library/archlinux:latest \
    bash -c 'pacman -Syu --noconfirm --needed archiso python git && bash build.sh "$@"' _ "$@"
