#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Contrôle de santé périodique — services, endpoints, certificats, disques.

Vérifications (configurées dans healthcheck.json) :
  - HTTP    : code de réponse attendu, mot-clé dans la page, temps de réponse
  - TCP     : port joignable
  - CERT    : expiration du certificat TLS d'un hôte
  - DISK    : taux d'occupation d'un chemin / point de montage
  - SERVICE : état d'un service (systemd sous Linux, "sc" sous Windows)

Alertes :
  - log dédié avec rotation automatique (log_file dans la config)
  - webhook optionnel (Slack / Discord / Teams) lors d'un changement d'état
  - rappel périodique tant que l'anomalie persiste (alert_repeat_hours)

Codes retour : 0 = tout va bien · 1 = au moins un avertissement
               2 = au moins une alerte critique · 3 = erreur de configuration

Exemples :
  python3 healthcheck.py                          # une passe, config par défaut
  python3 healthcheck.py -c /etc/healthcheck.json # config explicite
  python3 healthcheck.py --loop 300               # toutes les 5 minutes
  python3 healthcheck.py --init                   # crée healthcheck.json depuis l'exemple
"""
from __future__ import annotations

import argparse
import json
import logging
import os
import shutil
import socket
import ssl
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
from dataclasses import dataclass
from datetime import datetime, timezone
from logging.handlers import RotatingFileHandler

VERSION = "1.0.0"
OK, WARN, CRIT = "OK", "WARN", "CRIT"
_SEVERITY = {OK: 0, WARN: 1, CRIT: 2}
_LEVEL = {OK: logging.INFO, WARN: logging.WARNING, CRIT: logging.ERROR}
_COLORS = {OK: "\033[32m", WARN: "\033[33m", CRIT: "\033[31m"}
_RESET = "\033[0m"

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
DEFAULT_CONFIG = os.path.join(SCRIPT_DIR, "healthcheck.json")
EXAMPLE_CONFIG = os.path.join(SCRIPT_DIR, "healthcheck.example.json")

log = logging.getLogger("healthcheck")


# ---------------------------------------------------------------------------
# Modèle de résultat
# ---------------------------------------------------------------------------
@dataclass
class CheckResult:
    category: str   # HTTP / TCP / CERT / DISK / SERVICE
    name: str
    status: str     # OK / WARN / CRIT
    message: str


def worst_status(results):
    return max((r.status for r in results), key=lambda s: _SEVERITY[s], default=OK)


# ---------------------------------------------------------------------------
# Vérifications
# ---------------------------------------------------------------------------
def check_http(spec: dict) -> CheckResult:
    name = spec.get("name") or spec.get("url", "?")
    url = spec.get("url", "")
    expected = int(spec.get("expected_status", 200))
    timeout = float(spec.get("timeout", 10))
    warn_ms = float(spec.get("warn_ms", 2000))
    keyword = spec.get("keyword") or None

    req = urllib.request.Request(
        url, headers={"User-Agent": f"admin-toolkit-healthcheck/{VERSION}"}
    )
    start = time.monotonic()
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            status = resp.status
            body = resp.read(65536).decode("utf-8", "replace")
    except urllib.error.HTTPError as exc:
        status, body = exc.code, ""
    except Exception as exc:
        return CheckResult("HTTP", name, CRIT, f"indisponible : {exc}")

    latency_ms = (time.monotonic() - start) * 1000
    if status != expected:
        return CheckResult("HTTP", name, CRIT, f"code {status} (attendu {expected}) en {latency_ms:.0f} ms")
    if keyword and keyword not in body:
        return CheckResult("HTTP", name, CRIT, f"code {status} mais mot-clé « {keyword} » absent de la page")
    if latency_ms > warn_ms:
        return CheckResult("HTTP", name, WARN, f"code {status} en {latency_ms:.0f} ms (seuil {warn_ms:.0f} ms)")
    return CheckResult("HTTP", name, OK, f"code {status} en {latency_ms:.0f} ms")


def check_tcp(spec: dict) -> CheckResult:
    name = spec.get("name") or f"{spec.get('host')}:{spec.get('port')}"
    host = spec.get("host", "")
    port = int(spec.get("port", 0))
    timeout = float(spec.get("timeout", 5))
    start = time.monotonic()
    try:
        with socket.create_connection((host, port), timeout=timeout):
            latency_ms = (time.monotonic() - start) * 1000
            return CheckResult("TCP", name, OK, f"port {port} joignable en {latency_ms:.0f} ms")
    except Exception as exc:
        return CheckResult("TCP", name, CRIT, f"port {port} injoignable : {exc}")


def _fetch_cert_not_after(host: str, port: int, timeout: float, insecure: bool = False):
    """Renvoie la date d'expiration (datetime UTC) du certificat de host:port."""
    ctx = ssl.create_default_context()
    if insecure:  # pour dater précisément un certificat déjà jugé invalide
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
    with socket.create_connection((host, port), timeout=timeout) as sock:
        with ctx.wrap_socket(sock, server_hostname=host) as tls:
            der = tls.getpeercert(binary_form=True)
    if not der:
        raise ValueError("aucun certificat présenté par le serveur")

    decode = getattr(ssl._ssl, "_test_decode_cert", None)  # API stdlib de fait
    if decode is None:
        raise ValueError("décodage de certificat indisponible dans cette version de Python")

    fd, path = tempfile.mkstemp(suffix=".pem", text=True)
    try:
        with os.fdopen(fd, "w") as fh:
            fh.write(ssl.DER_cert_to_PEM_cert(der))
        info = decode(path)
    finally:
        try:
            os.unlink(path)
        except OSError:
            pass

    # ex. 'Nov  6 12:00:00 2026 GMT' -> datetime UTC (les dates cert. sont en GMT)
    raw = info.get("notAfter", "")
    naive = datetime.strptime(raw.rsplit(" ", 1)[0], "%b %d %H:%M:%S %Y")
    return naive.replace(tzinfo=timezone.utc)


def check_cert(spec: dict) -> CheckResult:
    name = spec.get("name") or spec.get("host", "?")
    host = spec.get("host", "")
    port = int(spec.get("port", 443))
    timeout = float(spec.get("timeout", 10))
    warn_days = int(spec.get("warn_days", 30))
    crit_days = int(spec.get("crit_days", 7))

    try:
        try:
            not_after = _fetch_cert_not_after(host, port, timeout)
        except ssl.SSLCertVerificationError as exc:
            # certificat refusé (expiré, CN invalide...) : on retente sans
            # vérification pour dater l'expiration avec précision
            try:
                not_after = _fetch_cert_not_after(host, port, timeout, insecure=True)
                days = (not_after - datetime.now(timezone.utc)).days
                if days < 0:
                    return CheckResult("CERT", name, CRIT,
                                       f"certificat EXPIRÉ depuis {-days} jour(s) ({not_after:%Y-%m-%d})")
            except Exception:
                pass
            raise exc

        days = (not_after - datetime.now(timezone.utc)).days
        if days <= crit_days:
            return CheckResult("CERT", name, CRIT, f"expire dans {days} j ({not_after:%Y-%m-%d})")
        if days <= warn_days:
            return CheckResult("CERT", name, WARN, f"expire dans {days} j ({not_after:%Y-%m-%d})")
        return CheckResult("CERT", name, OK, f"expire dans {days} j ({not_after:%Y-%m-%d})")
    except Exception as exc:
        return CheckResult("CERT", name, CRIT, f"vérification impossible : {exc}")


def check_disk(spec: dict) -> CheckResult:
    path = spec.get("path") or spec.get("mount", "/")
    name = spec.get("name") or path
    warn_pct = float(spec.get("warn_percent", spec.get("max_percent", 85)))
    crit_pct = float(spec.get("crit_percent", warn_pct + 10))

    try:
        usage = shutil.disk_usage(path)
    except Exception as exc:
        return CheckResult("DISK", name, CRIT, f"illisible : {exc}")

    pct = usage.used / usage.total * 100
    human_used = _human_size(usage.used)
    human_total = _human_size(usage.total)
    if pct >= crit_pct:
        return CheckResult("DISK", name, CRIT, f"{pct:.1f}% utilisé ({human_used}/{human_total})")
    if pct >= warn_pct:
        return CheckResult("DISK", name, WARN, f"{pct:.1f}% utilisé ({human_used}/{human_total})")
    return CheckResult("DISK", name, OK, f"{pct:.1f}% utilisé ({human_used}/{human_total})")


def check_service(spec: dict) -> CheckResult:
    name = spec.get("name") or "?"
    try:
        if shutil.which("systemctl"):
            out = subprocess.run(["systemctl", "is-active", name],
                                 capture_output=True, text=True, timeout=15)
            state = (out.stdout or "").strip().lower()
            if state == "active":
                return CheckResult("SERVICE", name, OK, "actif (running)")
            return CheckResult("SERVICE", name, CRIT, f"état : {state or 'inconnu'}")
        if os.name == "nt" and shutil.which("sc"):
            out = subprocess.run(["sc", "query", name],
                                 capture_output=True, text=True, timeout=15)
            state = (out.stdout or "") + (out.stderr or "")
            if "RUNNING" in state:
                return CheckResult("SERVICE", name, OK, "actif (running)")
            return CheckResult("SERVICE", name, CRIT, "arrêté ou inexistant")
        return CheckResult("SERVICE", name, WARN, "non vérifiable sur cette machine (ni systemd ni sc)")
    except FileNotFoundError:
        return CheckResult("SERVICE", name, WARN, "outil d'état des services introuvable")
    except Exception as exc:
        return CheckResult("SERVICE", name, CRIT, f"erreur : {exc}")


def _human_size(n: float) -> str:
    for unit in ("o", "Kio", "Mio", "Gio", "Tio"):
        if n < 1024 or unit == "Tio":
            return f"{n:.0f} {unit}" if unit == "o" else f"{n:.1f} {unit}"
        n /= 1024
    return f"{n:.1f} Tio"


# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
def load_config(path: str) -> dict:
    if not os.path.isfile(path):
        raise FileNotFoundError(
            f"Configuration introuvable : {path}\n"
            f"Créez-la depuis l'exemple :  python3 {os.path.basename(__file__)} --init"
        )
    try:
        with open(path, "r", encoding="utf-8") as fh:
            cfg = json.load(fh)
    except json.JSONDecodeError as exc:
        raise ValueError(f"JSON invalide dans {path} : {exc}")
    if not isinstance(cfg, dict):
        raise ValueError(f"La configuration doit être un objet JSON : {path}")
    return cfg


def resolve_path(path: str, config_path: str) -> str:
    """Chemin relatif -> résolu par rapport au dossier de la config (cron-friendly)."""
    if not path or os.path.isabs(path):
        return path
    return os.path.join(os.path.dirname(os.path.abspath(config_path)), path)


def setup_logging(log_file: str) -> None:
    log.setLevel(logging.INFO)
    log.handlers.clear()
    if log_file:
        os.makedirs(os.path.dirname(os.path.abspath(log_file)), exist_ok=True)
        handler = RotatingFileHandler(log_file, maxBytes=2_000_000, backupCount=3, encoding="utf-8")
        handler.setFormatter(logging.Formatter("%(asctime)s [%(levelname)s] %(message)s"))
        log.addHandler(handler)
    console = logging.StreamHandler(sys.stderr)
    console.setLevel(logging.CRITICAL + 10)  # la console est gérée à la main
    log.addHandler(console)


# ---------------------------------------------------------------------------
# Alertes (changement d'état + rappels + webhook)
# ---------------------------------------------------------------------------
def state_file_path(cfg: dict, config_path: str) -> str:
    p = cfg.get("state_file")
    if p:
        return resolve_path(p, config_path)
    log_file = resolve_path(cfg.get("log_file") or "logs/healthcheck.log", config_path)
    root, _ = os.path.splitext(log_file)
    return root + "-state.json"


def load_state(path: str) -> dict:
    try:
        with open(path, "r", encoding="utf-8") as fh:
            return json.load(fh)
    except (OSError, json.JSONDecodeError):
        return {}


def save_state(path: str, state: dict) -> None:
    try:
        os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
        with open(path, "w", encoding="utf-8") as fh:
            json.dump(state, fh, ensure_ascii=False, indent=1)
    except OSError as exc:
        log.error("Impossible d'écrire l'état d'alerte %s : %s", path, exc)


def send_webhook(url: str, text: str, timeout: float) -> None:
    # Clés "text" (Slack/Teams) + "content" (Discord) : compatible avec les trois.
    payload = json.dumps({"text": text[:1900], "content": text[:1900],
                          "title": "Contrôle de santé — admin-toolkit"}).encode()
    req = urllib.request.Request(url, data=payload, headers={"Content-Type": "application/json"})
    try:
        urllib.request.urlopen(req, timeout=timeout)
    except Exception as exc:
        log.error("Envoi du webhook impossible : %s", exc)


def process_alerts(results, cfg, config_path) -> None:
    state = load_state(state_file_path(cfg, config_path))
    now = time.time()
    repeat_s = float(cfg.get("alert_repeat_hours", 24)) * 3600
    changes = []

    for r in results:
        key = f"{r.category}:{r.name}"
        entry = state.get(key, {})
        prev = entry.get("status", OK)

        if _SEVERITY[r.status] > 0:
            if prev == OK:
                changes.append(f"[ALERTE ] {r.category:<7} {r.name} : {r.message}")
            elif now - entry.get("last_alert", 0.0) >= repeat_s:
                changes.append(f"[RAPPEL ] {r.category:<7} {r.name} : {r.message}")
            state[key] = {"status": r.status,
                          "last_alert": now if (prev == OK or now - entry.get("last_alert", 0.0) >= repeat_s)
                          else entry.get("last_alert", 0.0),
                          "since": entry.get("since", now)}
        else:
            if prev != OK:
                changes.append(f"[RÉTABLI] {r.category:<7} {r.name} : {r.message}")
            state[key] = {"status": OK, "last_alert": 0.0, "since": now}

    save_state(state_file_path(cfg, config_path), state)

    webhook = cfg.get("webhook") or {}
    url = webhook.get("url") or ""
    if changes:
        for line in changes:
            log.warning("Alerte : %s", line)
        if url:
            stamp = datetime.now().strftime("%Y-%m-%d %H:%M")
            try:
                host = socket.gethostname()
            except OSError:
                host = "?"
            send_webhook(url, f"admin-toolkit — {stamp} ({host})\n" + "\n".join(changes),
                         float(webhook.get("timeout", 10)))


# ---------------------------------------------------------------------------
# Affichage console
# ---------------------------------------------------------------------------
def print_results(results, use_color: bool, duration: float, quiet: bool, log_file: str) -> None:
    counts = {s: sum(1 for r in results if r.status == s) for s in (OK, WARN, CRIT)}
    if quiet:
        # mode cron : n'afficher que les problèmes (utile pour un mail cron)
        for r in results:
            if r.status != OK:
                print(f"[{r.status}] {r.category} {r.name} : {r.message}")
        return

    width = max([len(r.name) for r in results] + [10], default=10)
    print(f"Contrôle de santé — {datetime.now():%Y-%m-%d %H:%M:%S}")
    for r in results:
        line = f"[{r.status:^4}] {r.category:<8} {r.name:<{width}}  {r.message}"
        if use_color:
            line = _COLORS[r.status] + line + _RESET
        print(line)
    bilan = f"Bilan : {counts[OK]} OK · {counts[WARN]} WARN · {counts[CRIT]} CRIT — {duration:.1f} s"
    if use_color:
        worst = worst_status(results)
        bilan = _COLORS[worst] + bilan + _RESET
    print(bilan)
    if log_file:
        print(f"(log : {log_file})")


# ---------------------------------------------------------------------------
# Exécution
# ---------------------------------------------------------------------------
CHECK_MAP = (
    ("http", check_http),
    ("tcp", check_tcp),
    ("certificates", check_cert),
    ("disks", check_disk),
    ("services", check_service),
)


def run_all_checks(cfg) -> list:
    results = []
    for section, fn in CHECK_MAP:
        for spec in cfg.get(section) or []:
            try:
                results.append(fn(spec))
            except Exception as exc:  # sécurité : une vérification ne plante jamais la passe
                results.append(CheckResult(section.upper(), str(spec.get("name", spec)), CRIT,
                                           f"erreur interne : {exc}"))
    return results


def run_once(cfg, config_path, args) -> int:
    start = time.monotonic()
    results = run_all_checks(cfg)
    if not results:
        log.error("Aucune vérification configurée (http, tcp, certificates, disks, services)")
        print("ERREUR : aucune vérification configurée dans %s" % config_path, file=sys.stderr)
        return 3

    for r in results:
        log.log(_LEVEL[r.status], "%-4s %-8s %s : %s", r.status, r.category, r.name, r.message)

    process_alerts(results, cfg, config_path)

    log_file = resolve_path(cfg.get("log_file") or "", config_path)
    print_results(results, use_color=args.color, duration=time.monotonic() - start,
                  quiet=args.quiet, log_file=log_file)
    return _SEVERITY[worst_status(results)]


def main() -> int:
    # Sortie console en UTF-8 (sinon les accents partent en cp1252 sous Windows
    # dès que la sortie est redirigée ; sans effet sous Linux)
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(encoding="utf-8", errors="replace")
        except (AttributeError, OSError):
            pass

    parser = argparse.ArgumentParser(
        prog="healthcheck.py",
        description="Contrôle de santé périodique : HTTP, TCP, certificats, disques, services.",
        epilog="Codes retour : 0 OK · 1 avertissement · 2 critique · 3 erreur de configuration",
    )
    parser.add_argument("-c", "--config", default=DEFAULT_CONFIG,
                        help="chemin du fichier de configuration JSON (défaut : %(default)s)")
    parser.add_argument("--log-file", help="force le fichier de log (surcharge la config)")
    parser.add_argument("--loop", type=int, metavar="SEC",
                        help="exécution périodique : une passe toutes les SEC secondes")
    parser.add_argument("-q", "--quiet", action="store_true",
                        help="n'affiche que les problèmes (mode cron)")
    parser.add_argument("--no-color", dest="color", action="store_false",
                        help="désactive les couleurs console")
    parser.add_argument("--init", action="store_true",
                        help="crée healthcheck.json depuis l'exemple (si absent)")
    parser.add_argument("--version", action="version", version=f"%(prog)s {VERSION}")
    args = parser.parse_args()

    args.color = args.color and sys.stdout.isatty()
    if args.color and os.name == "nt":
        os.system("")  # active les séquences ANSI sous Windows

    if args.init:
        if os.path.exists(args.config):
            print(f"La configuration existe déjà : {args.config}")
            return 0
        if not os.path.exists(EXAMPLE_CONFIG):
            print(f"Exemple introuvable : {EXAMPLE_CONFIG}", file=sys.stderr)
            return 3
        import shutil as _sh
        _sh.copyfile(EXAMPLE_CONFIG, args.config)
        print(f"Configuration créée : {args.config} — adaptez-la puis relancez le contrôle.")
        return 0

    try:
        cfg = load_config(args.config)
    except (FileNotFoundError, ValueError) as exc:
        print(f"ERREUR : {exc}", file=sys.stderr)
        return 3

    if args.log_file:
        cfg["log_file"] = args.log_file
    setup_logging(resolve_path(cfg.get("log_file") or "", args.config) or None)

    if args.loop and args.loop > 0:
        print(f"Mode périodique : une passe toutes les {args.loop} s (Ctrl+C pour arrêter)")
        code = 0
        try:
            while True:
                code = run_once(cfg, args.config, args)
                time.sleep(args.loop)
        except KeyboardInterrupt:
            print("\nArrêt.")
        return code

    return run_once(cfg, args.config, args)


if __name__ == "__main__":
    sys.exit(main())
