#!/usr/bin/env bash
# ============================================================================
#  admin.sh — Console d'administration « admin-toolkit »
#
#  Petit système applicatif en shell : un menu unique pour piloter
#    - le contrôle de santé (Python)          : tous OS
#    - la maintenance VPS (Bash)              : Linux (root via sudo)
#    - la création de comptes AD (PowerShell) : Windows (ou pwsh sous Linux)
#    - l'installation / suppression de la planification cron
#
#  Lancement :  ./admin.sh      (ou : bash admin.sh)
# ============================================================================
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"

HEALTH_SCRIPT="$SCRIPT_DIR/sante/healthcheck.py"
HEALTH_CONFIG="$SCRIPT_DIR/sante/healthcheck.json"
HEALTH_EXAMPLE="$SCRIPT_DIR/sante/healthcheck.example.json"
HEALTH_LOG="$SCRIPT_DIR/sante/logs/healthcheck.log"
MAINT_SCRIPT="$SCRIPT_DIR/vps/vps-maintenance.sh"
AD_SCRIPT="$SCRIPT_DIR/ad/New-ADUsersBulk.ps1"
CRON_TAG="admin-toolkit"

# ----------------------------- Détection d'environnement -------------------
OS_KIND="$(uname -s)"
case "$OS_KIND" in
    Linux*)                    OS_LABEL="Linux" ;;
    MINGW*|MSYS*|CYGWIN*)      OS_LABEL="Windows (shell Git Bash)" ;;
    Darwin*)                   OS_LABEL="macOS" ;;
    *)                         OS_LABEL="$OS_KIND" ;;
esac
IS_LINUX=0;  [[ "$OS_KIND" == Linux* ]] && IS_LINUX=1
IS_WINDOWS=0; [[ "$OS_KIND" == MINGW* || "$OS_KIND" == MSYS* || "$OS_KIND" == CYGWIN* ]] && IS_WINDOWS=1

detect_python() {
    local p
    for p in python3 python py; do
        command -v "$p" >/dev/null 2>&1 && { command -v "$p"; return 0; }
    done
    return 1
}

detect_powershell() {
    if [[ $IS_WINDOWS -eq 1 ]]; then
        command -v powershell.exe >/dev/null 2>&1 && { echo powershell.exe; return 0; }
        command -v pwsh.exe >/dev/null 2>&1 && { echo pwsh.exe; return 0; }
    fi
    command -v pwsh >/dev/null 2>&1 && { echo pwsh; return 0; }
    return 1
}

# ----------------------------- Couleurs & messages -------------------------
if [[ -t 1 && "${NO_COLOR:-0}" != "1" ]]; then
    C_RESET=$'\e[0m'; C_BOLD=$'\e[1m'; C_DIM=$'\e[2m'
    C_GREEN=$'\e[32m'; C_YELLOW=$'\e[33m'; C_RED=$'\e[31m'; C_CYAN=$'\e[36m'
else
    C_RESET=""; C_BOLD=""; C_DIM=""; C_GREEN=""; C_YELLOW=""; C_RED=""; C_CYAN=""
fi

msg_ok()      { echo "  ${C_GREEN}[OK]${C_RESET} $*"; }
msg_info()    { echo "  ${C_CYAN}[i]${C_RESET}  $*"; }
msg_warn()    { echo "  ${C_YELLOW}[!]${C_RESET} $*"; }
msg_erreur()  { echo "  ${C_RED}[x]${C_RESET} $*"; }

pause() {
    echo ""
    read -r -p "Appuyez sur Entrée pour revenir au menu..." _
}

# Demande une valeur avec défaut : resultat dans la variable REPONSE
prompt_defaut() {
    local label="$1" defaut="$2"
    if [[ -n "$defaut" ]]; then
        read -r -e -p "$label [${defaut}] : " REPONSE
        REPONSE="${REPONSE:-$defaut}"
    else
        read -r -e -p "$label : " REPONSE
    fi
}

confirm() {
    local rep
    read -r -p "$1 ? [O/n] : " rep
    [[ -z "$rep" || "$rep" == "o" || "$rep" == "O" || "$rep" == "y" || "$rep" == "Y" ]]
}

# ----------------------------- Écran d'accueil -----------------------------
badge() { # $1 = texte, $2 = 1 si dispo
    if [[ "$2" == "1" ]]; then echo "${C_GREEN}$1 ✓${C_RESET}"; else echo "${C_DIM}$1 ✗${C_RESET}"; fi
}

print_header() {
    clear 2>/dev/null || true
    PY_BIN="$(detect_python)" && PY_OK=1 || PY_OK=0
    PS_BIN="$(detect_powershell)" && PS_OK=1 || PS_OK=0
    command -v systemctl >/dev/null 2>&1 && SYSD=1 || SYSD=0
    command -v crontab >/dev/null 2>&1 && CRON_OK=1 || CRON_OK=0

    echo "${C_CYAN}${C_BOLD}"
    echo "  ╔═══════════════════════════════════════════════════════════════╗"
    echo "  ║              ADMIN-TOOLKIT — console d'administration         ║"
    echo "  ╚═══════════════════════════════════════════════════════════════╝"
    echo "${C_RESET}"
    echo "  Hôte    : $(hostname 2>/dev/null || echo '?')"
    echo "  Date    : $(date '+%d/%m/%Y %H:%M')"
    echo "  OS      : $OS_LABEL"
    echo "  Outils  : $(badge python $PY_OK) · $(badge powershell $PS_OK) · $(badge systemctl $SYSD) · $(badge crontab $CRON_OK)"
    echo "  Dossier : $SCRIPT_DIR"
    echo ""
}

print_menu() {
    echo "  ${C_BOLD}Que voulez-vous faire ?${C_RESET}"
    echo ""
    echo "    1) Contrôle de santé maintenant        (HTTP, certs, disques, services)"
    echo "    2) Dernières lignes du log santé"
    echo "    3) Maintenance VPS                     (maj + nettoyage + service bot)"
    [[ $IS_LINUX -eq 1 ]] || echo "       ${C_DIM}(prévu pour Linux — indisponible ici)${C_RESET}"
    echo "    4) Création de comptes AD depuis CSV   (PowerShell + module AD)"
    [[ $PS_OK -eq 1 ]] || echo "       ${C_DIM}(PowerShell introuvable)${C_RESET}"
    echo "    5) Installer la planification cron     (santé 15 min · maintenance dim. 04:00)"
    echo "    6) Retirer la planification cron"
    echo ""
    echo "    0) Quitter"
    echo ""
}

# ----------------------------- Actions -------------------------------------
action_sante() {
    if [[ $PY_OK -ne 1 ]]; then msg_erreur "Python est introuvable (installez python3)."; return 1; fi
    local cfg="$HEALTH_CONFIG"
    if [[ ! -f "$cfg" ]]; then
        msg_warn "Aucune configuration trouvée : $cfg"
        confirm "La créer depuis l'exemple healthcheck.example.json" || return 1
        "$PY_BIN" "$HEALTH_SCRIPT" --init || return 1
        msg_info "Adaptez les cibles dans $cfg puis relancez."
        return 0
    fi
    echo ""
    "$PY_BIN" "$HEALTH_SCRIPT" --config "$cfg"
}

action_log() {
    if [[ ! -f "$HEALTH_LOG" ]]; then
        msg_warn "Pas encore de log : $HEALTH_LOG"
        msg_info "Lancez d'abord un contrôle de santé (choix 1)."
        return 1
    fi
    echo ""
    echo "--- 30 dernières lignes de $(basename "$HEALTH_LOG") ---"
    tail -n 30 "$HEALTH_LOG"
}

action_maintenance() {
    if [[ $IS_LINUX -ne 1 ]]; then
        msg_erreur "La maintenance VPS est prévue pour Linux (le script se re-lance en sudo tout seul)."
        return 1
    fi
    local svc
    prompt_defaut "Service(s) à surveiller (séparés par des virgules)" "bot"
    svc="$REPONSE"
    echo ""
    bash "$MAINT_SCRIPT" --service "$svc"
}

action_ad() {
    if [[ $PS_OK -ne 1 ]]; then
        msg_erreur "PowerShell est introuvable (script prévu pour Windows + outils RSAT/AD)."
        return 1
    fi
    if [[ ! -f "$AD_SCRIPT" ]]; then
        msg_erreur "Script introuvable : $AD_SCRIPT"
        return 1
    fi

    local csv ou company
    prompt_defaut "Fichier CSV des utilisateurs" "$SCRIPT_DIR/ad/utilisateurs.csv"
    csv="$REPONSE"
    if [[ ! -f "$csv" ]]; then
        msg_warn "Le fichier n'existe pas encore."
        msg_info "Un modèle est disponible : ad/utilisateurs-modele.csv"
        return 1
    fi
    prompt_defaut "OU cible (vide = conteneur Users du domaine)" ""
    ou="$REPONSE"
    prompt_defaut "Société (attribut Company, vide = aucun)" ""
    company="$REPONSE"

    # Chemins au format Windows pour powershell.exe
    local win_ad="$AD_SCRIPT" win_csv="$csv"
    if command -v cygpath >/dev/null 2>&1; then
        win_ad="$(cygpath -w "$AD_SCRIPT")"
        win_csv="$(cygpath -w "$csv")"
    fi

    local args=(-NoProfile -ExecutionPolicy Bypass -File "$win_ad" -CsvPath "$win_csv")
    [[ -n "$ou" ]]      && args+=(-TargetOu "$ou")
    [[ -n "$company" ]] && args+=(-Company "$company")

    echo ""
    msg_info "Lancement de la création (ajoutez -WhatIf pour simuler)..."
    echo ""
    "$PS_BIN" "${args[@]}"
    local rc=$?
    if [[ $rc -eq 0 ]]; then
        msg_ok "Création terminée sans échec (voir le rapport CSV listé plus haut)."
    else
        msg_warn "Code retour $rc : consultez le résumé et le rapport ci-dessus."
    fi
}

# ----------------------------- Planification cron --------------------------
cron_install() {
    if [[ $CRON_OK -ne 1 ]]; then
        msg_erreur "crontab est indisponible sur cette machine."
        return 1
    fi
    if [[ $PY_OK -ne 1 ]]; then
        msg_erreur "Python est requis pour le contrôle de santé planifié."
        return 1
    fi
    if [[ ! -f "$HEALTH_CONFIG" ]]; then
        msg_warn "Configuration santé absente — créons-la d'abord depuis l'exemple."
        confirm "Continuer" || return 1
        "$PY_BIN" "$HEALTH_SCRIPT" --init || return 1
    fi

    local py_abs health_line maint_line
    py_abs="$(command -v "$PY_BIN")"
    health_line="*/15 * * * * $py_abs $HEALTH_SCRIPT --config $HEALTH_CONFIG --quiet"
    maint_line="0 4 * * 0 /bin/bash $MAINT_SCRIPT --yes"

    local existing
    existing="$(crontab -l 2>/dev/null | awk -v b="# $CRON_TAG:begin" -v e="# $CRON_TAG:end" '
        $0 == b {skip=1} !skip {print} $0 == e {skip=0}
    ' || true)"

    { echo "$existing"
      echo "# $CRON_TAG:begin"
      echo "$health_line"
      echo "$maint_line"
      echo "# $CRON_TAG:end"
    } | crontab - || { msg_erreur "Impossible d'écrire la crontab."; return 1; }

    msg_ok "Planification installée :"
    echo "      ${C_DIM}santé      : toutes les 15 minutes${C_RESET}"
    echo "      ${C_DIM}maintenance : chaque dimanche à 04:00${C_RESET}"
    echo ""
    msg_info "Entrées actives :"
    crontab -l | grep -A3 "$CRON_TAG:begin" | sed 's/^/      /'
    echo ""
    msg_warn "La ligne maintenance utilise le cron de l'utilisateur courant :"
    msg_warn "déclarez-la plutôt en root (sudo crontab -e) ou autorisez le script"
    msg_warn "dans sudoers (voir README, section planification)."
}

cron_remove() {
    if [[ $CRON_OK -ne 1 ]]; then
        msg_erreur "crontab est indisponible sur cette machine."
        return 1
    fi
    local existing
    existing="$(crontab -l 2>/dev/null | awk -v b="# $CRON_TAG:begin" -v e="# $CRON_TAG:end" '
        $0 == b {skip=1} !skip {print} $0 == e {skip=0}
    ' || true)"
    { echo "$existing"; } | crontab - || { msg_erreur "Impossible de modifier la crontab."; return 1; }
    msg_ok "Planification admin-toolkit retirée de la crontab."
}

# ----------------------------- Boucle principale ---------------------------
while true; do
    print_header
    print_menu
    read -r -p "  Votre choix : " choix
    case "$choix" in
        1) action_sante ;;
        2) action_log ;;
        3) action_maintenance ;;
        4) action_ad ;;
        5) cron_install ;;
        6) cron_remove ;;
        0) echo ""; echo "  Au revoir."; exit 0 ;;
        *) msg_erreur "Choix invalide : $choix" ;;
    esac
    pause
done
