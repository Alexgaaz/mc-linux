#!/usr/bin/env python3
"""mcshell-mods.py — résout et télécharge les mods MCShell depuis Modrinth.

Utilisé à la construction de l'ISO (build.sh) et par `mcshell-update`.
Uniquement la bibliothèque standard Python (aucune dépendance).

Exemple :
    python3 mcshell-mods.py sync --mc 26.1.2 --loader fabric \
        --required "fabric-api waylandcraft" --optional "sodium modmenu" \
        --dest ~/.local/share/PrismLauncher/instances/MCShell/minecraft/mods

Le dossier de destination reçoit un fichier `.mcshell-managed.json` qui liste
les fichiers gérés par MCShell : seuls ceux-là sont remplacés ou supprimés lors
d'une mise à jour, les mods ajoutés à la main ne sont jamais touchés.
"""

from __future__ import annotations

import argparse
import datetime as _dt
import hashlib
import json
import os
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request

API_BASE = "https://api.modrinth.com/v2"
USER_AGENT = "MCShell/1.0 (projet personnel; construction de distro Minecraft)"
MANIFEST = ".mcshell-managed.json"
CHANNEL_RANK = {"release": 0, "beta": 1, "alpha": 2}


class ModError(RuntimeError):
    """Erreur bloquante (mod requis introuvable, hash invalide, ...)."""


def log(msg: str) -> None:
    print(msg, flush=True)


def warn(msg: str) -> None:
    print(f"  ! {msg}", file=sys.stderr, flush=True)


class Modrinth:
    def __init__(self, base: str, timeout: int = 30, retries: int = 4) -> None:
        self.base = base.rstrip("/")
        self.timeout = timeout
        self.retries = retries
        self._project_cache: dict[str, dict] = {}

    def _open(self, url: str):
        last_exc: Exception | None = None
        for attempt in range(1, self.retries + 1):
            req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
            try:
                return urllib.request.urlopen(req, timeout=self.timeout)
            except urllib.error.HTTPError as exc:
                last_exc = exc
                if exc.code == 404:
                    raise
                if exc.code == 429 or exc.code >= 500:
                    wait = exc.headers.get("Retry-After") or exc.headers.get("X-Ratelimit-Reset")
                    delay = min(float(wait), 60.0) if wait and wait.isdigit() else 2.0 * attempt
                    warn(f"HTTP {exc.code} sur {url} — nouvel essai dans {delay:.0f} s")
                    time.sleep(delay)
                    continue
                raise
            except (urllib.error.URLError, TimeoutError, ConnectionError) as exc:
                last_exc = exc
                warn(f"réseau : {exc} — nouvel essai ({attempt}/{self.retries})")
                time.sleep(2.0 * attempt)
        raise ModError(f"impossible de joindre {url} : {last_exc}")

    def get_json(self, path: str, params: dict | None = None):
        url = f"{self.base}{path}"
        if params:
            url += "?" + urllib.parse.urlencode(params)
        with self._open(url) as resp:
            return json.load(resp)

    def project(self, ref: str) -> dict:
        if ref not in self._project_cache:
            data = self.get_json(f"/project/{urllib.parse.quote(ref)}")
            self._project_cache[data["id"]] = data
            self._project_cache[data["slug"]] = data
            self._project_cache[ref] = data
        return self._project_cache[ref]

    def versions(self, ref: str, mc: str, loader: str) -> list[dict]:
        params = {
            "loaders": json.dumps([loader]),
            "game_versions": json.dumps([mc]),
            "include_changelog": "false",
        }
        return self.get_json(f"/project/{urllib.parse.quote(ref)}/version", params)

    def download(self, url: str, dest: str, sha512: str, size: int | None) -> None:
        fd, tmp = tempfile.mkstemp(prefix=".dl-", dir=os.path.dirname(dest))
        digest = hashlib.sha512()
        total = 0
        try:
            with os.fdopen(fd, "wb") as out, self._open(url) as resp:
                while True:
                    chunk = resp.read(1 << 16)
                    if not chunk:
                        break
                    digest.update(chunk)
                    total += len(chunk)
                    out.write(chunk)
            if size is not None and total != size:
                raise ModError(f"taille inattendue pour {os.path.basename(dest)} ({total} au lieu de {size})")
            if digest.hexdigest() != sha512:
                raise ModError(f"empreinte SHA-512 invalide pour {os.path.basename(dest)}")
            os.chmod(tmp, 0o644)
            os.replace(tmp, dest)
        except BaseException:
            if os.path.exists(tmp):
                os.unlink(tmp)
            raise


def pick_version(versions: list[dict], max_channel: str) -> dict | None:
    allowed = CHANNEL_RANK[max_channel]
    candidates = [v for v in versions if CHANNEL_RANK.get(v.get("version_type", "release"), 9) <= allowed]
    if not candidates:
        return None
    # Le canal le plus stable d'abord, puis la publication la plus récente.
    candidates.sort(key=lambda v: v.get("date_published", ""), reverse=True)
    candidates.sort(key=lambda v: CHANNEL_RANK.get(v.get("version_type", "release"), 9))
    return candidates[0]


def primary_file(version: dict) -> dict:
    files = version.get("files") or []
    jars = [f for f in files if f.get("filename", "").endswith(".jar")] or files
    if not jars:
        raise ModError(f"aucun fichier dans la version {version.get('id')}")
    for f in jars:
        if f.get("primary"):
            return f
    return jars[0]


def sha512_of(path: str) -> str:
    h = hashlib.sha512()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 16), b""):
            h.update(chunk)
    return h.hexdigest()


def resolve(api: Modrinth, required: list[str], optional: list[str], mc: str, loader: str,
            channel: str) -> dict[str, dict]:
    """Retourne {project_id: entrée} avec les dépendances requises incluses."""
    chosen: dict[str, dict] = {}
    queue: list[tuple[str, bool, str]] = [(s, True, "demandé") for s in required]
    queue += [(s, False, "optionnel") for s in optional]

    while queue:
        ref, is_required, reason = queue.pop(0)
        try:
            proj = api.project(ref)
        except urllib.error.HTTPError as exc:
            if exc.code == 404:
                if is_required:
                    raise ModError(f"projet Modrinth introuvable : {ref}") from None
                warn(f"{ref} : projet introuvable, ignoré")
                continue
            raise
        pid = proj["id"]
        if pid in chosen:
            chosen[pid]["required"] = chosen[pid]["required"] or is_required
            continue
        version = pick_version(api.versions(pid, mc, loader), channel)
        if version is None:
            if is_required:
                raise ModError(f"{proj['slug']} : aucune version {loader} pour Minecraft {mc}")
            warn(f"{proj['slug']} : pas de version {loader} pour Minecraft {mc}, ignoré")
            continue
        f = primary_file(version)
        chosen[pid] = {
            "slug": proj["slug"],
            "title": proj.get("title", proj["slug"]),
            "project_id": pid,
            "version_id": version["id"],
            "version_number": version.get("version_number", "?"),
            "version_type": version.get("version_type", "release"),
            "filename": f["filename"],
            "url": f["url"],
            "sha512": f["hashes"]["sha512"],
            "size": f.get("size"),
            "required": is_required,
            "reason": reason,
            "_deps": version.get("dependencies") or [],
        }
        for dep in chosen[pid]["_deps"]:
            if dep.get("dependency_type") == "required" and dep.get("project_id"):
                queue.append((dep["project_id"], is_required, f"dépendance de {proj['slug']}"))

    # Incompatibilités déclarées : on retire le mod optionnel fautif.
    for pid, entry in list(chosen.items()):
        for dep in entry["_deps"]:
            other = dep.get("project_id")
            if dep.get("dependency_type") != "incompatible" or other not in chosen or pid not in chosen:
                continue
            a, b = chosen[pid], chosen[other]
            if a["required"] and b["required"]:
                raise ModError(f"{a['slug']} est incompatible avec {b['slug']} (tous deux requis)")
            # On retire de préférence le mod qui déclare l'incompatibilité, s'il est optionnel.
            victim = a if not a["required"] else b
            warn(f"{a['slug']} est incompatible avec {b['slug']} : {victim['slug']} retiré")
            chosen.pop(victim["project_id"], None)
    return chosen


def sync(args: argparse.Namespace) -> int:
    dest = os.path.abspath(os.path.expanduser(args.dest))
    os.makedirs(dest, exist_ok=True)
    api = Modrinth(args.api_base)

    log(f"Résolution des mods pour Minecraft {args.mc} ({args.loader}) via {args.api_base}")
    chosen = resolve(api, args.required.split(), args.optional.split(), args.mc, args.loader, args.channel)

    manifest_path = os.path.join(dest, MANIFEST)
    previous: dict = {}
    if os.path.exists(manifest_path):
        try:
            with open(manifest_path, encoding="utf-8") as fh:
                previous = json.load(fh)
        except (OSError, json.JSONDecodeError):
            warn("manifeste précédent illisible, il sera recréé")

    wanted = {e["filename"] for e in chosen.values()}
    for entry in sorted(chosen.values(), key=lambda e: e["slug"]):
        target = os.path.join(dest, entry["filename"])
        flag = "requis" if entry["required"] else "optionnel"
        label = f"{entry['slug']} {entry['version_number']} [{flag}]"
        if os.path.exists(target) and sha512_of(target) == entry["sha512"]:
            log(f"  = {label} (déjà à jour)")
            continue
        if args.dry_run:
            log(f"  + {label} (simulation)")
            continue
        log(f"  + {label} → {entry['filename']}")
        api.download(entry["url"], target, entry["sha512"], entry["size"])

    for old in previous.get("mods", []):
        name = old.get("filename", "")
        if name and name not in wanted and os.path.basename(name) == name:
            path = os.path.join(dest, name)
            if os.path.exists(path):
                if args.dry_run:
                    log(f"  - {name} (simulation)")
                else:
                    os.unlink(path)
                    log(f"  - {name} (remplacé ou retiré)")

    if not args.dry_run:
        manifest = {
            "minecraft": args.mc,
            "loader": args.loader,
            "generated": _dt.datetime.now(_dt.timezone.utc).isoformat(timespec="seconds"),
            "mods": [
                {k: v for k, v in e.items() if not k.startswith("_")}
                for e in sorted(chosen.values(), key=lambda e: e["slug"])
            ],
        }
        tmp = manifest_path + ".tmp"
        with open(tmp, "w", encoding="utf-8") as fh:
            json.dump(manifest, fh, indent=2, ensure_ascii=False)
            fh.write("\n")
        os.replace(tmp, manifest_path)
    log(f"OK : {len(chosen)} mods gérés dans {dest}")
    return 0


def show(args: argparse.Namespace) -> int:
    path = os.path.join(os.path.expanduser(args.dest), MANIFEST)
    try:
        with open(path, encoding="utf-8") as fh:
            data = json.load(fh)
    except FileNotFoundError:
        print(f"Aucun manifeste MCShell dans {args.dest}")
        return 1
    print(f"Minecraft {data.get('minecraft')} ({data.get('loader')}) — généré le {data.get('generated')}")
    for m in data.get("mods", []):
        flag = "requis" if m.get("required") else "optionnel"
        print(f"  {m['slug']:<16} {m['version_number']:<28} {flag}")
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Gestion des mods MCShell (Modrinth)")
    sub = parser.add_subparsers(dest="cmd", required=True)

    p_sync = sub.add_parser("sync", help="résoudre + télécharger les mods dans un dossier")
    p_sync.add_argument("--mc", required=True, help="version de Minecraft (ex. 26.1.2)")
    p_sync.add_argument("--loader", default="fabric")
    p_sync.add_argument("--required", default="", help="slugs Modrinth requis (séparés par des espaces)")
    p_sync.add_argument("--optional", default="", help="slugs Modrinth optionnels")
    p_sync.add_argument("--dest", required=True, help="dossier mods de destination")
    p_sync.add_argument("--channel", choices=sorted(CHANNEL_RANK), default="beta",
                        help="canal le moins stable accepté (défaut : beta)")
    p_sync.add_argument("--api-base", default=os.environ.get("MCSHELL_MODRINTH_API", API_BASE))
    p_sync.add_argument("--dry-run", action="store_true")
    p_sync.set_defaults(func=sync)

    p_show = sub.add_parser("show", help="afficher les mods gérés d'un dossier")
    p_show.add_argument("--dest", required=True)
    p_show.set_defaults(func=show)

    args = parser.parse_args(argv)
    try:
        return args.func(args)
    except ModError as exc:
        print(f"ERREUR : {exc}", file=sys.stderr)
        return 2
    except KeyboardInterrupt:
        return 130


if __name__ == "__main__":
    sys.exit(main())
