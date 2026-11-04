# Problem 2: Diagnose Me Doctor

An Ubuntu 24.04 VM running only NGINX as a load balancer reports its root disk at 99%. This runbook keeps it serving, copies evidence before freeing anything, reclaims what is safe to drop, then follows a fixed order of checks to one of seventeen causes. [`diagnose-disk.sh`](diagnose-disk.sh) runs the read-only checks in one pass; [`tests/rotate-check.sh`](tests/rotate-check.sh) proves that the packaged rotation makes NGINX reopen its logs.

## Contents

- [Scope](#scope)
- [Decisions](#decisions)
- [What a full disk does to the load balancer](#what-a-full-disk-does-to-the-load-balancer)
- [First 15 minutes: keep it serving](#first-15-minutes-keep-it-serving)
- [Investigation](#investigation)
- [Root causes](#root-causes)
- [Prevention and monitoring](#prevention-and-monitoring)

## Scope

### In scope

- **The alert**: `/` at 99% on one VM whose only workload is NGINX.
- **Keeping it serving**: what fails, what to free first, how to buy headroom.
- **Finding the cause**: ordered checks and the causes they lead to.
- **Not recurring**: alerts and configuration.

### Out of scope

- **Other workloads on the VM**: the check order still applies.
- **Provider tooling**: resize, snapshot, draining and volume health, named by function.
- **The fleet**: log pipeline and retention beyond this VM.
- **Other filesystems**: XFS and Btrfs, except where they differ from ext4.

### Assumptions

- **One scenario**: the task names "two production issues" but describes one.
- **One ext4 root, sized here at 64 GB**: a cloud image root spans the disk and reserves nothing (`tune2fs -l`: `Reserved block count: 0`); the Ubuntu Server installer puts `/` on LVM at half the volume group and reserves 5%.
- **The Ubuntu NGINX package**: 1.24, logs in `/var/log/nginx`, temp files in `/var/lib/nginx`, workers as `www-data`, 14 daily rotations.
- **A systemd service**: in Docker, the unbounded `json-file` log under `/var/lib/docker/containers/` is the first suspect.
- **journald on disk, forwarding to rsyslog**: `ForwardToSyslog=yes` in `/usr/lib/systemd/journald.conf.d/syslog.conf`.
- **Unknowns**: whether a shipper runs and whether another node can take this one's traffic.

## Decisions

| # | Decision | Alternatives considered | Why | Revisit when |
|---|---|---|---|---|
| 1 | Copy a tail of each deleted-but-open file before freeing space | Free first | `reopen`, truncate or a shipper restart discards the file | A shipper confirms delivery |
| 2 | Truncate an open log, never `rm` it | `rm` and restart | `rm` frees nothing while a descriptor is open | Never, for a held file |
| 3 | `nginx -s reopen`, not `systemctl restart nginx` | Restart; `reload` | `reopen` drops no connection; a stop cuts transfers at 5 seconds (`--retry QUIT/5`) | The master is wedged |
| 4 | Cap the journal with `SystemMaxUse=` | `ForwardToSyslog=no`; lower `MaxRetentionSec=` | Bounds the disk whatever a unit logs | A shipper reads the journal, so rsyslog's copy can go |
| 5 | `proxy_cache_path` with `max_size`, `min_free`, `inactive` | A cron purge | The cache manager evicts in-process; a purge job races it | The cache has its own volume |
| 6 | Separate volumes for `/var/log`, `/var/cache/nginx` and `/var/lib/nginx` | A larger root; quotas | A flood stops there; apt, sshd and `/` keep working | Logs leave at once |
| 7 | Ship logs off the VM, keep 48 hours locally | 14 days local | 14 days at 1,000 requests per second is 61 GB | 14 days fits in half the disk |
| 8 | Alert on time to full and available bytes | 90% and 95% thresholds | 18.6 GB a day fills 64 GB from 85% in 12 hours | 5% exceeds a day of growth |
| 9 | `tune2fs -m 1` as a bridge, `-m 5` after the fix | Leave 1%; never touch it | About 2.6 GB on 64 GB | The root reserves nothing |

## What a full disk does to the load balancer

Workers run as `www-data` and get `ENOSPC` (`28: No space left on device`) once `df` shows `Avail` 0; root processes keep writing into the reserve where one exists. At 99% the workers have about 0.6 GB left on 64 GB; at 1,000 requests per second with 215-byte `combined` lines the access log writes 18.6 GB a day and uses that in about 45 minutes. Observed on a full filesystem:

| Path | Disk use | On a full disk |
|---|---|---|
| Request within memory buffers | None | Served |
| Body above `client_body_buffer_size` (8 KB on x86-64) | `client_body_temp_path` | `500 Internal Server Error`; `[crit] pwrite() "/var/lib/nginx/body/0000000002" failed (28: No space left on device)` |
| Response above `proxy_buffers` (8 × 4 KB or 8 KB) to a slow client | `proxy_temp_path`, up to `proxy_max_temp_file_size` (1024 MB) per request | 200 and headers, then the connection closes mid-body (3.4 MB of 64 MB at 2 MB/s, `curl` exit 18); `[crit] pwritev()` with errno 28 |
| `proxy_cache` hit | Read only | Served |
| `proxy_cache` miss | A temp file into the cache | `curl: (52) Empty reply from server`; `[crit] pwrite()` with errno 28 |
| Access or error log line | Append | Served, line lost; `[alert] write() to "/var/log/nginx/access.log" failed (28: ...)` at most once a minute per worker |
| `nginx -t`, `-s reload`, `-s reopen` | By the master, as root | Succeeded |
| Health check in front | A small proxied request | Passes, so the node stays in rotation while uploads and cache misses fail |
| logrotate | gzip writes the `.gz` first | `gzip: stdout: No space left on device`, exit 1, nothing freed |
| rsyslog | `$PrivDropToUser syslog` | `/var/log/syslog` and `/var/log/auth.log` stop with the workers |
| apt, unattended-upgrades | Downloads and unpacks | Security updates stop |

## First 15 minutes: keep it serving

Run these commands one at a time in an interactive root shell (`du` and `/proc/<pid>/fd` are partial otherwise), not as a script: under `set -e` a `grep` that matches nothing ends it.

### Confirm what is full and whether NGINX still serves

```bash
df -hT /                     # available excludes root's reserve
df -i /                      # above 90% with bytes free: inode exhaustion
dmesg -T | tail -n 20        # "EXT4-fs error", "I/O error", "Remounting filesystem read-only": a disk fault
findmnt -n -o OPTIONS /      # "ro," first: the kernel remounted / read-only
systemctl is-active nginx
curl -sS -o /dev/null -w '%{http_code}\n' http://127.0.0.1/<health-path>
tail -n 100000 /var/log/nginx/error.log | grep -E '\[(crit|alert)\].*(No space left|Read-only file system)' | tail -n 5
```

A passing health check proves only the in-memory path. `crit` lines with errno 28 mean uploads and cache misses already fail; their absence proves nothing, because `error.log` sits on the full disk.

- **Read-only or disk errors**: free nothing; follow the I/O fault row under Less common causes.
- **Inodes above 90%**: go to Inode exhaustion.
- **A possible intrusion** (an unknown file or writer): snapshot the volume first.
- **Another node can carry the traffic**: take this one out of rotation now; its health check keeps passing. A sole load balancer keeps serving.

### Copy evidence before freeing anything

```bash
# 1. Deleted-but-open files, with holder, inode and size
find /proc/[0-9]*/fd -lname '*(deleted)' -printf '%p -> %l\n' 2>/dev/null
stat -L -c 'inode %i, %s bytes' /proc/<pid>/fd/<n>
# 2. A target off /: another host, another mount, or /dev/shm (RAM)
grep MemAvailable /proc/meminfo  # tails kept in /dev/shm must total well below this
df -h /dev/shm               # half of RAM by default
mkdir -p /dev/shm/evidence
printf '%s pid=%s fd=%s inode=%s size=%s\n' "$(date -Is)" <pid> <n> <inode> <size> >> /dev/shm/evidence/index.txt
# 3. A bounded tail, straight off the box or locally
tail -c 200M /proc/<pid>/fd/<n> | ssh <user>@<collector> 'cat > /srv/evidence/<host>-<pid>-<n>.tail'
tail -c 200M /proc/<pid>/fd/<n> > /dev/shm/evidence/<pid>-<n>.tail
# 4. Only then release the file
nginx -s reopen
```

`/dev/shm` files hold RAM that NGINX needs until deleted and vanish at reboot: prefer the `ssh` stream and move local copies off the VM within the hour.

### What not to do

- **`rm` on an open log**: it frees nothing while NGINX holds the descriptor, and the `nginx -s reopen` that releases it recreates the log as 0644 instead of logrotate's 0640.
- **Clearing `/var/lib/nginx/body` or `/var/lib/nginx/proxy`**: NGINX unlinks each temp file on creation, so deleting there frees nothing.
- **Hand-deleting under `/var/lib/dpkg`, `/var/lib/apt`, `/boot` or `/var/log/journal`**: use `apt autoremove --purge` and `journalctl --vacuum-size`.
- **`mount -o remount,rw /` after the kernel set it read-only**: new writes spread the damage of the I/O or filesystem error behind it; snapshot, then `fsck.ext4 -f` from a rescue boot.

### Reclaim space that is safe to drop

Free space in this order, least costly first, and check `df -h /` after each step. Stop once `Avail` exceeds 5% of the filesystem, the critical alert level. If two `df -B1 --output=avail /` readings a minute apart still fall, a writer is live: run the Investigation before freeing more.

| # | Action | Command | Frees | Cost |
|---|---|---|---|---|
| 1 | Release deleted logs | `nginx -s reopen` | Deleted logs NGINX holds | Hand-removed logs return as 0644 |
| 2 | Drop downloaded packages | `apt-get clean` | `/var/cache/apt/archives` | A later download |
| 3 | Trim the journal | `journalctl --vacuum-size=500M` | Archived journals beyond 500 MB | Older system logs |
| 4 | Empty a held deleted log | `: > /proc/<pid>/fd/<n>`, for a log only, never an NGINX temp file of an in-flight request | Its blocks | Its content |
| 5 | Remove rotated logs beyond 48 hours | Ship them, then `find /var/log/nginx -name '*.gz' -mmin +2880 -delete` | Logs beyond the target | None once shipped |
| 6 | Empty the growing live log | `tail -n 200000 <log> > /dev/shm/evidence/<name>.tail`, then `truncate -s 0 <log>`; `<log>` is `access.log`, or `access.log.1` when NGINX never reopened | The whole file | Its content |
| 7 | Shrink an oversized cache | Lower `max_size` in `proxy_cache_path`, then `nginx -t && nginx -s reload` | Cache above the limit | Hit ratio |

### Buy headroom if that is not enough

- **Lend the reserve**: `tune2fs -m 1 "$(findmnt -n -o SOURCE /)"` frees about 2.6 GB on 64 GB while mounted; restore `-m 5` after the fix. A cloud image root has none to lend.
- **Extend the root logical volume**: when `vgs` shows `VFree`, `lvextend -r -L +10G /dev/ubuntu-vg/ubuntu-lv` grows the volume and its ext4 while mounted.
- **Grow the volume online**: resize the volume, then `TMPDIR=/dev/shm growpart /dev/<disk> <partition-number>` (its working directory defaults to `/tmp`, on the full root) and `resize2fs /dev/<root-partition>`; on LVM, `pvresize /dev/<partition>` and `lvextend -r` replace `resize2fs`. Skip the resize when `lsblk` already shows the disk larger than its partition.

## Investigation

Run the checks in order and stop at the first whose finding accounts for the used bytes. `diagnose-disk.sh` runs them all under timeouts, `du` and `find` at idle I/O priority, and exits 1 when a collector could not run:

```bash
sudo ./diagnose-disk.sh / > /dev/shm/disk-report.txt
```

```mermaid
flowchart LR
  a["`**Alert: / at 99%**
differs from df: the monitor's formula or mount`"] --> b{"`**dmesg, mount options**
error or ro?`"}
  b -- yes --> fault["`**I/O fault or read-only remount**`"]
  b -- no --> c{"`**df -i /**
inodes above 90%?`"}
  c -- yes --> inodes["`**Inode exhaustion**`"]
  c -- no --> d{"`**df used vs du -sx /**
gap?`"}
  d -- yes --> e["`**Space du cannot see**
deleted-but-open files
files under a mount point`"]
  d -- no --> f["`**du -x by directory**
/var/log/nginx
cache and temp paths
journal and syslog
apt, snaps, /var/crash
shipper data, stray files`"]
  a --> g{"`**lsblk, vgs**
space outside /?`"}
  g -- partition --> grow["`**Partition never grown**`"]
  g -- volume group --> lv["`**Root logical volume never extended**`"]
```

1. `lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINTS; vgs`: a disk larger than its partition means the partition was never grown, and `VFree` means the root logical volume was never extended.
2. `df -B1 --output=used /; ionice -c3 du -sxB1 / 2>/dev/null`: a gap of hundreds of MB is deleted-but-open files or files hidden under a mount point.
3. `find /proc/[0-9]*/fd -lname '*(deleted)' -printf '%p -> %l\n' 2>/dev/null`, or `lsof -nP +L1`: the deleted files and their holders.
4. `ionice -c3 du -xh --max-depth=1 / 2>/dev/null | sort -h`, then `ionice -c3 du -xh --max-depth=2 /var 2>/dev/null | sort -h | tail -n 20`: with no gap, the largest directory locates the growth.
5. `ionice -c3 find / -xdev -type f -size +500M -printf '%s\t%t\t%p\n' 2>/dev/null | sort -n` and `ionice -c3 find / -xdev -type f -mmin -15 -size +10M -printf '%s\t%p\n' 2>/dev/null`: large files and live writers.
6. `nginx -T 2>/dev/null | grep -nE 'access_log|error_log|proxy_cache_path|_temp_path|proxy_max_temp_file_size|proxy_buffering'`: `error_log ... debug` is debug logging, `proxy_cache_path` without `max_size` is an unbounded cache, and temp paths on `/` share the root disk.
7. `ls -lhS --time-style=long-iso /var/log/nginx`: an empty `access.log` beside a large, current `access.log.1` means NGINX did not reopen after rotation; all 14 rotations present means retention outgrew the disk; none means logrotate skips NGINX.
8. `logrotate -d /etc/logrotate.conf 2>&1 | grep -iE '^error|ignoring'; systemctl list-timers logrotate.timer; journalctl -u logrotate.service --since=-3d -p warning --no-pager; grep nginx /var/lib/logrotate/status`: an `Ignoring nginx` error, a failed run, a disabled timer or an old `nginx` entry means logrotate skips NGINX.
9. `journalctl --disk-usage; ls -lhS /var/log | head`: a journal near its cap or a large `/var/log/syslog` means journald and rsyslog store the same logs twice.
10. `du -sh /var/cache/apt/archives /boot /var/lib/snapd/snaps; dpkg -l 'linux-image-[0-9]*' | grep '^ii'; snap list --all | grep disabled`: old kernels, a large apt cache or disabled snaps are upgrade leftovers.

## Root causes

### Retention outgrew the disk

`/etc/logrotate.d/nginx` keeps 14 rotated files beside the live log, the newest uncompressed (`delaycompress`): at 1,000 requests per second, two uncompressed days plus 13 compressed at 10:1 come to 37 + 24 = 61 GB, the whole disk.

- **Confirm**: `/var/log/nginx` largest, all 14 rotations present, a daily sawtooth.
- **Impact**: uploads return 500, downloads truncate and cache misses get no reply, while the health check passes.
- **Recovery**: ship, then delete the oldest `.gz` files, then lower `rotate`.
- **Prevention**: `hourly` and `rotate 48` in `/etc/logrotate.d/nginx`, logrotate on an hourly timer, and older logs shipped off the VM.

### logrotate skips NGINX

Silent failures: a group- or world-writable config file (`error: Ignoring nginx because it is writable by group or others`, yet `Result=success`), a syntax error under `/etc/logrotate.d`, or a disabled `logrotate.timer`.

- **Confirm**: a steady climb; no rotated files, or an old `nginx` entry in `/var/lib/logrotate/status`.
- **Impact**: the access log grows until the disk fills.
- **Recovery**: `chmod 0644 /etc/logrotate.d/nginx` or `systemctl enable --now logrotate.timer`, then `logrotate -v /etc/logrotate.conf`.
- **Prevention**: alert on `error:` lines from `logrotate.service` and on the status entry's age.

### Rotated logs not reopened

The packaged postrotate, `invoke-rc.d nginx rotate >/dev/null 2>&1`, sends `USR1` to the pid file named in `/etc/nginx/nginx.conf` and fails silently when that differs from the running master's: logrotate moves `access.log` to `.1` and creates an empty one, NGINX keeps writing to `.1`, and `.1` grows without limit while logrotate exits 0. [`tests/rotate-check.sh`](tests/rotate-check.sh) reproduces both outcomes in a container: new inodes with the packaged config, a 0-byte `access.log` without `postrotate`.

- **Confirm**: `access.log` empty while `access.log.1` grows, or NGINX holds a deleted log.
- **Impact**: `.1` grows until the disk fills, and recent lines sit in `access.log.1` or a deleted file that a restart discards.
- **Recovery**: copy the evidence, then `kill -USR1 "$(pgrep -f '^nginx: master')"`, since `nginx -s reopen` reads the same wrong pid file; then correct that pid file.
- **Prevention**: after a unit, pid path or logrotate change, force one rotation on the VM (`logrotate -f /etc/logrotate.d/nginx`) and check that `access.log` grows and no deleted NGINX log remains; `tests/rotate-check.sh` covers only the packaged configuration. Alert on deleted-but-open bytes.

### Root logical volume never extended

The Ubuntu Server installer's default layout sizes `ubuntu-lv` at half of `ubuntu-vg` for volume groups of 20 to 200 GiB, so a 64 GB VM fills a 30 GB root while about 30 GB sit unallocated.

- **Confirm**: `df -h /` shows about 30 GB on a 64 GB disk; `vgs` shows about 30 GB `VFree`.
- **Impact**: a full root at half the planned size, filling twice as fast.
- **Recovery**: `lvextend -r -L +10G /dev/ubuntu-vg/ubuntu-lv`, online; extend further at the capacity review.
- **Prevention**: size the root logical volume at build time; compare `vgs` with `df -h /` after each install.

### Unbounded proxy cache

Without `max_size` or `min_free` (NGINX 1.19.1 and later) the cache manager removes only entries unused for `inactive` (10 minutes by default), so a long `inactive` lets the cache take the disk.

- **Confirm**: flat near 99%; the cache path is largest; `nginx -T` shows no `max_size`.
- **Impact**: misses get no response while hits work: failures look random by URL.
- **Recovery**: `max_size` and `min_free` below what the disk holds, then reload.
- **Prevention**: `inactive` with `max_size` and `min_free`, so the cache manager evicts in-process; the cache on its own volume; `use_temp_path=off`.

### Temp files for uploads and downloads

Large upload bodies and responses that outrun a slow client spill to `client_body_temp_path` and `proxy_temp_path`. NGINX unlinks these files on creation, so `du /var/lib/nginx` shows nothing while the `/proc` scan does: `/var/lib/nginx/proxy/0000000009 (deleted)` at 60 MB during one slow download.

- **Confirm**: spikes that recover; workers hold deleted `body/` or `proxy/` files.
- **Impact**: transient alone; near full, 500s on uploads and truncated downloads.
- **Recovery**: the space returns when the requests finish.
- **Prevention**: `proxy_request_buffering off` on upload routes; a lower `proxy_max_temp_file_size`; temp paths on a separate volume.

### Journal and syslog

journald caps itself at 10% of the filesystem or 4 GB (`SystemMaxUse=`), but forwards every entry to rsyslog, which writes it again to `/var/log/syslog`, rotated weekly with 4 files kept and no size limit (`/etc/logrotate.d/rsyslog`).

- **Confirm**: `/var/log/journal` or `/var/log/syslog` large; one unit dominates the journal.
- **Impact**: rsyslog stops with the workers, so the incident's own logs are lost.
- **Recovery**: `journalctl --vacuum-size=500M`; `truncate -s 0 /var/log/syslog` (rsyslog holds it open).
- **Prevention**: `SystemMaxUse=1G` in a journald drop-in, plus `maxsize` on the rsyslog files.

### Inode exhaustion

ext4 fixes the inode count at `mkfs` time (one per 16 KB by default, about 4 million on 64 GB); millions of small files exhaust it, and creation fails with errno 28 while `df -h` shows free space. It explains a 99% alert only when the monitor reports inode use.

- **Confirm**: `df -i` near 100% while `df -h` shows free space.
- **Impact**: appends continue; new temp files, cache entries and rotated logs fail.
- **Recovery**: count entries per directory without a temporary file, `find / -xdev -printf '%h\n' | awk '{ c[$0]++ } END { for (d in c) print c[d], d }' | sort -n | tail`; for the NGINX cache, lower `max_size` and reload; elsewhere, delete only files whose owner is known.
- **Prevention**: alert on inode use; `mkfs.ext4 -i 4096` or XFS for a cache volume.

### The monitor versus `df`

`df` computes `Use%` as used ÷ (used + available), excluding the reserve, so its 100% is the workers' zero; a monitor using used ÷ size reads about 5 points lower, and one without a filesystem filter may report `/boot`, or a snap's squashfs mount, which always reads 100%.

- **Confirm**: the alert's number differs from `df`, or names another mount.
- **Impact**: none off `/`; on `/`, 99% is about 0.6 GB from errno 28.
- **Recovery**: `tune2fs -m 1` where a reserve exists; correct the monitor's mount and formula.
- **Prevention**: alert on available bytes and time to full, squashfs and tmpfs excluded.

### Less common causes

| Cause | Confirm | Recover | Prevent |
|---|---|---|---|
| Debug error logging, about 13 KB per proxied request | `error.log` outgrows `access.log` | Level back to `error`, reload, truncate | `debug_connection <client-ip>;` for one client |
| Apt cache, old kernels, snap revisions | `/var/cache/apt/archives`, `/boot` or `/var/lib/snapd/snaps` large after upgrades | `apt-get clean`; `apt autoremove --purge`; `snap remove <name> --revision=<rev>` | `APT::Periodic::CleanInterval "7";`, `Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";`, `snap set system refresh.retain=2` |
| Crash dumps | `/var/crash` or `/var/lib/apport/coredump` growing; `core_pattern` names the handler | Copy one report off the VM, delete the rest, fix the crash | apport, the default: a size alert on both directories; systemd-coredump: `MaxUse=1G` in a `coredump.conf` drop-in |
| A log shipper buffering while its destination is down | Output errors; a growing data directory | Restore the destination, or copy the evidence and restart it | A buffer limit inside a disk budget |
| A stray large file | `find -size +500M`; `lsof <path>` shows a live writer | Stop the writer; move the file off the VM or delete it after a snapshot | Ring-buffer captures (`tcpdump -C 100 -W 10`) |
| Files hidden under a mount point | `df` used exceeds the `du` total with no deleted-open files | `mount --bind / /mnt/rootfs`, delete through it | Move the data before mounting over it |
| An I/O fault or read-only remount (`errors=remount-ro`) | `EXT4-fs error` or `I/O error` in `dmesg`; `/` mounted `ro` | Stop writing, snapshot, `fsck.ext4 -f` from a rescue boot | Alert on `node_filesystem_readonly` and `node_filesystem_device_error` |
| A root partition never grown after a resize | `lsblk` shows the disk larger than its partition | `growpart` with `TMPDIR=/dev/shm`, then `resize2fs`, or on LVM `pvresize` and `lvextend -r` | Compare `lsblk` with `df -h /` after every resize |

## Prevention and monitoring

### Alerts

Metric names are node_exporter's; a textfile collector signal needs a small script on the VM.

| Signal | Source | Alert when | Points to |
|---|---|---|---|
| Time to full for `/` | `predict_linear(node_filesystem_avail_bytes{mountpoint="/"}[6h], 4 * 3600) < 0` | True for 15 minutes | Any live writer, hours early |
| Available bytes on `/` | `node_filesystem_avail_bytes`, squashfs and tmpfs excluded | Below 15% of size (warning), 5% (critical) | Slow growth |
| Read-only or faulting filesystem | `node_filesystem_readonly`, `node_filesystem_device_error`; `EXT4-fs error` or `I/O error` in the kernel log | Any | An I/O fault or read-only remount |
| Inode use | `node_filesystem_files_free / node_filesystem_files` | Below 10% | Inode exhaustion |
| Deleted-but-open bytes | Textfile collector running the `/proc` scan every 5 minutes | Above 1 GB for 30 minutes | Logs not reopened, NGINX temp files, a shipper's buffer |
| Size of `/var/log/nginx`, the cache path, `/var/log/journal`, `/var/crash` | Textfile collector running `du -sb` | Above its budget | Retention, debug logging, an unbounded cache, the journal, crash dumps |
| logrotate health | `error:` lines from `logrotate.service`; age of the `nginx` status entry | Any error; older than two days | logrotate skipping NGINX or logs not reopened |

### Configuration

- **Retention sized to traffic**: rotate hourly and keep 48 files, two days and about 5 GB at 1,000 requests per second; logrotate honours `hourly` only when its timer runs hourly.

```text
# /etc/logrotate.d/nginx
/var/log/nginx/*.log {
    hourly
    rotate 48
    missingok
    compress
    delaycompress
    notifempty
    create 0640 www-data adm
    sharedscripts
    prerotate
        if [ -d /etc/logrotate.d/httpd-prerotate ]; then \
            run-parts /etc/logrotate.d/httpd-prerotate; \
        fi \
    endscript
    postrotate
        invoke-rc.d nginx rotate >/dev/null 2>&1
    endscript
}
```

```ini
# systemctl edit logrotate.timer
[Timer]
OnCalendar=
OnCalendar=hourly
```

- **Log less**: `access_log off;` in the health check location.
- **Bounded cache and temp files**: `proxy_cache_path /var/cache/nginx/app levels=1:2 keys_zone=app:50m max_size=10g min_free=5g inactive=7d use_temp_path=off;`, `proxy_max_temp_file_size 256m;`, `proxy_request_buffering off;` on upload routes.
- **A capped journal**: `/etc/systemd/journald.conf.d/size.conf` with `[Journal]` and `SystemMaxUse=1G`, then `systemctl restart systemd-journald`.
- **Capacity review**: monthly; grow the disk when projected time to full falls below 30 days.
