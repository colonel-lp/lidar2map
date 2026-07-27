#!/usr/bin/env bash
#
# run_on_vm.sh - lance lidar2map sur la VM headless DEPUIS ton PC (Git Bash / WSL).
#
# Deux modes :
#   defaut (source) : git clone + python lidar2map.py -> dernier main. Les deps
#                     LAZ (laspy/lazrs, CSF) s'auto-installent au 1er chunk. Idéal
#                     pour tester TON code fraichement pousse.
#   --bundle        : binaire self-contained de la derniere release (tout inclus,
#                     ni venv ni pip). Plus rapide/robuste, mais = version publiee.
#
# Dans les deux cas : lance dans un tmux detache qui survit a la deconnexion SSH,
# idempotent (ne double pas un run en cours).
#
# Usage : bash run_on_vm.sh [--bundle] <user@host> "<args lidar2map>"
#   ex : bash run_on_vm.sh root@159.69.1.2 \
#          "--lidar --laz --zone-department 83 --download --split-width 20 \
#           --cleanup --min-free-gb 20 --shading lrm:sigma=3 --file-formats mbtiles"
#
set -euo pipefail

# ============ Parametres ============
MODE="source"
case "${1:-}" in
  --bundle) MODE="bundle"; shift ;;
  --source) MODE="source"; shift ;;
esac
VM="${1:-}"                # user@host de ta VM (ex: root@159.69.x.x)
ARGS="${2:-}"             # la commande lidar2map, ENTRE GUILLEMETS (une chaine)
SESSION="lidar"           # nom de la session tmux
# ====================================

if [ -z "$VM" ] || [ -z "$ARGS" ]; then
  echo "Usage : bash run_on_vm.sh [--bundle] <user@host> \"<args lidar2map>\"" >&2
  echo "Exemple :" >&2
  echo "  bash run_on_vm.sh root@159.69.1.2 \"--lidar --laz --zone-department 83 --download --split-width 20 --cleanup --min-free-gb 20 --shading lrm:sigma=3 --file-formats mbtiles\"" >&2
  echo "  (ajoute --bundle en 1er pour le binaire de la release au lieu de la source)" >&2
  exit 1
fi

echo "==> Mode   : $MODE"
echo "==> Cible  : $VM"
echo "==> Params : lidar2map $ARGS"

# MODE/SESSION/ARGS injectes en prefixe ; heredoc en quotes simples (<<'REMOTE')
# donc RIEN n'est expanse localement : $HOME etc. sont evalues sur la VM.
ssh -o ConnectTimeout=10 "$VM" \
    "MODE='$MODE' SESSION='$SESSION' ARGS='$ARGS' bash -s" <<'REMOTE'
set -euo pipefail
SUDO=""; [ "$(id -u)" -ne 0 ] && SUDO="sudo"

if [ "$MODE" = "bundle" ]; then
  # ---- Binaire self-contained (toutes deps incluses) ----
  URL="https://github.com/nico579/lidar2map/releases/latest/download/lidar2map-linux-x86_64.tar.gz"
  BIN="$HOME/lidar2map-linux-x86_64/lidar2map"
  if ! command -v tmux >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1; then
    echo "==> Installation tmux + curl..."
    $SUDO apt-get update -qq && $SUDO apt-get install -y -qq tmux curl
  fi
  if [ ! -x "$BIN" ]; then
    echo "==> Telechargement du binaire (~380 Mo)..."
    cd "$HOME"; curl -fsSL -o l2m.tgz "$URL"; tar xzf l2m.tgz; rm -f l2m.tgz; chmod +x "$BIN"
  fi
  "$BIN" --version
  RUN="'$BIN'"
else
  # ---- Source (git clone, dernier main) ----
  REPO="https://github.com/nico579/lidar2map.git"; DIR="$HOME/lidar2map"
  # Ubuntu fournit python3 SANS venv/ensurepip (paquet separe) -> on teste ensurepip.
  if ! command -v git >/dev/null 2>&1 || ! command -v tmux >/dev/null 2>&1 \
     || ! python3 -c "import ensurepip" >/dev/null 2>&1; then
    echo "==> Installation git tmux python3-venv..."
    $SUDO apt-get update -qq && $SUDO apt-get install -y -qq git tmux python3 python3-venv
  fi
  if [ ! -d "$DIR/.git" ]; then
    echo "==> Clone de lidar2map..."; git clone "$REPO" "$DIR"
  else
    echo "==> git pull..."; git -C "$DIR" pull --ff-only || echo "   (pull ignore)"
  fi
  # Un venv a moitie cree (run precedent sans python3-venv) : on le vire pour recreation.
  _venv="$HOME/.lidar2map/venv"
  if [ -d "$_venv" ] && ! "$_venv/bin/python3" -m pip --version >/dev/null 2>&1; then
    echo "==> venv incomplet, suppression pour recreation..."; rm -rf "$_venv"
  fi
  # Bootstrap venv + deps critiques (~400 Mo, 1 fois). Les deps LAZ (laspy/lazrs,
  # CSF) s'installent a la demande au 1er chunk (_check_deps), pas ici.
  echo "==> Bootstrap venv (1er run ~5 min)..."
  ( cd "$DIR" && python3 lidar2map.py --version )
  RUN="python3 $DIR/lidar2map.py"
fi

# Deja en cours ? On ne double pas.
if tmux has-session -t "$SESSION" 2>/dev/null; then
  echo "==> Un run '$SESSION' tourne DEJA sur la VM. Rien relance."; exit 0
fi

# Lancement dans un tmux detache. cwd = $HOME -> sorties sous ~/Projets, log ~/run.log.
echo "==> Lancement dans tmux '$SESSION'..."
tmux new-session -d -s "$SESSION" -c "$HOME" \
  "$RUN $ARGS 2>&1 | tee run.log; echo; echo '=== run fini ==='; exec bash"
echo "==> Demarre."
REMOTE

echo ""
echo "OK. Le calcul tourne sur la VM (mode $MODE), il continue meme PC eteint."
echo "  Suivi live  : ssh $VM -t 'tmux attach -t $SESSION'   (detacher : Ctrl-b puis d)"
echo "  Suivi log   : ssh $VM 'tail -f run.log'"
echo "  Etat        : ssh $VM 'tmux ls'"
echo "  Sorties     : ssh $VM 'ls -R Projets'   (a recuperer par scp en fin de run)"
