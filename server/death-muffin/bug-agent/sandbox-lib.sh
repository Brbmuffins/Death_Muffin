# Shared sandbox setup, sourced INSIDE `unshare -rnm bash -c '...'` by check.sh, check-godot.sh, preview.sh, preview-godot.sh, shot.sh and regen.sh
# (and by nothing the AI can edit: this file lives in the tools dir outside every worktree). One implementation so they cannot drift.
#
# Model: the whole filesystem is read-only, then only what the script needs is re-opened. The previous model only remounted /home/ubuntu read-only,
# but `ubuntu` also owns /var/www/death-muffin (the published client, play/, offline/, preview/), /opt/*, /game*, /var/log ..., all writable from
# code that runs inside the sandbox (test code, vite plugins, Godot scripts). So:
#   1. every mount in /proc/self/mountinfo is remounted read-only (bind remount; /proc, /sys, /dev stay as they are: root-owned kernel views);
#   2. a private tmpfs replaces /tmp and /dev/shm (nothing of the host's /tmp is visible or writable; sibling jobs' scratch and the predictable
#      /tmp/ship-*.$$ files stay out of reach); if the worktree itself lives under /tmp (tests only) it is carried over into the new /tmp;
#   3. only $TOP (the job's worktree) is writable again, via a bind mount.
# It FAILS CLOSED: if any mount cannot be made read-only, or a write probe still succeeds anywhere it must not, the run aborts (exit 99).
# Needs: $TOP (absolute worktree path). Optional: DM_SANDBOX_RW (colon-separated extra paths to re-open writable; none are used today).
dm_sandbox_setup() {
  ip link set lo up || return 99    # loopback only (tests listen on 127.0.0.1); nothing routes out
  mount --make-rprivate / || { echo "sandbox: cannot make mounts private" >&2; exit 99; }
  [ -n "${TOP:-}" ] && [ -d "$TOP" ] || { echo "sandbox: TOP is not a directory" >&2; exit 99; }
  local mp opts ro_list=() all=() line
  while read -r line; do all+=("$line"); done < <(awk '{print $5 " " $6}' /proc/self/mountinfo)
  for line in "${all[@]}"; do
    mp=${line%% *}; opts=${line#* }
    case "$mp" in /proc|/proc/*|/sys|/sys/*|/dev|/dev/*) continue;; esac
    case ",$opts," in *,ro,*) ro_list+=("$mp"); continue;; esac
    mount -o remount,bind,ro "$mp" 2>/dev/null || { echo "sandbox: cannot make $mp read-only; refusing to run" >&2; exit 99; }
    ro_list+=("$mp")
  done
  # private scratch space: /tmp and /dev/shm are fresh tmpfs, invisible to and from the host
  if [[ "$TOP" == /tmp/* ]]; then   # a worktree under /tmp (tests): stage it in a tmpfs that then replaces /tmp
    { mount -t tmpfs -o size=8g,mode=1777 tmpfs /mnt && mkdir -p "/mnt${TOP#/tmp}" && mount --bind "$TOP" "/mnt${TOP#/tmp}" && mount --move /mnt /tmp; } || { echo "sandbox: cannot set up /tmp" >&2; exit 99; }
  else
    mount -t tmpfs -o size=8g,mode=1777 tmpfs /tmp || { echo "sandbox: cannot set up /tmp" >&2; exit 99; }
  fi
  mount -t tmpfs -o size=2g,mode=1777 tmpfs /dev/shm 2>/dev/null || true
  # re-open the worktree (and any explicitly listed extra path) for writing
  local rw
  for rw in "$TOP" $(printf '%s' "${DM_SANDBOX_RW:-}" | tr ':' ' '); do
    { [[ "$rw" == /tmp/* ]] || mount --bind "$rw" "$rw"; } && mount -o remount,bind,rw "$rw" || { echo "sandbox: cannot re-open $rw" >&2; exit 99; }
  done
  # self-check: a write must fail on every read-only mount (other than where we re-opened) and must work in the worktree and /tmp
  for mp in "${ro_list[@]}"; do
    case "$mp" in /tmp|/tmp/*|"$TOP"|"$TOP"/*) continue;; esac
    if ( : > "$mp/.dm-sandbox-probe" ) 2>/dev/null; then rm -f "$mp/.dm-sandbox-probe"; echo "sandbox: $mp is still writable; refusing to run" >&2; exit 99; fi
  done
  ( : > "$TOP/.dm-sandbox-probe" ) 2>/dev/null && rm -f "$TOP/.dm-sandbox-probe" || { echo "sandbox: worktree is not writable" >&2; exit 99; }
  ( : > /tmp/.dm-sandbox-probe ) 2>/dev/null && rm -f /tmp/.dm-sandbox-probe || { echo "sandbox: /tmp is not writable" >&2; exit 99; }
}


# Runs INSIDE the nested namespace, before any payload. The ro remounts above were made by root of the OUTER user namespace, so code running
# there could simply remount them rw. In the nested user+mount namespace those mounts are LOCKED (MNT_LOCK_READONLY): they cannot be remounted
# rw, unmounted, or unmounted to reveal what is underneath. This proves it from the inside and aborts (exit 99) if any of it is not true.
dm_sandbox_verify() {
  local line mp
  while read -r line; do
    mp=${line%% *}
    case "$mp" in /proc|/proc/*|/sys|/sys/*|/dev|/dev/*|/tmp|/tmp/*|"$TOP"|"$TOP"/*) continue;; esac
    [ -n "${NM:-}" ] && [ "$mp" = "$NM/.vite" ] && continue
    if ( : > "$mp/.dm-sandbox-probe" ) 2>/dev/null; then rm -f "$mp/.dm-sandbox-probe"; echo "sandbox: $mp is writable; refusing to run" >&2; exit 99; fi
    if mount -o remount,bind,rw "$mp" 2>/dev/null; then echo "sandbox: $mp can be remounted read-write; refusing to run" >&2; exit 99; fi
  done < <(awk '{print $5}' /proc/self/mountinfo)
  if mount -o remount,bind,rw / 2>/dev/null; then echo "sandbox: / can be remounted read-write; refusing to run" >&2; exit 99; fi
  if umount /tmp 2>/dev/null; then echo "sandbox: /tmp can be unmounted; refusing to run" >&2; exit 99; fi
  ( : > "$TOP/.dm-sandbox-probe" ) 2>/dev/null && rm -f "$TOP/.dm-sandbox-probe" || { echo "sandbox: worktree is not writable" >&2; exit 99; }
  ( : > /tmp/.dm-sandbox-probe ) 2>/dev/null && rm -f /tmp/.dm-sandbox-probe || { echo "sandbox: /tmp is not writable" >&2; exit 99; }
}

# The only entry point scripts use (as `unshare -rnm bash -c '. "$DM_SANDBOX_LIB"; dm_sandbox_run'`): set the sandbox up as root of the outer
# user namespace, then exec the payload ($DM_PAYLOAD: bash text fixed by the calling script, exported) inside a NESTED user+mount namespace.
# Nothing the AI influences runs before the nesting. The network namespace is inherited (loopback only).
dm_sandbox_run() {
  dm_sandbox_setup
  if [ -n "${NM:-}" ] && [ -d "$NM/.vite" ]; then mount -t tmpfs tmpfs "$NM/.vite" || { echo "sandbox: cannot mount scratch over $NM/.vite" >&2; exit 99; }; fi
  exec unshare -Um --map-current-user bash -c '. "$DM_SANDBOX_LIB"; dm_sandbox_verify; exec bash -c "$DM_PAYLOAD"'
}
