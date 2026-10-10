#!/bin/bash
# Kodi on Wayland: weston (DRM/KMS on the NVIDIA GPU, color management on) is
# the display owner; Kodi runs as a Wayland client.
#
#	* weston must be allowed to run as root (it owns /dev/dri/card*);
#	* a seat provider is required inside the container (no logind here):
#	  seatd, with /dev/tty0 + /dev/tty1 mapped;
#	* /dev/nvidia-modeset may not exist on the host and must be created;
#	* Kodi itself runs unprivileged (uid/gid 568), as in the X11 image.
set -e

UID_GID=568
XDG_DIR=/run/kodi-xdg
WESTON_LOG=/data/.kodi/temp/weston.log

# --- NVIDIA KMS device ----------------------------------------------------
[ -e /dev/nvidia-modeset ] || mknod /dev/nvidia-modeset c 195 254
chmod 666 /dev/nvidia-modeset

# --- profile + seeds ------------------------------------------------------
mkdir -p /data/.kodi/temp /data/.kodi/userdata
chown -R ${UID_GID}:${UID_GID} /data
for f in advancedsettings.xml sources.xml playercorefactory.xml; do
    [ -f "/usr/share/kodi-seed/$f" ] || continue
    [ -f "/data/.kodi/userdata/$f" ] || cp "/usr/share/kodi-seed/$f" "/data/.kodi/userdata/$f"
    chown ${UID_GID}:${UID_GID} "/data/.kodi/userdata/$f"
done

# --- Wayland runtime dir --------------------------------------------------
rm -rf "$XDG_DIR"; mkdir -p "$XDG_DIR"; chmod 700 "$XDG_DIR"

# --- seat provider --------------------------------------------------------
# seatd replaces logind; weston's libseat talks to it (LIBSEAT_BACKEND=seatd).
seatd -g root >/data/.kodi/temp/seatd.log 2>&1 &
sleep 1

export XDG_RUNTIME_DIR="$XDG_DIR"
export LIBSEAT_BACKEND=seatd
export WESTON_ALLOW_ROOT=1

# --- compositor -----------------------------------------------------------
# weston.ini carries color-management=true and the output EOTF (HDR); the GL
# renderer is required for color management.
#
# --drm-device: the container sees every /dev/dri node the nvidia runtime
#   injects, which includes the host's virtual (bochs) VGA as card0.  weston
#   would pick card0 and end up on llvmpipe; pin it to the NVIDIA card, resolved
#   through by-path so a change of card numbering does not matter.
# --continue-without-input: a NAS has no input devices, and weston otherwise
#   treats "failed to create input devices" as fatal.
NVIDIA_CARD="card1"
if [ -e /dev/dri/by-path/pci-0000:02:00.0-card ]; then
    NVIDIA_CARD="$(basename "$(readlink -f /dev/dri/by-path/pci-0000:02:00.0-card)")"
fi
echo "[kodi-wayland] starting weston on the DRM backend (device: ${NVIDIA_CARD})"
weston --backend=drm --drm-device="$NVIDIA_CARD" --continue-without-input \
       --renderer=gl --log="$WESTON_LOG" &

ready=0
for _ in $(seq 1 60); do
    if [ -S "$XDG_DIR/wayland-1" ]; then ready=1; break; fi
    sleep 1
done
if [ "$ready" != "1" ]; then
    echo "[kodi-wayland] ERROR: no compositor socket; see $WESTON_LOG" >&2
    tail -20 "$WESTON_LOG" >&2 || true
    exit 1
fi

chown -R ${UID_GID}:${UID_GID} "$XDG_DIR" 2>/dev/null || true
chmod 700 "$XDG_DIR"
echo "[kodi-wayland] compositor up: $(grep -m1 -iE 'Output .*HDMI|set mode|EOTF|HDR' "$WESTON_LOG" 2>/dev/null || echo '(no mode line yet)')"

stop_all() {
    echo "[kodi-wayland] container stopping -- SIGTERM to clients, compositor, seatd"
    pkill -TERM -x kodi.bin 2>/dev/null || true
    pkill -TERM -x mpv 2>/dev/null || true
    pkill -TERM -x weston 2>/dev/null || true
    pkill -TERM -x seatd 2>/dev/null || true
}
trap stop_all TERM INT

# --- Kodi as a Wayland client --------------------------------------------
# WAYLAND_DISPLAY (and no DISPLAY) selects Kodi's Wayland window system.
# Ambient CAP_NET_ADMIN/NET_RAW are kept for libPlatinum's SSDP multicast join
# (see the X11 image for the igmp_max_memberships sidecar); the compose must
# also grant them (cap_add) or setpriv fails with EPERM.  Degrade gracefully
# instead of refusing to start Kodi without them.
CAPS="--inh-caps +net_admin,+net_raw --ambient-caps +net_admin,+net_raw"
if ! setpriv --reuid=${UID_GID} --regid=${UID_GID} --init-groups $CAPS true 2>/dev/null; then
    echo "[kodi-wayland] WARNING: NET_ADMIN/NET_RAW unavailable (add cap_add: [NET_ADMIN, NET_RAW]); running Kodi without them - DLNA/SSDP discovery may fail"
    CAPS=""
fi

setpriv --reuid=${UID_GID} --regid=${UID_GID} --init-groups $CAPS \
    env HOME=/data XDG_RUNTIME_DIR="$XDG_DIR" WAYLAND_DISPLAY=wayland-1 \
        KODI_DATA=/data/.kodi /usr/bin/kodi --standalone &
kodi_child=$!

wait "$kodi_child" || true
echo "[kodi-wayland] Kodi exited; stopping compositor"
stop_all
