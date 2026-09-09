# Multicluster Workshop

Ein Deployment-Workflow, der aus einem privaten GitHub-Repo per GitHub
Actions ein Container-Image baut, nach GHCR pusht und anschließend auf
mehreren heterogenen Zielsystemen ausrollt (zwei Docker-Cluster + LUIS via
Apptainer).

## Architektur

```
                       GitHub
                         │
                    privates Repo
                         │
              ┌──────────┴──────────┐
              │                     │
        Build Docker Image      Source Code
              │                     │
              ▼                     │
            GHCR                    │
      ghcr.io/org/project           │
              │                     │
        ┌─────┼──────────┐          │
        ▼     ▼          ▼          │
 Cluster A  Cluster B    LUIS ◄─────┘
 Docker     Docker     Apptainer
```

## Repo-Struktur

```
multicluster-workshop/
├── .github/workflows/
│   ├── deploy.yml          # workflow_dispatch, Cluster-Auswahl, Build + Deploy
│   └── health.yml          # geplanter/manueller Verify-Lauf ohne Deploy
├── config/
│   └── clusters.json       # zentrale Cluster-Definition (Name, Typ, Host, ...)
├── scripts/
│   ├── deploy.sh           # ./deploy.sh <cluster-name> <image-tag>
│   ├── verify.sh           # Soll/Ist-Vergleich über alle Cluster
│   ├── create-deployment-info.sh
│   ├── preflight.sh        # lokale Tools + SSH-Erreichbarkeit prüfen
│   └── sync.sh             # optionaler rsync von src/ (getrennt vom Image-Deploy)
├── cluster-config/
│   ├── local-docker.sh     # generisches lokales Test-Zielsystem (sshd + docker)
│   ├── cluster-a-docker.sh # Cluster-A-Stand-in lokal starten
│   └── luis-apptainer.sh   # Pull+Run gegen ein echtes Apptainer-System testen
├── src/hello.py
├── deploy.sh                # Wrapper -> scripts/deploy.sh (für `./deploy.sh ...`)
├── version.txt
├── requirements.txt
└── Dockerfile
```

Hinweis: aus dem ursprünglichen Diagramm wurde `cluster config/` zu
`cluster-config/` (kein Leerzeichen im Verzeichnisnamen).

## Vorbereitung

1. **Workshop-Repo**: dieses Repo als privates GitHub-Repo anlegen/pushen.
2. **Runner vorbereiten**: dedizierter GitHub-Actions-Runner (self-hosted
   oder GitHub-hosted, siehe Sicherheitsabschnitt), Zugriff auf `docker`,
   `jq`, `ssh`, `rsync`.
3. **Zielsysteme vorbereiten** – zwei lokale Docker-Container als Stand-in
   für Cluster A/B:
   ```
   ssh-keygen -t ed25519 -f ~/.ssh/id_cluster_a -N ""
   ./cluster-config/cluster-a-docker.sh ~/.ssh/id_cluster_a.pub
   # cluster-b analog: local-docker.sh cluster-b <port> <pubkey> kopieren/anpassen
   ```
   Runner-Zugriff auf die Container absichern (siehe unten).
4. `config/clusters.json` mit echten Hosts/Usern füllen.
5. **SSH testen**:
   ```
   ssh -p 2201 -i ~/.ssh/id_cluster_a deploy@127.0.0.1
   ./scripts/preflight.sh
   ```
6. **Platzhalter-Image** vor dem Split bereitstellen, damit Gruppe 1/3/4
   nicht auf Gruppe 2 warten müssen:
   ```
   docker build -t ghcr.io/<org>/<project>:dummy .
   docker push ghcr.io/<org>/<project>:dummy
   ```
7. Definition of Done pro Gruppe fixieren (siehe unten) – **vor** dem Split.
8. Gemeinsame Schnittstellen fixieren (siehe Tabelle unten) – **vor** dem Split.

### Sicherheit beim Runner-Zugriff auf die Zielsysteme

- SSH-Keys möglichst als **Deploy-Keys mit `command=`-Restriction** in
  `authorized_keys`, z. B.:
  ```
  command="/opt/workshop/bin/remote-deploy.sh",no-port-forwarding,no-X11-forwarding,no-agent-forwarding,no-pty ssh-ed25519 AAAA... deploy@runner
  ```
  `remote-deploy.sh` wertet `$SSH_ORIGINAL_COMMAND` aus und erlaubt nur eine
  feste Allowlist an Befehlen (pull/run des Images) statt freiem Shell-Zugriff.
- **GitHub Environments** mit Protection Rules pro Cluster (`cluster-a`,
  `cluster-b`, `luis`) statt eines repo-weiten Secrets – jedes Environment
  bekommt eigene `CLUSTER_SSH_KEY`/Zugangsdaten.
- Ein Runner mit Docker-Socket-Zugriff ist quasi root: wenn möglich
  **rootless Docker** verwenden, den Runner nicht mit anderen Workloads
  teilen.
- GHCR-Package **privat** halten, Pull-Token mit möglichst engem Scope
  (`read:packages` statt vollem PAT), Token nur über das jeweilige
  Environment einschleusen (`GHCR_PULL_TOKEN`).

## Gemeinsame Schnittstellen (vor dem Split fixiert)

| Was | Format/Konvention |
|---|---|
| Image-Naming | `ghcr.io/org/project:<git-sha>` |
| Cluster-Bezeichner | wie in `config/clusters.json`: `cluster-a`, `cluster-b`, `luis` |
| `deploy.sh` Aufruf | `./deploy.sh <cluster-name> <image-tag>` → Exit-Code 0/≠0 |
| `verify.sh` Aufruf | liest `config/clusters.json`, gibt Statustabelle + Exit-Code zurück |
| Deployment-Info-Format | JSON mit mind. `commit`, `image_tag`, `timestamp` (siehe `create-deployment-info.sh`) |

### Exit-Codes `deploy.sh`

| Code | Bedeutung |
|---|---|
| 0 | Erfolg |
| 1 | Usage-/Konfigurationsfehler lokal |
| 2 | unbekannter Cluster-Name/-Typ |
| 3 | Cluster nicht erreichbar |
| 4 | Remote-Befehl fehlgeschlagen |

### Digest vs. Tag

`verify.sh` vergleicht standardmäßig **Tags** (einfach, aber Tags sind
grundsätzlich veränderlich). Für eine belastbare Aussage "läuft wirklich
derselbe Code" zusätzlich den **Digest** vergleichen:

```
# Digest des gepushten Images ermitteln
docker buildx imagetools inspect ghcr.io/org/project:<sha>

# lokal gebautes Image per Digest referenzieren
docker inspect --format='{{index .RepoDigests 0}}' ghcr.io/org/project:<sha>
```

`create-deployment-info.sh` unterstützt optional `IMAGE_DIGEST`, um den
Digest mit ins Deployment-Info-JSON zu schreiben.

## Gruppenaufteilung

### Gruppe 1: GitHub Actions & Multi-Cluster Selection
Verantwortung: `workflow_dispatch`, Cluster-Auswahl (Checkboxen), Job-Conditions,
Zusammenfassung am Ende des Runs. Siehe `.github/workflows/deploy.yml`.

**Definition of Done**
- [ ] `workflow_dispatch` mit Inputs für Cluster-Auswahl (Cluster A/B, LUIS) ist definiert
- [ ] Input „Build container" (ja/nein) funktioniert unabhängig von der Cluster-Auswahl
- [ ] Pro Cluster ein Job mit `if:`-Condition, der nur bei Auswahl läuft
- [ ] Jobs rufen die Skripte der anderen Gruppen mit den abgestimmten Parametern auf
- [ ] Workflow läuft mindestens einmal End-to-End durch (auch mit Platzhaltern)
- [ ] Fehler in einem Cluster-Job blockiert nicht die anderen Cluster-Jobs
- [ ] Zusammenfassung am Ende zeigt Erfolg/Fehlschlag pro Cluster
- [ ] Keine Secrets im Klartext im Workflow-File; Environments/Secrets korrekt referenziert

### Gruppe 2: Containers & Reproducible Environments
Verantwortung: `Dockerfile`, Image-Tags, GHCR-Push, Container starten,
Docker ↔ Apptainer Unterschiede.

**Definition of Done**
- [ ] `Dockerfile` baut lokal fehlerfrei (`docker build .`)
- [ ] Image wird mit Git-SHA getaggt (`ghcr.io/org/project:<sha>`), nicht nur `latest`
- [ ] Push nach GHCR funktioniert aus der Action heraus
- [ ] Image ist per Digest referenzierbar, Auslesen dokumentiert
- [ ] Container lässt sich lokal starten, `hello.py` läuft sichtbar durch
- [ ] Kurzdoku: Docker ↔ Apptainer (mind. 3 Punkte: Daemon/root, Image-Format, Netzwerk/Namespaces)
- [ ] Beispielbefehl für GHCR → `.sif` (`apptainer pull docker://...`) dokumentiert
- [ ] Sichtbarkeit/Rechte des GHCR-Package geklärt (privat + welche Tokens dürfen pullen)

### Gruppe 3: Transport & Remote Execution
Verantwortung: `scripts/deploy.sh`, SSH, optional `scripts/sync.sh`.

**Definition of Done**
- [ ] SSH-Verbindung zu Cluster A und LUIS erfolgreich getestet (Key-based)
- [ ] `deploy.sh` mit klar dokumentierter Signatur `./deploy.sh <cluster-name> <image-tag>`
- [ ] Skript unterscheidet intern Docker (Cluster A/B) vs. Apptainer (LUIS) korrekt
- [ ] Pull + Run auf Zielsystem nachweisbar erfolgreich
- [ ] Exit-Code eindeutig (0 = Erfolg, ≠0 = Fehler)
- [ ] SSH-Zugriff eingeschränkt (`command=`-Restriction, kein voller Shell-Zugriff)
- [ ] Optional: `rsync` für Source-Sync funktioniert, sauber getrennt von Docker-Deploy
- [ ] Fehlerfälle behandelt: Cluster nicht erreichbar, Image nicht vorhanden

### Gruppe 4: Version Tracking & Verification
Verantwortung: `scripts/create-deployment-info.sh`, `scripts/verify.sh`.

**Definition of Done**
- [ ] `create-deployment-info.sh` erzeugt JSON mit Git-Commit, Image-Tag/Digest, Zeitstempel
- [ ] `verify.sh` liest pro Cluster den tatsächlich laufenden Image-Tag aus
- [ ] Vergleich Soll (aktueller Git-Commit) vs. Ist (pro Cluster) korrekt und lesbar
- [ ] Statusausgabe eindeutig: ✓ aktuell / OUTDATED / „nicht erreichbar" als dritter Zustand
- [ ] Skript funktioniert auch, wenn nur ein Teil der Cluster deployed wurde
- [ ] Exit-Code spiegelt Gesamtstatus wider
- [ ] Kurzdoku: wie wird „gleicher Code, gleiches Environment" geprüft (Tag- vs. Digest-Vergleich)

## Integration

Nach der Gruppenarbeit: gemeinsame Phase, in der alle vier Teile gegen den
echten Workflow (`deploy.yml`) integriert werden – jede Gruppe ersetzt ihren
Platzhalter durch die eigene Implementierung, danach ein End-to-End-Lauf
mit allen Clustern.

## Zeitplan

_TODO: Zeitplan für den Workshop-Tag ergänzen (Vorbereitung, Gruppenarbeit,
Integration, Abschluss)._
