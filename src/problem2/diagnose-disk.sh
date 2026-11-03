#!/usr/bin/env bash
# Read-only disk report for an NGINX host: every check from SOLUTION.md in one
# pass, nothing deleted. Each collector runs under a timeout; collectors that
# fail, time out or lack their tool are listed at the end, and the exit status
# is 1 when any failed, so a partial report cannot pass for a complete one.
# Usage: sudo ./diagnose-disk.sh [mount] > /dev/shm/disk-report.txt
set -euo pipefail

export TARGET="${1:-/}"
export TOP="${TOP:-15}"      # rows per listing
export BIG="${BIG:-500M}"    # threshold for the large-file listing

# sort may spill to $TMPDIR, which defaults to the full disk.
if [[ -d /dev/shm && -w /dev/shm ]]; then export TMPDIR=/dev/shm; fi

have()    { command -v "$1" >/dev/null 2>&1; }
low()     { if have ionice; then nice -n 19 ionice -c 3 "$@"; else nice -n 19 "$@"; fi; }
human()   { numfmt --to=iec-i --suffix=B -- "$1"; }
section() { printf '\n== %s\n' "$1"; }
first()   { awk -v n="$TOP" 'NR <= n'; }
skip()    { echo "skipped: $1 is not installed"; return 3; }

overview() {
  printf 'host %s, %s, kernel %s, target %s\n' "$(hostname)" "$(date -Is)" "$(uname -r)" "$TARGET"
  if [[ $EUID -ne 0 ]]; then echo "WARNING: not root; du, /proc and tune2fs results are incomplete"; fi
  section "Filesystems (bytes, then inodes)"
  df -hT -x tmpfs -x devtmpfs -x squashfs -x efivarfs
  df -i -x tmpfs -x devtmpfs -x squashfs -x efivarfs
}

mount_options() {
  section "Mount holding $TARGET"
  have findmnt || skip findmnt
  findmnt -n -o TARGET,SOURCE,FSTYPE,OPTIONS -T "$TARGET"
  if findmnt -n -o OPTIONS -T "$TARGET" | grep -qE '(^|,)ro(,|$)'; then
    echo "SIGNAL: mounted read-only; the kernel remounted it after an error, or it never came up read-write (R15)"
  fi
}

reserved_blocks() {
  local src fstype
  have findmnt || skip findmnt
  src=$(findmnt -n -o SOURCE -T "$TARGET")
  fstype=$(findmnt -n -o FSTYPE -T "$TARGET")
  section "Filesystem $src ($fstype): root reserve and inode table"
  if [[ $fstype != ext* ]]; then echo "not ext2/3/4: no root reserve to report"; return 0; fi
  have tune2fs || skip tune2fs
  tune2fs -l "$src" | awk -F: '
    /^Block count/          { total = $2 }
    /^Reserved block count/ { res = $2 }
    /^Block size/           { bs = $2 }
    /^Inode count/          { inodes = $2 }
    /^Filesystem state/     { state = $2 }
    /^Errors behavior/      { err = $2 }
    END {
      printf "reserved for root: %d blocks, %.1f%%, %.2f GiB\n", res, 100 * res / total, res * bs / 2^30
      printf "inodes: %d, one per %d bytes\n", inodes, total * bs / inodes
      printf "state:%s; on error:%s\n", state, err }'
}

kernel_log() {
  local lines
  section "Kernel log: filesystem and device errors (dmesg)"
  have dmesg || skip dmesg
  lines=$(dmesg -T)
  grep -iE 'ext4-fs (error|warning)|i/o error|remount|read-only' <<<"$lines" | tail -n "$TOP" \
    || echo "no filesystem or device errors in the ring buffer"
  echo "last 3 lines:"; tail -n 3 <<<"$lines"
}

block_devices() {
  section "Block devices: a disk larger than its partitions is a resize that was never grown (R16)"
  have lsblk || skip lsblk
  lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINTS
  lsblk -b -n -r -o NAME,SIZE,TYPE,PKNAME | awk '
    $3 == "disk" { disk[$1] = $2 }
    $3 == "part" { used[$4] += $2 }
    END { for (d in disk) { gap = disk[d] - used[d]
      if (gap > 2^30) printf "SIGNAL: %s has %.1f GiB outside any partition: growpart, then resize2fs (R16)\n", d, gap / 2^30 } }'
}

lvm_layout() {
  section "LVM volume groups and logical volumes"
  have vgs || skip lvm2
  vgs --noheadings -o vg_name,vg_size,vg_free
  lvs --noheadings -o lv_name,vg_name,lv_size,lv_path
}

deleted_open() {
  local dev fd key size pid comm sum=0
  local -A bytes=() holders=() names=()
  dev=$(stat -c %d "$TARGET")
  section "Deleted files still held open on $TARGET (copy their tails before reopen or truncate)"
  while IFS= read -r fd; do
    read -r key size < <(stat -L -c '%d:%i %s' "$fd" 2>/dev/null) || continue
    [[ ${key%%:*} == "$dev" ]] || continue
    pid=${fd#/proc/}; pid=${pid%%/*}
    comm=$(cat "/proc/$pid/comm" 2>/dev/null || echo "?")
    bytes[$key]=$size
    holders[$key]+="$comm($pid) "
    names[$key]=$(readlink "$fd" 2>/dev/null || echo "?")
  done < <(find /proc/[0-9]*/fd -lname '*(deleted)' 2>/dev/null || true)
  if [[ ${#bytes[@]} -eq 0 ]]; then echo "none"; return 0; fi
  for key in "${!bytes[@]}"; do sum=$(( sum + bytes[$key] )); done
  for key in "${!bytes[@]}"; do
    printf '%s\tinode %s\t%s\t%s\n' "${bytes[$key]}" "${key#*:}" "${names[$key]}" "${holders[$key]}"
  done | sort -rn | first | numfmt --to=iec --field=1
  printf 'total held: %s (counted once per file, not per process)\n' "$(human "$sum")"
}

df_vs_du() {
  local dulist used total gap
  section "Largest directories on $TARGET (du -x, depth 3)"
  dulist=$(low du -x -B1 --max-depth=3 "$TARGET" 2>/dev/null || true)
  sort -rn <<<"$dulist" | first | numfmt --to=iec --field=1
  used=$(df -B1 --output=used "$TARGET" | tail -n 1 | tr -d ' ')
  total=$(awk -v t="$TARGET" '$2 == t { print $1 }' <<<"$dulist")
  gap=$(( used - ${total:-0} ))
  section "df used versus du total"
  printf 'df used %s, du total %s, gap %s\n' "$(human "$used")" "$(human "${total:-0}")" "$(human "$gap")"
  echo "A gap of more than a few percent: deleted-but-open files (section above) or files hidden under a mount point."
}

big_files() {
  section "Files over $BIG on $TARGET"
  low find "$TARGET" -xdev -type f -size "+$BIG" -printf '%s\t%TY-%Tm-%Td %TH:%TM\t%p\n' 2>/dev/null \
    | sort -rn | first | numfmt --to=iec --field=1 || true
  section "Files over 10M written in the last 15 minutes (growing now)"
  low find "$TARGET" -xdev -type f -mmin -15 -size +10M -printf '%s\t%p\n' 2>/dev/null \
    | sort -rn | first | numfmt --to=iec --field=1 || true
}

inode_hotspots() {
  local pct
  pct=$(df --output=ipcent "$TARGET" | tail -n 1 | tr -dc '0-9')
  if [[ -z $pct || $pct -lt 80 ]]; then return 0; fi
  section "Directories with the most entries (inode use is ${pct}%)"
  low find "$TARGET" -xdev -printf '%h\n' 2>/dev/null \
    | awk '{ c[$0]++ } END { for (d in c) print c[d], d }' | sort -rn | first || true
}

nginx_checks() {
  section "NGINX directives that write to disk (nginx -T)"
  have nginx || skip nginx
  nginx -v 2>&1
  nginx -T 2>/dev/null | grep -nE '^\s*(access_log|error_log|proxy_cache_path|proxy_temp_path|client_body_temp_path|proxy_max_temp_file_size|proxy_buffering|client_max_body_size)\b' || true
  nginx -V 2>&1 | tr ' ' '\n' | grep -E 'temp-path|log-path' || true
  section "NGINX log, temp and cache directories"
  local dirs=(/var/log/nginx /var/lib/nginx /var/cache/nginx)
  mapfile -t -O "${#dirs[@]}" dirs < <(nginx -T 2>/dev/null | awk '$1 == "proxy_cache_path" { print $2 }' | sort -u)
  for d in "${dirs[@]}"; do if [[ -d $d ]]; then du -sh "$d" 2>/dev/null || true; fi; done
  if [[ -d /var/log/nginx ]]; then
    find /var/log/nginx -maxdepth 1 -type f -printf '%s\t%TY-%Tm-%Td %TH:%TM\t%u:%g\t%f\n' \
      | sort -rn | first | numfmt --to=iec --field=1
    if [[ -f /var/log/nginx/access.log && ! -s /var/log/nginx/access.log && /var/log/nginx/access.log.1 -nt /var/log/nginx/access.log ]]; then
      echo "SIGNAL: access.log is empty and access.log.1 is newer: nginx did not reopen its logs after rotation (R3)"
    fi
  fi
}

logrotate_checks() {
  section "logrotate"
  have logrotate || skip logrotate
  if have systemctl; then
    systemctl list-timers logrotate.timer --no-pager --all 2>/dev/null | awk 'NR <= 2' || true
    systemctl show logrotate.service -p Result -p ExecMainStatus -p ExecMainExitTimestamp 2>/dev/null || true
  fi
  grep -h nginx /var/lib/logrotate/status 2>/dev/null || echo "no nginx entry in /var/lib/logrotate/status"
  find /etc/logrotate.d -type f -perm /022 -printf 'IGNORED by logrotate (group or world writable): %p\n' 2>/dev/null || true
  logrotate -d /etc/logrotate.conf 2>&1 | grep -iE '^error|ignoring|insecure' | first || true
  if have journalctl; then journalctl -u logrotate.service --since=-3d --no-pager -o cat -p warning 2>/dev/null | first || true; fi
}

journald_checks() {
  section "journald"
  have journalctl || skip journalctl
  journalctl --disk-usage 2>/dev/null || true
  if have systemd-analyze; then
    systemd-analyze cat-config systemd/journald.conf 2>/dev/null | grep -E '^(Storage|SystemMaxUse|SystemKeepFree|MaxRetentionSec|ForwardToSyslog)=' || echo "journald limits: compile-time defaults"
  fi
  echo "top writers in the last hour:"
  journalctl --since=-1h -o export --output-fields=SYSLOG_IDENTIFIER 2>/dev/null \
    | awk -F= '/^SYSLOG_IDENTIFIER=/ { c[$2]++ } END { for (k in c) print c[k], k }' | sort -rn | awk 'NR <= 5' || true
}

package_checks() {
  section "Packages, kernels and snaps"
  have dpkg-query || skip dpkg
  du -sh /var/cache/apt/archives /boot /var/lib/snapd/snaps 2>/dev/null || true
  echo "running kernel: $(uname -r)"
  dpkg-query -W -f='${db:Status-Abbrev} ${Package}\n' 'linux-image-[0-9]*' 2>/dev/null | awk '$1 == "ii" { print "installed: " $2 }' || true
  if have snap; then snap list --all 2>/dev/null | awk '/disabled/ { print "disabled snap revision: " $1 " " $3 }' || true; fi
}

coredump_checks() {
  section "Core dumps and crash reports"
  echo "core_pattern: $(cat /proc/sys/kernel/core_pattern)"
  du -sh /var/crash /var/lib/apport/coredump /var/lib/systemd/coredump 2>/dev/null || true
}

shipper_checks() {
  section "Log shippers (their buffers and held files)"
  have pgrep || skip procps
  pgrep -a -f 'fluent-bit|fluentd|filebeat|vector|otelcol|promtail|alloy' 2>/dev/null | cut -c1-160 || echo "none running"
}

export -f have low human section first skip overview mount_options reserved_blocks kernel_log \
  block_devices lvm_layout deleted_open df_vs_du big_files inode_hotspots nginx_checks \
  logrotate_checks journald_checks package_checks coredump_checks shipper_checks

FAILED=()
SKIPPED=()
ERR=$(mktemp)
trap 'rm -f "$ERR"' EXIT
TIMEOUT=""
if have timeout; then TIMEOUT=timeout; elif have gtimeout; then TIMEOUT=gtimeout; fi

# run <collector> <seconds>: a child bash runs the exported function so that
# timeout covers every command in it. Exit 3 means the collector skipped itself.
run() {
  local fn=$1 secs=$2 rc=0 why
  if [[ -n $TIMEOUT ]]; then
    "$TIMEOUT" --kill-after=5 "$secs" bash -eu -o pipefail -c "$fn" 2>"$ERR" || rc=$?
  else
    bash -eu -o pipefail -c "$fn" 2>"$ERR" || rc=$?
  fi
  why=$(tail -n 1 "$ERR" 2>/dev/null || true)
  case $rc in
    0) ;;
    3) SKIPPED+=("$fn") ;;
    124 | 137) FAILED+=("$fn: timed out after ${secs}s") ;;
    *) FAILED+=("$fn: exit $rc${why:+, $why}") ;;
  esac
}

run overview 10
run mount_options 10
run reserved_blocks 10
run kernel_log 10
run block_devices 10
run lvm_layout 10
run deleted_open 30
run df_vs_du 30
run big_files 30
run inode_hotspots 30
run nginx_checks 20
run logrotate_checks 20
run journald_checks 20
run package_checks 20
run coredump_checks 10
run shipper_checks 10

section "Collection summary"
if [[ -z $TIMEOUT ]]; then FAILED+=("timeout: not installed, so collectors ran without a time limit"); fi
if (( ${#SKIPPED[@]} > 0 )); then echo "skipped, tool not installed: ${SKIPPED[*]}"; fi
if (( ${#FAILED[@]} > 0 )); then
  echo "could not collect:"
  printf '  %s\n' "${FAILED[@]}"
  echo "The report is partial: treat these sections as unknown, not as clean."
  exit 1
fi
echo "all collectors completed"
