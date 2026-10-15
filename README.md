# MCShell — Minecraft comme bureau Linux

Distribution Linux (base Arch) qui démarre directement dans Minecraft. Grâce au mod
[Waylandcraft](https://github.com/EVV1E/waylandcraft), tes applications Linux (Firefox,
terminal, fichiers…) s'ouvrent comme des fenêtres posées dans le monde.

> Projet personnel indépendant, inspiré du teaser « MCShell » de nickkohls1351.
> Aucun lien avec lui, ni avec Mojang ou Microsoft.

## Comment ça marche

```
PC ─▶ GRUB (thème Minegrub) ─▶ Arch Linux ─▶ connexion automatique (console 1)
   ─▶ sway invisible (mode kiosque) ─▶ Prism Launcher ─▶ Minecraft 26.1.2 + Fabric
   ─▶ Waylandcraft = compositeur Wayland DANS le jeu ─▶ tes applis dans le monde
Minecraft fermé ─▶ menu MCShell (relancer, Wi-Fi, terminal, mises à jour, éteindre…)
```

Mods : Fabric API et Waylandcraft (requis), Sodium, Lithium, FerriteCore et Mod Menu
(optionnels : ajoutés seulement s'ils existent pour la version de Minecraft visée).

Pourquoi sway et pas cage ? cage ne gère pas le verrouillage du pointeur, indispensable
pour viser à la souris dans Minecraft. sway le gère, et MCShell le configure pour être
invisible : pas de barre, pas de bordures, chaque fenêtre en plein écran.

## Prérequis

- Un compte Microsoft qui possède **Minecraft Java Edition**. Le jeu n'est pas dans l'ISO :
  il se télécharge au premier lancement (environ 1 Go).
- Un PC 64 bits qui démarre en **UEFI**, Secure Boot désactivé.
- Carte graphique : AMD ou Intel (Mesa, recommandé) ; NVIDIA géré par l'installeur
  (pilote `nvidia-open`, expérimental).
- Une clé USB de 4 Go minimum et Internet (le filaire marche sans réglage).

## 1. Construire l'ISO

### Option A — sur Arch Linux

```bash
sudo pacman -S --needed archiso python
sudo ./build.sh
```

Résultat : `out/mcshell-AAAA.MM.JJ-x86_64.iso` et son `.sha256`.
Compte 10 à 30 minutes et environ 15 Go d'espace libre.

### Option B — Docker (Ubuntu, Fedora, WSL2 sous Windows…)

```bash
./build-in-docker.sh
```

Sous Windows avec Docker Desktop, depuis PowerShell dans le dossier du projet :

```powershell
docker run --rm --privileged -v "${PWD}:/mcshell" -w /mcshell archlinux:latest bash -c "pacman -Syu --noconfirm --needed archiso python git && bash build.sh"
```

### Option C — GitHub Actions (rien à installer)

1. Crée un dépôt GitHub et envoie-y ce dossier.
2. Onglet **Actions** → « Construire l'ISO MCShell » → **Run workflow**.
3. À la fin, télécharge l'artefact `mcshell-iso`.

## 2. Tester dans une machine virtuelle (conseillé)

Valide le démarrage et l'installeur avant de toucher à un vrai disque :

```bash
qemu-img create -f qcow2 disque.qcow2 40G
qemu-system-x86_64 -enable-kvm -m 8G -smp 4 \
  -bios /usr/share/edk2/x64/OVMF.4m.fd \
  -cdrom out/mcshell-*.iso -drive file=disque.qcow2,if=virtio \
  -device virtio-vga-gl -display gtk,gl=on
```

La 3D virtuelle peut être trop juste pour un Minecraft fluide : la VM sert surtout à
vérifier le démarrage, le menu et l'installation.

## 3. Créer la clé USB

- **Windows** : Rufus en choisissant « Écrire en mode Image DD », ou balenaEtcher.
- **Linux** : `sudo dd if=out/mcshell-*.iso of=/dev/sdX bs=4M status=progress oflag=sync`
- **Ventoy** fonctionne aussi : copie simplement l'ISO sur la clé.

## 4. Premier démarrage (session live)

1. Démarre sur la clé en UEFI (menu de démarrage : F11 sur les cartes mères MSI).
2. MCShell s'ouvre tout seul sur un écran d'accueil.
3. Sans câble réseau, l'assistant Wi-Fi (nmtui) s'affiche.
4. Prism Launcher demande ton compte Microsoft : scanne le QR code avec ton téléphone.
5. Minecraft se télécharge puis démarre. Crée un monde nommé **MCShell**
   (Superplat conseillé) : il s'ouvrira automatiquement aux démarrages suivants.
6. En jeu, appuie sur **V** pour ouvrir le lanceur d'applications.

La session live tourne en RAM (4 Go réservés aux écritures) : rien n'est conservé
à l'extinction. Pour garder ton monde et ta connexion, installe MCShell.

## 5. Installer sur un disque

Ferme Minecraft → menu MCShell → **[I] Installer** (ou `sudo mcshell-install` dans un terminal).

- Le disque choisi est **entièrement effacé** (EFI 1 Gio + système ext4). La clé live
  n'est jamais proposée, et il faut taper `EFFACER` pour confirmer.
- Pour garder Windows, installe MCShell sur **un autre disque** : GRUB détecte Windows
  et l'affiche comme un second « monde » dans l'écran de sélection.
- L'installeur demande : disque, utilisateur, mot de passe, nom de machine, fuseau
  horaire, clavier. Il télécharge ensuite environ 2 Go de paquets.
- Au redémarrage : connexion automatique, puis MCShell.

## 6. Au quotidien

### Touches

| Où | Touche | Action |
|---|---|---|
| En jeu (Waylandcraft) | V | lanceur d'applications |
| | B | gestionnaire de fenêtres |
| | G | capture du clavier pour écrire dans une fenêtre |
| | Alt+Q | capture totale (Échap envoyé à l'appli, souris relative) ; Alt+Q pour sortir |
| Partout | Ctrl+Alt+Fin | fermer Minecraft → menu MCShell |
| | Ctrl+Alt+Retour arrière | quitter vers la console (`exit` pour revenir) |

### Menu MCShell (quand Minecraft est fermé)

Entrée : jouer · P : Prism Launcher · T : terminal · R : réseau · M : mises à jour ·
D : diagnostic · I : installer (live) · B : redémarrer · E : éteindre · C : console.

### Applications MCShell dans le lanceur V

Fermer Minecraft, quitter vers la console, redémarrer, éteindre, réseau, mises à jour,
diagnostic. Redémarrer et éteindre ferment d'abord le jeu proprement pour sauvegarder le monde.

### Mises à jour

`mcshell-update` (ou menu → M) lance `pacman -Syu` puis met à jour les mods pour la
version de Minecraft configurée. Les mods que tu ajoutes à la main ne sont jamais touchés.

## 7. Configuration — `/etc/mcshell.conf`

Surcharge personnelle possible dans `~/.config/mcshell/mcshell.conf`.

| Clé | Défaut | Rôle |
|---|---|---|
| `MCSHELL_MC_VERSION` | `26.1.2` | version de Minecraft (celle exigée par Waylandcraft) |
| `MCSHELL_FABRIC_LOADER` | `0.19.5` | version de Fabric Loader (≥ 0.19.5) |
| `MCSHELL_MODS_REQUIRED` / `_OPTIONAL` | voir fichier | identifiants Modrinth |
| `MCSHELL_WORLD` | `MCShell` | monde ouvert au démarrage s'il existe (`""` = écran titre) |
| `MCSHELL_RAM_MB` | `auto` | 6 Go dès 16 Go de RAM, 4 Go dès 8 Go |
| `MCSHELL_REFRESH` | `max` | fréquence max de l'écran, `default`, ou `3440x1440@165Hz` |
| `MCSHELL_ADAPTIVE_SYNC` | `on` | FreeSync / VRR |
| `MCSHELL_KEYBOARD_LAYOUT` | `fr` | clavier de sway et des fenêtres Waylandcraft |
| `MCSHELL_GAME_BACKEND` | `auto` | `x11` force XWayland en cas de souci d'affichage |
| `MCSHELL_LIVE_COW` | `4G` | RAM d'écriture de la session live (lu à la construction) |

Pour passer à une autre version de Minecraft : modifie `MCSHELL_MC_VERSION` (et le
loader si besoin), puis lance `mcshell-update`.

## 8. Dépannage

- **`mcshell-doctor`** (menu → D) vérifie les paquets, xkbcommon ≥ 1.11, Java 25,
  le réseau, le compte, les mods, et liste les journaux.
- Journaux : `/tmp/mcshell-<uid>/launch.log` et `sway.log` ; jeu :
  `~/.local/share/PrismLauncher/instances/MCShell/minecraft/logs/latest.log`.
- 3 plantages en 3 minutes : MCShell s'arrête dans la console pour éviter une boucle.
  Tape `exit` pour réessayer.
- Écran noir ou souris étrange : `MCSHELL_GAME_BACKEND="x11"`.
- Waylandcraft ne s'initialise pas : retire MangoHud ou la capture OBS, et évite le pilote Zink.
- Fenêtres en QWERTY : vérifie `MCSHELL_KEYBOARD_LAYOUT`.

## 9. Limites

- Waylandcraft est jeune : son auteur prévient lui-même qu'il reste des bugs.
- Les fenêtres ne sont visibles que par toi (pas de partage en multijoueur).
- Ce kit a été vérifié morceau par morceau (scripts analysés, profil archiso généré,
  scénarios simulés), mais pas démarré sur ta machine : commence par la VM.
- Licences : Minecraft n'est jamais inclus. Les mods sont téléchargés depuis Modrinth
  à la construction ; garde l'ISO pour toi, ou vérifie leurs licences avant de la partager.

## Structure du projet

```
build.sh                  construction de l'ISO (archiso)
build-in-docker.sh        construction dans un conteneur Arch
mcshell.conf              configuration (→ /etc/mcshell.conf)
packages.txt              paquets ajoutés à l'ISO et à l'installation
tools/mcshell-mods.py     résolution et téléchargement des mods (Modrinth, SHA-512)
overlay/                  fichiers copiés dans le système
  usr/local/bin/          mcshell-session, -launch, -menu, -exit, -update,
                          -doctor, -netsetup, -install, -postinstall, -live-setup
  usr/local/share/mcshell lib.sh, config sway kiosque, modèles Prism, icône GRUB
  usr/local/share/applications  entrées MCShell du lanceur Waylandcraft
  etc/                    autologin, service live, profil utilisateur, terminal
.github/workflows/        construction de l'ISO sur GitHub
```
