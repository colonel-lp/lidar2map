#!/usr/bin/env bash
#
# run_on_vm.sh - lance lidar2map sur la VM headless DEPUIS ton PC (Git Bash / WSL).
#
# Fait tout, en une commande et de façon idempotente :
#   1. installe les paquets de base sur la VM si absents (git, tmux, python3-venv)
#   2. clone lidar2map si absent, sinon `git pull`
#   3. bootstrap/verifie le venv (~/.lidar2map/venv) via `--version`
#   4. lance le run dans un tmux detache qui survit a la deconnexion SSH
#      (si un run tourne deja, ne le double pas)
#
# Usage : bash run_on_vm.sh <user@host> "<args lidar2map>"
#   ex : bash run_on_vm.sh root@159.69.1.2 \
#          "--lidar --laz --zone-department 83 --download --split-width 5 \
#           --cleanup --min-free-gb 20 --shading lrm:sigma=4 --file-formats mbtiles"
#
set -euo pipefail

# ============ Parametres positionnels ============
VM="${1:-}"                # $1 = user@host de ta VM Hetzner (ex: root@159.69.x.x)
ARGS="${2:-}"             # $2 = la commande lidar2map, ENTRE GUILLEMETS (une chaine)

# Config interne (rarement a changer)
REPO="https://github.com/nico579/lidar2map.git"
DIR="lidar2map"           # dossier du clone sur la VM (-> ~/lidar2map)
SESSION="lidar"           # nom de la session tmux
# =================================================

if [ -z "$VM" ] || [ -z "$ARGS" ]; then
  echo "Usage : bash run_on_vm.sh <user@host> \"<args lidar2map>\"" >&2
  echo "Exemple :" >&2
  echo "  bash run_on_vm.sh root@159.69.1.2 \"--lidar --laz --zone-department 83 --download --split-width 5 --cleanup --min-free-gb 20 --shading lrm:sigma=4 --file-formats mbtiles\"" >&2
  exit 1
fi

echo "==> Cible   : $VM"
echo "==> Params  : lidar2map $ARGS"

# Les valeurs locales (DIR/REPO/SESSION/ARGS) sont injectees en prefixe de commande ;
# le corps du heredoc est en quotes simples (<<'REMOTE') donc RIEN n'est expanse
# localement : $DIR, $HOME, etc. sont evalues sur la VM.
ssh -o ConnectTimeout=10 "$VM" \
    "DIR='$DIR' REPO='$REPO' SESSION='$SESSION' ARGS='$ARGS' bash -s" <<'REMOTE'
set -euo pipefail
SUDO=""; [ "$(id -u)" -ne 0 ] && SUDO="sudo"

# 1. Paquets de base. NB : Ubuntu fournit python3 SANS le module venv/ensurepip
#    (paquet separe python3-venv). On teste 'import ensurepip', pas juste le
#    binaire python3, sinon le venv du bootstrap echoue (ensurepip not available).
if ! command -v git  >/dev/null 2>&1 \
   || ! command -v tmux >/dev/null 2>&1 \
   || ! python3 -c "import ensurepip" >/dev/null 2>&1; then
  echo "==> Installation des paquets de base (git tmux python3-venv)..."
  $SUDO apt-get update -qq
  $SUDO apt-get install -y -qq git tmux python3 python3-venv
fi

# 2. Clone si absent, sinon mise a jour
if [ ! -d "$HOME/$DIR/.git" ]; then
  echo "==> Clone de lidar2map dans ~/$DIR ..."
  git clone "$REPO" "$HOME/$DIR"
else
  echo "==> lidar2map deja present, git pull..."
  git -C "$HOME/$DIR" pull --ff-only || echo "   (pull ignore, on continue)"
fi

cd "$HOME/$DIR"

# 3. Verif install : le 1er run bootstrappe le venv (~400 Mo, UNE fois) ; sinon rapide.
#    Fait en synchrone pour voir les erreurs d'install ici (pas cachees dans un log).
# Un run precedent sans python3-venv a pu laisser un venv a moitie cree (sans pip) :
# on le supprime pour que le bootstrap le recree proprement, sinon il bute dessus.
_venv="$HOME/.lidar2map/venv"
if [ -d "$_venv" ] && ! "$_venv/bin/python3" -m pip --version >/dev/null 2>&1; then
  echo "==> venv incomplet detecte (pip absent), suppression pour recreation..."
  rm -rf "$_venv"
fi
echo "==> Verification de l'installation (bootstrap venv si besoin)..."
python3 lidar2map.py --version

# 4. Deja en cours ? On ne double pas.
if tmux has-session -t "$SESSION" 2>/dev/null; then
  echo "==> Un run '$SESSION' tourne DEJA sur la VM. Rien relance."
  exit 0
fi

# 5. Lancement dans un tmux detache (survit a la deconnexion SSH).
echo "==> Lancement dans tmux '$SESSION'..."
tmux new-session -d -s "$SESSION" -c "$HOME/$DIR" \
  "python3 lidar2map.py $ARGS 2>&1 | tee run.log; echo; echo '=== run fini ==='; exec bash"
echo "==> Demarre."
REMOTE

echo ""
echo "OK. Le calcul tourne sur la VM, il continue meme PC eteint."
echo "  Suivi live  : ssh $VM -t 'tmux attach -t $SESSION'   (detacher : Ctrl-b puis d)"
echo "  Suivi log   : ssh $VM 'tail -f $DIR/run.log'"
echo "  Etat        : ssh $VM 'tmux ls'"
