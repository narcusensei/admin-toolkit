#!/usr/bin/env bash
# ============================================================================
#  vps-maintenance.sh — Maintenance périodique du VPS
#
#  1) Mise à jour des paquets (apt, dnf, zypper, apk, pacman)
#  2) Nettoyage : dépendances inutiles, cache, journaux systemd (Docker en option)
#  3) État du/des service(s) bot (avec redémarrage optionnel si planté)
#  4) Instantané disque / mémoire / charge + détection de redémarrage requis
#  Résumé complet en fin d'exécution. Prévu pour un passage en cron.
#
#  Exemple cron (chaque dimanche à 04:00, en root) :
#    0 4 * * 0 /bin/bash /opt/admin-toolkit/vps/vps-maintenance.sh --yes
#
#  Usage : sudo ./vps-maintenance.sh [options]   (voir --help)
# ============================================================================
set -uo pipefail

VERSION="1.0.0"

# ----------------------------- Valeurs par défaut --------------------------
SERVICES="${BOT_SERVICE:-bot}"     # service(s) à surveiller, séparés par des virgules
RESTART_IF_FAILED=0
DO_UPDATE=1
DO_CLEAN=1
KEEP_JOURNAL="7d"                  # âge max des journaux systemd conservés
PRUNE_DOCKER=0
DISK_WARN=85                       # seuil d'alerte occupation disque (%)
LOG_FILE="/var/log/vps-maintenance.log"
DRY_RUN=0
ASSUME_YES=0

ACTIONS=(); WARNINGS=(); ERRORS=()
REBOOT_NEEDED=0
SUMMARY_DONE=0
START_SECONDS=$SECONDS
PKG=""

usage() {
    cat <<'EOF'
vps-maintenance.sh — mise à jour, nettoyage et état du service bot

Usage : sudo ./vps-maintenance.sh [options]

Options :
  --service NOM[,NOM2]    Service(s) à surveiller (défaut : bot, ou variable
                          d'environnement BOT_SERVICE)
  --restart-if-failed     Redémarre le service s'il n'est pas actif
  --no-update             Pas de mise à jour des paquets
  --no-clean              Pas de nettoyage
  --keep-journal 7d       Âge max des journaux systemd conservés
  --prune-docker          Nettoie aussi les éléments Docker inutilisés
                          (conteneurs arrêtés, images non étiquetées ; PAS les volumes)
  --disk-warn 85          Seuil d'alerte disque en %
  --log-file CHEMIN       Fichier de log (défaut : /var/log/vps-maintenance.log)
  --dry-run               Simulation : affiche les commandes sans les exécuter
  --yes, -y               Non interactif (pour cron), répond "oui" partout
  -h, --help              Cette aide

Codes retour : 0 = OK (avertissements possibles) · 1 = au moins une erreur
EOF
}

# ----------------------------- Journalisation ------------------------------
TS() { date '+%Y-%m-%d %H:%M:%S'; }

_file_log() { # $1 = niveau, $2 = message -> fichier uniquement
    [[ "$LOG_FILE" == "/dev/null" ]] && return 0
    echo "$(TS) [$1] $2" >> "$LOG_FILE" 2>/dev/null || true
}
log_info() { _file_log INFO "$*"; echo "[INFO ] $*"; }
log_raw()  { _file_log DEBUG "$*"; }                # sortie brute des commandes (fichier)
warn()     { WARNINGS+=("$*"); _file_log WARN "$*"; echo "[ATTEN] $*" >&2; }
err()      { ERRORS+=("$*"); _file_log ERROR "$*"; echo "[ERREUR] $*" >&2; }

init_log() {
    [[ $DRY_RUN -eq 1 ]] && { LOG_FILE="/dev/null"; return 0; }
    if ! touch "$LOG_FILE" 2>/dev/null; then
        LOG_FILE="${TMPDIR:-/tmp}/vps-maintenance.log"
        touch "$LOG_FILE" 2>/dev/null || LOG_FILE="/dev/null"
    fi
    # rotation sommaire : si le log dépasse ~5 Mo, on ne garde que les 2000 dernières lignes
    if [[ -f "$LOG_FILE" ]]; then
        local size
        size="$(stat -c%s "$LOG_FILE" 2>/dev/null || wc -c < "$LOG_FILE" 2>/dev/null || echo 0)"
        if [[ "$size" =~ ^[0-9]+$ ]] && (( size > 5242880 )); then
            tail -n 2000 "$LOG_FILE" > "$LOG_FILE.tmp" 2>/dev/null && mv "$LOG_FILE.tmp" "$LOG_FILE"
        fi
    fi
    _file_log INFO "========== Nouvelle exécution (v$VERSION) =========="
}

confirm() {
    [[ $ASSUME_YES -eq 1 ]] && return 0
    local rep
    read -r -p "$1 ? [o/N] : " rep
    [[ "$rep" == "o" || "$rep" == "O" || "$rep" == "y" || "$rep" == "Y" ]]
}

# Exécute une commande : sortie complète dans le log, console sobre.
run_cmd() {
    local out rc line
    if [[ $DRY_RUN -eq 1 ]]; then
        echo "[SIMUL] $*"
        return 0
    fi
    _file_log INFO "exécution : $*"
    out="$("$@" 2>&1)"; rc=$?
    if [[ -n "$out" ]]; then
        while IFS= read -r line; do log_raw "    $line"; done <<< "$out"
    fi
    if [[ $rc -ne 0 && -n "$out" ]]; then
        echo "$out" | tail -n 10 >&2
    fi
    return $rc
}

# ------------------------------- Étapes ------------------------------------
detect_pkg() {
    local pm
    for pm in apt-get dnf yum zypper pacman apk; do
        if command -v "$pm" >/dev/null 2>&1; then PKG="$pm"; return 0; fi
    done
    PKG=""
}

pkg_update() {
    case "$PKG" in
        apt-get)
            run_cmd env DEBIAN_FRONTEND=noninteractive apt-get update || return 1
            run_cmd env DEBIAN_FRONTEND=noninteractive apt-get upgrade -y ;;
        dnf|yum) run_cmd "$PKG" upgrade -y ;;
        zypper)  run_cmd "$PKG" --non-interactive patch ;;
        apk)     run_cmd "$PKG" update && run_cmd "$PKG" upgrade ;;
        pacman)  run_cmd "$PKG" -Syu --noconfirm ;;
        *) warn "Gestionnaire de paquets non reconnu : mise à jour ignorée"; return 0 ;;
    esac
}

pkg_clean() {
    case "$PKG" in
        apt-get)
            run_cmd env DEBIAN_FRONTEND=noninteractive apt-get autoremove --purge -y || return 1
            run_cmd apt-get clean ;;
        dnf|yum) run_cmd "$PKG" autoremove -y && run_cmd "$PKG" clean all ;;
        zypper)  run_cmd "$PKG" clean ;;
        apk)     run_cmd "$PKG" cache clean ;;
        pacman)  run_cmd "$PKG" -Sc --noconfirm ;;
        *) warn "Gestionnaire de paquets non reconnu : nettoyage ignoré"; return 0 ;;
    esac
}

check_reboot_needed() {
    if [[ -f /var/run/reboot-required ]]; then
        REBOOT_NEEDED=1
        warn "Un redémarrage du serveur est requis (mise à jour noyau/bibliothèques)"
    elif command -v needs-restarting >/dev/null 2>&1; then
        if ! needs-restarting -r >/dev/null 2>&1; then
            REBOOT_NEEDED=1
            warn "Un redémarrage du serveur est requis (needs-restarting)"
        fi
    fi
}

check_service() {
    local s="$1" state enabled
    if ! command -v systemctl >/dev/null 2>&1; then
        warn "systemctl indisponible : état du service '$s' inconnu"
        return 0
    fi
    state="$(systemctl is-active "$s.service" 2>/dev/null || true)"
    if [[ "$state" == "active" ]]; then
        enabled="$(systemctl is-enabled "$s.service" 2>/dev/null || echo 'inconnu')"
        log_info "Service '$s' : actif (démarrage : $enabled)"
        ACTIONS+=("Service '$s' vérifié : actif")
        return 0
    fi
    if [[ -z "$state" || "$state" == "unknown" ]]; then
        warn "Service '$s' introuvable côté systemd (vérifiez son nom)"
    else
        warn "Service '$s' est dans l'état : $state"
    fi
    # dernières lignes du journal, dans le log uniquement
    if command -v journalctl >/dev/null 2>&1; then
        _file_log DEBUG "--- journal $s.service (5 dernières lignes) ---"
        journalctl -u "$s.service" -n 5 --no-pager 2>/dev/null \
            | while IFS= read -r l; do log_raw "    $l"; done
    fi
    if [[ $RESTART_IF_FAILED -eq 1 ]]; then
        if run_cmd systemctl restart "$s.service"; then
            log_info "Service '$s' redémarré"
            ACTIONS+=("Service '$s' redémarré")
        else
            err "Échec du redémarrage du service '$s'"
        fi
    fi
}

disk_snapshot() {
    local mount="$1" out pct
    out="$(df -h "$mount" 2>/dev/null | awk 'NR==2{print $3" / "$2" ("$5")"}')"
    pct="$(df -P "$mount" 2>/dev/null | awk 'NR==2{gsub(/%/,"",$5); print $5}')"
    [[ -z "$pct" ]] && { warn "Impossible de mesurer l'occupation de $mount"; return 0; }
    log_info "Disque $mount : $out utilisé"
    if (( pct >= DISK_WARN )); then
        warn "Disque $mount à ${pct}% (seuil : ${DISK_WARN}%)"
    fi
}

# ------------------------------- Résumé ------------------------------------
print_summary() {
    [[ $SUMMARY_DONE -eq 1 ]] && return 0
    SUMMARY_DONE=1
    local dur=$(( SECONDS - START_SECONDS )) i
    echo ""
    echo "=========================== RÉSUMÉ ======================================="
    echo "  Exécution terminée le $(TS) — durée : $((dur / 60)) min $((dur % 60)) s"
    echo ""
    if (( ${#ACTIONS[@]} > 0 )); then
        echo "  Actions effectuées (${#ACTIONS[@]}) :"
        for i in "${!ACTIONS[@]}"; do echo "    - ${ACTIONS[$i]}"; done
    else
        echo "  Aucune action effectuée."
    fi
    if (( ${#WARNINGS[@]} > 0 )); then
        echo ""
        echo "  Avertissements (${#WARNINGS[@]}) :"
        for i in "${!WARNINGS[@]}"; do echo "    ! ${WARNINGS[$i]}"; done
    fi
    if (( ${#ERRORS[@]} > 0 )); then
        echo ""
        echo "  Erreurs (${#ERRORS[@]}) :"
        for i in "${!ERRORS[@]}"; do echo "    x ${ERRORS[$i]}"; done
    fi
    echo ""
    [[ $REBOOT_NEEDED -eq 1 ]] && echo "  >>> REDÉMARRAGE DU SERVEUR REQUIS <<<"
    echo "  Log complet : $LOG_FILE"
    echo "=========================================================================="
}
trap print_summary EXIT

# ----------------------------- Arguments -----------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --service)          SERVICES="${2:?--service requiert un nom}"; shift 2 ;;
        --restart-if-failed) RESTART_IF_FAILED=1; shift ;;
        --no-update)        DO_UPDATE=0; shift ;;
        --no-clean)         DO_CLEAN=0; shift ;;
        --keep-journal)     KEEP_JOURNAL="${2:?--keep-journal requiert une valeur}"; shift 2 ;;
        --prune-docker)     PRUNE_DOCKER=1; shift ;;
        --disk-warn)        DISK_WARN="${2:?--disk-warn requiert une valeur}"; shift 2 ;;
        --log-file)         LOG_FILE="${2:?--log-file requiert un chemin}"; shift 2 ;;
        --dry-run)          DRY_RUN=1; shift ;;
        --yes|-y)           ASSUME_YES=1; shift ;;
        -h|--help)          SUMMARY_DONE=1; usage; exit 0 ;;
        *) echo "Option inconnue : $1 (voir --help)" >&2; exit 64 ;;
    esac
done

# ------------------------------- Pré-requis --------------------------------
if [[ $EUID -ne 0 && $DRY_RUN -ne 1 ]]; then
    if command -v sudo >/dev/null 2>&1; then
        exec sudo bash "$0" "$@"
    else
        echo "ERREUR : ce script doit être exécuté en root (sudo)." >&2
        exit 1
    fi
fi

init_log

# Verrou anti-doublon (une seule exécution à la fois)
if [[ $EUID -eq 0 && -d /var/run ]] && command -v flock >/dev/null 2>&1; then
    exec 9>/var/run/vps-maintenance.lock
    if ! flock -n 9; then
        warn "Une autre instance est déjà en cours : arrêt."
        exit 0
    fi
fi

IFS=',' read -ra SVC_LIST <<< "$SERVICES"

# ------------------------------ Exécution ----------------------------------
echo "=== Maintenance VPS v$VERSION — $(TS) ==="
log_info "Hôte : $(hostname 2>/dev/null || echo '?') — noyau : $(uname -r 2>/dev/null || echo '?')"

detect_pkg
if [[ -n "$PKG" ]]; then
    log_info "Gestionnaire de paquets détecté : $PKG"
else
    warn "Aucun gestionnaire de paquets connu détecté"
fi

# --- 1) Mise à jour ---------------------------------------------------------
if [[ $DO_UPDATE -eq 1 ]]; then
    echo ""
    log_info "[1/4] Mise à jour du système..."
    if [[ -n "$PKG" ]]; then
        if pkg_update; then
            ACTIONS+=("Mise à jour des paquets effectuée ($PKG)")
        else
            err "La mise à jour des paquets a échoué (voir log)"
        fi
    fi
    check_reboot_needed
else
    log_info "[1/4] Mise à jour sautée (--no-update)"
fi

# --- 2) Nettoyage -----------------------------------------------------------
if [[ $DO_CLEAN -eq 1 ]]; then
    echo ""
    log_info "[2/4] Nettoyage..."
    if [[ -n "$PKG" ]]; then
        if pkg_clean; then
            ACTIONS+=("Nettoyage du gestionnaire de paquets ($PKG)")
        else
            err "Le nettoyage des paquets a échoué (voir log)"
        fi
    fi
    if command -v journalctl >/dev/null 2>&1; then
        if run_cmd journalctl --vacuum-time="$KEEP_JOURNAL"; then
            ACTIONS+=("Journaux systemd réduits à $KEEP_JOURNAL")
        else
            warn "Impossible de réduire les journaux systemd"
        fi
    fi
    if [[ $PRUNE_DOCKER -eq 1 ]]; then
        if command -v docker >/dev/null 2>&1; then
            if confirm "Nettoyer les éléments Docker inutilisés (conteneurs arrêtés, images non étiquetées, réseaux)"; then
                if run_cmd docker system prune -f; then
                    ACTIONS+=("Docker nettoyé (system prune)")
                else
                    err "docker system prune a échoué"
                fi
            fi
        else
            warn "--prune-docker demandé mais docker est absent"
        fi
    fi
else
    log_info "[2/4] Nettoyage sauté (--no-clean)"
fi

# --- 3) État du/des service(s) bot ------------------------------------------
echo ""
log_info "[3/4] État du/des service(s) : ${SVC_LIST[*]}..."
for svc in "${SVC_LIST[@]}"; do
    [[ -n "$svc" ]] && check_service "$svc"
done

# --- 4) Instantané des ressources -------------------------------------------
echo ""
log_info "[4/4] Ressources..."
disk_snapshot /
if command -v free >/dev/null 2>&1; then
    log_info "Mémoire : $(free -h | awk 'NR==2{print $3" / "$2" utilisés"}')"
fi
if [[ -r /proc/loadavg ]]; then
    log_info "Charge : $(awk '{print $1", "$2", "$3}' /proc/loadavg)"
fi

# ------------------------------- Bilan --------------------------------------
EXIT_CODE=0
(( ${#ERRORS[@]} > 0 )) && EXIT_CODE=1
exit $EXIT_CODE
