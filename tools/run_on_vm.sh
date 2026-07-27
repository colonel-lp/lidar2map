#!/usr/bin/env bash
#
# run_on_vm.sh - lance lidar2map sur la VM headless DEPUIS ton PC (Git Bash / WSL).
#
# Utilise le BINAIRE self-contained (PyInstaller) : toutes les deps sont incluses
# (laspy, lazrs, CSF, rasterio, numpy...), donc AUCUN venv, AUCUN bootstrap, aucune
# dep a installer. Idempotent :
#   1. installe tmux si absent (pour survivre a la deconnexion SSH)
#   2. telecharge + extrait le binaire s'il n'est pas deja la
#   3. lance le run dans un tmux detache (si un run tourne deja, ne le double pas)
#
# Usage : bash run_on_vm.sh <user@host> "<args lidar2map>"
#   ex : bash run_on_vm.sh root@159.69.1.2 \
#          "--lidar --laz --zone-department 83 --download --split-width 20 \
#           --cleanup --min-free-gb 20 --shading lrm:sigma=3 --file-formats mbtiles"
#
set -euo pipefail

# ============ Parametres positionnels ============
VM="${1:-}"                # $1 = user@host de ta VM Hetzner (ex: root@159.69.x.x)
ARGS="${2:-}"             # $2 = la commande lidar2map, ENTRE GUILLEMETS (une chaine)

# Config interne (rarement a changer)
SESSION="lidar"           # nom de la session tmux
# =================================================

if [ -z "$VM" ] || [ -z "$ARGS" ]; then
  echo "Usage : bash run_on_vm.sh <user@host> \"<args lidar2map>\"" >&2
  echo "Exemple :" >&2
  echo "  bash run_on_vm.sh root@159.69.1.2 \"--lidar --laz --zone-department 83 --download --split-width 20 --cleanup --min-free-gb 20 --shading lrm:sigma=3 --file-formats mbtiles\"" >&2
  exit 1
fi

echo "==> Cible   : $VM"
echo "==> Params  : lidar2map $ARGS"

# SESSION/ARGS injectes en prefixe ; le corps du heredoc est en quotes simples
# (<<'REMOTE') donc RIEN n'est expanse localement : $HOME etc. sont evalues sur la VM.
ssh -o ConnectTimeout=10 "$VM" \
    "SESSION='$SESSION' ARGS='$ARGS' bash -s" <<'REMOTE'
set -euo pipefail
SUDO=""; [ "$(id -u)" -ne 0 ] && SUDO="sudo"

URL="https://github.com/nico579/lidar2map/releases/latest/download/lidar2map-linux-x86_64.tar.gz"
BIN="$HOME/lidar2map-linux-x86_64/lidar2map"

# 1. tmux (garder le run vivant apres deconnexion) + curl (download)
if ! command -v tmux >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1; then
  echo "==> Installation de tmux + curl..."
  $SUDO apt-get update -qq
  $SUDO apt-get install -y -qq tmux curl
fi

# 2. Binaire self-contained. Idempotent : re-telecharge seulement si absent.
if [ ! -x "$BIN" ]; then
  echo "==> Telechargement du binaire lidar2map (self-contained, ~380 Mo)..."
  cd "$HOME"
  curl -fsSL -o lidar2map.tar.gz "$URL"
  tar xzf lidar2map.tar.gz
  rm -f lidar2map.tar.gz
  chmod +x "$BIN"
else
  echo "==> Binaire deja present, on le garde (rm -rf ~/lidar2map-linux-x86_64 pour forcer)."
fi
"$BIN" --version

# 3. Deja en cours ? On ne double pas.
if tmux has-session -t "$SESSION" 2>/dev/null; then
  echo "==> Un run '$SESSION' tourne DEJA sur la VM. Rien relance."
  exit 0
fi

# 4. Lancement dans un tmux detache (survit a la deconnexion SSH). cwd = $HOME :
#    les sorties atterrissent sous ~/Projets, le log dans ~/run.log.
echo "==> Lancement dans tmux '$SESSION'..."
tmux new-session -d -s "$SESSION" -c "$HOME" \
  "'$BIN' $ARGS 2>&1 | tee run.log; echo; echo '=== run fini ==='; exec bash"
echo "==> Demarre."
REMOTE

echo ""
echo "OK. Le calcul tourne sur la VM, il continue meme PC eteint."
echo "  Suivi live  : ssh $VM -t 'tmux attach -t $SESSION'   (detacher : Ctrl-b puis d)"
echo "  Suivi log   : ssh $VM 'tail -f run.log'"
echo "  Etat        : ssh $VM 'tmux ls'"
echo "  Sorties     : ssh $VM 'ls -R Projets'   (a recuperer par scp en fin de run)"
