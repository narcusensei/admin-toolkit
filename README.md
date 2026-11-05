# admin-toolkit

Trois outils d'administration + une console unique pour les piloter.

```
admin-toolkit/
├── admin.sh                     ← console (menu shell) — le point d'entrée
├── ad/
│   ├── New-ADUsersBulk.ps1      ← création de comptes AD en masse (PowerShell)
│   └── utilisateurs-modele.csv  ← modèle de fichier d'entrée
├── vps/
│   └── vps-maintenance.sh       ← maintenance périodique du VPS (Bash, Linux)
└── sante/
    ├── healthcheck.py           ← contrôle de santé (Python 3, sans dépendance)
    └── healthcheck.example.json ← configuration d'exemple
```

Démarrage rapide :

```bash
chmod +x admin.sh vps/vps-maintenance.sh sante/healthcheck.py
./admin.sh
```

---

## 1. Création de comptes AD en masse — `ad/New-ADUsersBulk.ps1`

**Prérequis** : Windows avec outils RSAT (module `ActiveDirectory`), exécuté avec
des droits suffisants pour créer des comptes dans l'OU cible.

```powershell
# Simulation d'abord (rien n'est créé)
.\New-ADUsersBulk.ps1 -CsvPath .\utilisateurs.csv -WhatIf

# Création réelle
.\New-ADUsersBulk.ps1 -CsvPath .\nouveaux.csv `
    -TargetOu "OU=Utilisateurs,DC=boite,DC=local" `
    -Company "Boite SARL"
```

**Uniformisation** : `Nom affiché = "Prenom Nom"`, `SamAccountName = prenom.nom`
(sans accents, 20 car. max, dédoublonné), `UPN = prenom.nom@suffixe`,
`Description = "Créé en masse le AAAA-MM-JJ - Département - Fonction"`.

**Mot de passe temporaire** (ordre de priorité) : colonne `MotDePasse` du CSV →
paramètre `-TempPassword` → généré aléatoirement (14 car., complexité AD garantie).
Le changement de mot de passe est **forcé à la première ouverture de session**
(désactivable avec `-NoChangeAtLogon`).

**CSV** : colonnes FR ou EN reconnues (`Prenom`/`FirstName`, `Nom`/`LastName`,
`SamAccountName`, `Departement`, `Fonction`, `OU`, `Email`, `MotDePasse`),
séparateur `,` ou `;` détecté automatiquement, encodage **UTF-8** recommandé.

**Rapport** : `rapport-creation-<date>.csv` listant créés / ignorés / échecs +
mots de passe temporaires. ⚠️ À transmettre par un canal sûr puis à supprimer.

Codes retour : `0` = OK · `2` = au moins un échec.

---

## 2. Maintenance du VPS — `vps/vps-maintenance.sh`

**Prérequis** : Linux, exécuté en root (le script se relance via `sudo` lui-même).

```bash
sudo ./vps-maintenance.sh                       # complet
sudo ./vps-maintenance.sh --service "bot,nginx" # services surveillés
sudo ./vps-maintenance.sh --dry-run             # simulation
sudo ./vps-maintenance.sh --no-update           # nettoyage + état seulement
sudo ./vps-maintenance.sh --prune-docker --restart-if-failed
```

Déroulé : **mise à jour** (apt/dnf/zypper/apk/pacman) → **nettoyage**
(autoremove, cache, journaux systemd réduits à 7 j, Docker en option opt-in) →
**état du/des service(s) bot** (dernières lignes de journal si anomalie,
redémarrage optionnel) → **instantané disque/mémoire/charge** + détection de
redémarrage requis. Résumé complet en fin d'exécution ; tout est journalisé
dans `/var/log/vps-maintenance.log` (rotation sommaire intégrée).

**Planification** (depuis la console `./admin.sh`, choix 5, ou à la main) :

```cron
0 4 * * 0 /bin/bash /opt/admin-toolkit/vps/vps-maintenance.sh --yes
```

Pour un cron utilisateur, autorisez le script sans mot de passe dans `sudoers`
(`sudo visudo`) :

```
votreluisateur ALL=(root) NOPASSWD: /opt/admin-toolkit/vps/vps-maintenance.sh
```

Codes retour : `0` = OK (avertissements possibles) · `1` = au moins une erreur.

---

## 3. Contrôle de santé — `sante/healthcheck.py`

**Prérequis** : Python 3.8+, aucune dépendance externe. Fonctionne sous Linux
et Windows.

```bash
python3 sante/healthcheck.py --init       # crée healthcheck.json depuis l'exemple
#  ... adapter les cibles dans sante/healthcheck.json ...
python3 sante/healthcheck.py              # une passe
python3 sante/healthcheck.py --loop 300   # une passe toutes les 5 minutes
python3 sante/healthcheck.py -q           # silencieux : seuls les problèmes (cron)
```

**Vérifications** : ping HTTP (code attendu, mot-clé, latence), port TCP,
expiration de certificat TLS (avertissement à J-30, critique à J-7 par défaut),
occupation disque, état de service (systemd / service Windows).

**Alertes** : log dédié `sante/logs/healthcheck.log` avec rotation ; webhook
optionnel (Slack / Discord / Teams) déclenché **au changement d'état** (pas de
spam) avec rappel configurable tant que l'anomalie persiste.

**Planification** :

```cron
*/15 * * * * /usr/bin/python3 /opt/admin-toolkit/sante/healthcheck.py \
    --config /opt/admin-toolkit/sante/healthcheck.json --quiet
```

Codes retour : `0` OK · `1` avertissement · `2` critique · `3` erreur de config.

---

## 4. La console — `admin.sh`

Un menu shell unique qui détecte l'environnement (Linux / Windows / macOS, Python,
PowerShell, cron) et n'affiche que ce qui est utilisable :

1. lancer un contrôle de santé,
2. consulter le log santé,
3. lancer la maintenance VPS (Linux),
4. lancer la création AD en masse avec saisie guidée (Windows),
5. installer / 6. retirer la planification cron (entrées balisées `admin-toolkit`).

---

## Notes de sécurité

- Le rapport AD contient les **mots de passe temporaires** : canal sûr + suppression.
- Principe de moindre privilège : un compte délégué à l'OU cible suffit pour l'AD
  (pas besoin d'administrateur du domaine).
- Le webhook envoie le nom des services/endpoints : pensez-y si les noms sont sensibles.
- `--prune-docker` ne touche jamais aux volumes (données), uniquement conteneurs
  arrêtés / images non étiquetées / réseaux inutilisés.
