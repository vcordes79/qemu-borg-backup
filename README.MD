# qemu-borg-backup

Sichert QEMU/KVM-VMs, LXC-Container und ausgewählte Verzeichnisse mit Borg, Restic oder beiden. VMs und Container werden dafür einmal eingefroren. Beide Backends schreiben denselben Stand, danach wird der Snapshot aufgelöst.

Der HTML-Bericht geht auf die Standardausgabe. Statusdateien liegen unter `/var/spool/borgbackup/<Repository>`. Ein zweiter Lauf wartet, solange `/var/lock/qemu-borg-backup.lock` gehalten wird.

## Aufruf

```bash
export BORG_PASSPHRASE='geheim'
export BORG_REPO='ssh://backup@backuphost/./repo'
export BACKUP_SSH_KEY=/root/.ssh/backup_ed25519

./borg-backup.sh
```

| Skript | Wirkung |
|---|---|
| `backup.sh` | Hauptprogramm. Ohne weitere Variablen läuft Borg. |
| `borg-backup.sh` | Ruft `backup.sh` auf. Gesetztes `BACKUP_RESTIC=y` bleibt wirksam. |
| `restic-backup.sh` | Nur Restic. |
| `qemu-backup.sh <vm>` | Eine VM, Backends wie in der Umgebung gesetzt. |
| `qemu-borg-backup.sh <vm>` | Eine VM, nur Borg. |
| `qemu-restic-backup.sh <vm>` | Eine VM, nur Restic. |
| `lxc-backup.sh <container>` | Ein Container, Backends wie in der Umgebung gesetzt. |
| `lxc-borg-backup.sh <container>` | Ein Container, nur Borg. |
| `lxc-restic-backup.sh <container>` | Ein Container, nur Restic. |

Argumente von `backup.sh`, `borg-backup.sh` und `restic-backup.sh` sind exakte VM-Namen. Ohne Argumente ermittelt das Skript die VMs selbst. Container und Dateiverzeichnisse bleiben davon unberührt.

Beide Backends gleichzeitig:

```bash
export BACKUP_BORG=y
export BACKUP_RESTIC=y
export BORG_PASSPHRASE='geheim'
export BORG_REPO='ssh://backup@backuphost/./repo'
export RESTIC_PASSWORD='geheim'
export RESTIC_REPOSITORY='sftp:backup@backuphost:/repo'
export BACKUP_SSH_KEY=/root/.ssh/backup_ed25519
./backup.sh
```

Fällt eines der beiden Backends aus, läuft das andere zu Ende. Der VM-Overlay wird danach zurückgeführt und der LXC-Snapshot gelöscht. Der Lauf endet dann mit Status 1. Status 0 ist Erfolg, Status 2 eine Warnung. Jeder andere Status ist ein Fehler.

## Ablauf

**VMs.** Ist die VM `paused` (suspended), wird sie mit `virsh resume` fortgesetzt. Ist sie `pmsuspended`, weckt `virsh dompmwakeup` sie auf. Nach dem Backup legt das Skript sie wieder in denselben Zustand. `virsh` legt einen externen Disk-only-Snapshot namens `borg.qcow2` an. Gesichert werden die darunterliegenden Images. Anschließend führt `blockcommit` den Overlay zurück. Schlägt der Snapshot fehl, fährt das Skript die VM herunter, wartet auf `shut off`, startet sie neu und versucht den Snapshot erneut, diesmal mit `--quiesce`, sobald der QEMU-Agent antwortet. Vor dem Snapshot geht ein TRIM an den Gast, außer der Name ist `pfsense` oder `opnsense`. Nach erfolgreichem Backup und Blockcommit setzt `virsh domtime` die Gastuhr. Image-Pfade, die `_backup` enthalten, werden mitgesnapshotet und zurückgeführt, aber nicht ins Archiv aufgenommen.

Kann `virsh list` die VM-Liste nicht lesen, bricht der Lauf ab. Dasselbe gilt für `lxc list`, wenn `lxc` installiert ist und `LXC_BACKUP=y`.

**LXC.** `lxc snapshot <container> borgbackup` friert den Container ein. Verschachtelte Btrfs-Subvolumes unter dem Snapshot werden entfernt, dann sichert das Backend das Snapshot-Verzeichnis, danach löscht `lxc delete` den Snapshot. Ist `LXC_STOP_MYSQL` gesetzt, wird vorher `service mysql stop` im Container ausgeführt und danach wieder gestartet.

**Verzeichnisse.** Jede Variable `BORG_DIRS_<Name>` ist eine Gruppe. Der Name nach dem Präfix wird der Archivname, Leerzeichen trennen die Pfade.

**Aufbewahrung.** Borg löscht alte Archive mit `borg prune` und dem Muster `name-JJJJ-MM-TTTHH:MM:SS`. Archive außerhalb dieses Musters bleiben liegen. Restic vergisst Schnappschüsse, die beide Tags `kind` und `name` tragen, und ruft danach einmal `restic prune` auf. `borg compact` läuft, wenn die installierte Borg-Version es anbietet.

VMs und Container werden bei einer Sperre bis zu `BORG_TRIES` Mal wiederholt, mit 60 Sekunden Pause. Dateibackups haben einen Versuch.

## Umgebungsvariablen

Werte außer `y` schalten eine Option aus, deren Beschreibung genau `y` verlangt. Leere Werte nutzen den genannten Standard.

### Backends

| Variable | Standard | Bedeutung |
|---|---|---|
| `BACKUP_BORG` | `y`, wenn `BACKUP_BORG` und `BACKUP_RESTIC` beide leer sind | `y` sichert mit Borg. Jeder andere gesetzte Wert schaltet Borg aus. |
| `BACKUP_RESTIC` | aus | `y` sichert mit Restic. |

### Borg

| Variable | Standard | Bedeutung |
|---|---|---|
| `BORG_REPO` | — | Borg-Repository. Pflicht, wenn Borg läuft. Beispiel: `ssh://backup@host/./repo` oder ein lokaler Pfad. |
| `BORG_PASSPHRASE` | — | Passphrase des Borg-Repositorys. Pflicht, wenn Borg läuft. |
| `BORG_EXCLUDE` | `--exclude */.btrfs --exclude */.snapshots` | Zusätzliche Argumente für LXC- und Dateibackups, an Leerzeichen getrennt. Beispiel: `--exclude /var/cache --exclude /tmp`. VM-Images erhalten diese Ausschlüsse nicht. |
| `BORG_TRIES` | `20` | Versuche für VM- und LXC-Backups. |
| `BORG_BREAK_LOCK` | an (leer oder `y`) | Leere exklusive Borg-Sperre wird mit `borg break-lock` entfernt, wenn kein Prozess `borg` läuft. Dieselbe Variable gilt für `restic unlock`. Jeder andere gesetzte Wert lässt Sperren stehen. |
| `BORG_RSH` | `ssh` | Von Borg selbst gelesen. `BACKUP_SSH_KEY` überschreibt diese Variable für die Dauer des Laufs. |

### Restic

| Variable | Standard | Bedeutung |
|---|---|---|
| `RESTIC_REPOSITORY` | — | Restic-Repository. Pflicht, wenn Restic läuft. SFTP-Beispiel: `sftp:backup@host:/repo`. Im Immutable-Modus: `rclone:user@host`, optional mit Port `rclone:user@host:23`. Ein Pfad hinter dem Host wird ignoriert, weil der Server den Repository-Pfad in der SSH-Beschränkung festlegt. |
| `RESTIC_PASSWORD` | — | Passwort des Restic-Repositorys. Pflicht, wenn Restic läuft. |
| `RESTIC_IMMUTABLE` | aus | `y` schaltet den Append-only-Zugriff ein. `forget`, `prune` und `unlock` entfallen. `KEEP_DAILY`, `KEEP_WEEKLY` und `KEEP_MONTHLY` gelten dann nur für Borg. |

Restic-Archive tragen die Tags `kind=vm`, `kind=lxc` oder `kind=dir` sowie `name=<Name>`. Der Hostname des Schnappschusses ist derselbe Name. `--compression max` wird gesetzt, wenn `restic backup --help` die Option enthält.

Im Immutable-Modus verbindet sich Restic per SSH mit dem Rclone-Backend. Auf dem Server beschränkt `authorized_keys` den Schlüssel auf Anhängen:

```
restrict,command="rclone serve restic --stdio --append-only /pfad/zum/repo" ssh-ed25519 AAAA...
```

Das Repository muss vorher mit einem Schlüssel ohne diese Beschränkung angelegt werden. `BACKUP_SSH_KEY` wird als `ssh -i` verwendet. Beispiel:

```bash
export BACKUP_RESTIC=y
export BACKUP_BORG=n
export RESTIC_IMMUTABLE=y
export RESTIC_PASSWORD='geheim'
export RESTIC_REPOSITORY='rclone:backup@backuphost'
export BACKUP_SSH_KEY=/root/.ssh/backup_ed25519
./restic-backup.sh
```

### SSH

| Variable | Standard | Bedeutung |
|---|---|---|
| `BACKUP_SSH_KEY` | SSH-Standardschlüssel | Pfad zum privaten Schlüssel. Borg ruft `ssh -i <Schlüssel> -o IdentitiesOnly=yes` auf. Bei einem Restic-Repository mit Präfix `sftp:` und im Immutable-Modus gilt derselbe Schlüssel. Die Datei muss existieren, lesbar sein und für Gruppe und Andere keine Rechte haben (Modus `600` oder `400`). |

### Aufbewahrung

| Variable | Standard | Bedeutung |
|---|---|---|
| `KEEP_DAILY` | `7` | Tägliche Archive, die behalten werden. Gilt für Borg und Restic. |
| `KEEP_WEEKLY` | `4` | Wöchentliche Archive. |
| `KEEP_MONTHLY` | `4` | Monatliche Archive. |
| `PRUNE_FIRST` | aus | Ein beliebiger nicht leerer Wert räumt zuerst auf und sichert danach. Sonst wird nach dem Backup aufgeräumt. |

### Speicherziel

Liegt das Repository auf einem Datenträger, der erst eingehängt werden muss:

| Variable | Standard | Bedeutung |
|---|---|---|
| `MOUNTPOINT` | leer | Einhängepunkt. Pflicht, sobald `FS_UUID` oder `NFS_PATH` gesetzt ist. |
| `FS_UUID` | leer | UUID eines lokalen Dateisystems. Es wird mit `mount UUID=…` eingehängt. |
| `NFS_PATH` | leer | NFS-Quelle, zum Beispiel `backuphost:/export/backup`. Eingehängt mit NFSv4.0. |

Ist der Einhängepunkt bereits belegt, hängt das Skript ihn aus und danach neu ein. Am Ende wird nur ausgehängt, was dieser Lauf eingehängt hat.

### Virtuelle Maschinen

| Variable | Standard | Bedeutung |
|---|---|---|
| `BACKUP_SHUTOFF` | aus | `y` nimmt auch ausgeschaltete VMs auf (`virsh list --all`). Sonst nur aktive VMs (`virsh list`), also laufende und angehaltene. |
| `DEFAULT_DOMAINS` | Ausgabe von `virsh list` | Leerzeichengetrennte VM-Namen. Argumente auf der Kommandozeile ersetzen diese Liste für den einen Lauf. |

### LXC

| Variable | Standard | Bedeutung |
|---|---|---|
| `LXC_BACKUP` | `y` | `y` sichert Container. Jeder andere gesetzte Wert überspringt LXC. |
| `LXC_CONTAINERS` | `lxc list --format=csv -c n` | Leerzeichengetrennte Containernamen. |
| `LXC_STORAGE_PATH` | `lxc storage get default source` | Speicherpfad des LXC-Pools. Ein vom Container genutzter Pool überschreibt den Pfad für diesen Container. |
| `LXC_STOP_MYSQL` | aus | Ein beliebiger nicht leerer Wert stoppt `mysql` im Container für den Snapshot und startet es danach. |

### Dateien

| Variable | Standard | Bedeutung |
|---|---|---|
| `BORG_DIRS_<Name>` | `BORG_DIRS_SYSTEM="/usr/local /etc"` | Verzeichnisse der Gruppe `<Name>`. Leerzeichen trennen die Pfade. `backup.sh` setzt `BORG_DIRS_SYSTEM` beim Start auf `/usr/local /etc`. Weitere Gruppen bleiben erhalten, zum Beispiel `BORG_DIRS_MY_HOST="/data/a /data/b"`. |

Pfade in `BORG_DIRS_*` und in `BORG_EXCLUDE` enthalten keine Leerzeichen. Sternchen in Pfaden bleiben wörtlich.
