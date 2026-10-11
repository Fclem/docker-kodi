#!/bin/bash
# Kodi on Wayland, with a compositor that owns the DRM/KMS output of a passed
# through NVIDIA GPU.
#
#	KODI_COMPOSITOR=weston (default) - colour management would be needed for HDR
#	  but weston's color-lcms aborts on NVIDIA ("color operations capability
#	  missing": its GLES renderer has no y-flip readback), so this path is SDR.
#	KODI_COMPOSITOR=kwin - kwin_wayland sets the upstream HDR_OUTPUT_METADATA
#	  property, which nvidia-drm *does* implement (visible once the matching
#	  module is loaded).  KWIN_FORCE_ASSUME_HDR_SUPPORT is required because
#	  nvidia-drm exposes no max_bpc property, which is KWin's normal HDR check.
#
#	* the compositor runs as root (it owns /dev/dri/card*);
#	* a seat provider is required inside the container (no logind here):
#	  seatd, with /dev/tty0 + /dev/tty1 mapped;
#	* /dev/nvidia-modeset may not exist on the host and must be created;
#	* Kodi itself runs unprivileged (uid/gid 568), as in the X11 image.
set -e

UID_GID=568
XDG_DIR=/run/kodi-xdg
WESTON_LOG=/data/.kodi/temp/weston.log
KWIN_LOG=/data/.kodi/temp/kwin.log
XORG_LOG=/data/.kodi/temp/Xorg.log

# --- NVIDIA KMS device ----------------------------------------------------
[ -e /dev/nvidia-modeset ] || mknod /dev/nvidia-modeset c 195 254
chmod 666 /dev/nvidia-modeset

# --- profile + seeds ------------------------------------------------------
mkdir -p /data/.kodi/temp /data/.kodi/userdata
chown -R ${UID_GID}:${UID_GID} /data
# playercorefactory.xml is deliberately NOT seeded: its external-player rule
# hands every 2160p/HDR filename to a helper script, and re-seeding it on each
# restart silently re-arms that hand-off (it bit us once: the script was absent
# from the image, Kodi forked it, got exit 127, and nothing played at all).
# The hand-off is opt-in, on request only.
for f in advancedsettings.xml sources.xml; do
    [ -f "/usr/share/kodi-seed/$f" ] || continue
    [ -f "/data/.kodi/userdata/$f" ] || cp "/usr/share/kodi-seed/$f" "/data/.kodi/userdata/$f"
    chown ${UID_GID}:${UID_GID} "/data/.kodi/userdata/$f"
done

# --- Wayland runtime dir --------------------------------------------------
rm -rf "$XDG_DIR"; mkdir -p "$XDG_DIR"; chmod 700 "$XDG_DIR"

# --- seat provider --------------------------------------------------------
# seatd replaces logind; the compositor's libseat talks to it.
seatd -g root >/data/.kodi/temp/seatd.log 2>&1 &
sleep 1

export XDG_RUNTIME_DIR="$XDG_DIR"
export LIBSEAT_BACKEND=seatd
export WESTON_ALLOW_ROOT=1

# The container sees every /dev/dri node the nvidia runtime injects, which
# includes the host's virtual (bochs) VGA as card0 - a compositor that picks it
# would render with llvmpipe.  Resolve the NVIDIA card through by-path so a
# change of card numbering does not matter.
NVIDIA_CARD="card1"
if [ -e /dev/dri/by-path/pci-0000:02:00.0-card ]; then
    NVIDIA_CARD="$(basename "$(readlink -f /dev/dri/by-path/pci-0000:02:00.0-card)")"
fi

# --- compositor -----------------------------------------------------------
COMPOSITOR="${KODI_COMPOSITOR:-weston}"
if [ "$COMPOSITOR" = "kwin" ]; then
    # KWin needs a session bus; Kodi must connect to the same one.
    dbus-daemon --session --fork --address="unix:path=$XDG_DIR/bus" >/dev/null 2>&1 || true
    export DBUS_SESSION_BUS_ADDRESS="unix:path=$XDG_DIR/bus"
    export XDG_SESSION_TYPE=wayland
    export HOME=/data XDG_CONFIG_HOME=/data/.config
    mkdir -p /data/.config
    # nvidia-drm has HDR_OUTPUT_METADATA but no max_bpc, which is what KWin
    # normally checks, so both overrides are needed.
    export KWIN_FORCE_ASSUME_HDR_SUPPORT=1
    export KWIN_DRM_ALLOW_NVIDIA_COLORSPACE=1
    export KWIN_DRM_DEVICES="/dev/dri/${NVIDIA_CARD}"
    echo "[kodi-wayland] starting kwin_wayland (DRM device: /dev/dri/${NVIDIA_CARD})"
    kwin_wayland --drm --no-lockscreen --no-global-shortcuts >"$KWIN_LOG" 2>&1 &
    COMPOSITOR_LOG="$KWIN_LOG"
else
    echo "[kodi-wayland] starting weston on the DRM backend (device: ${NVIDIA_CARD})"
    # --shell=kiosk: weston's default desktop shell paints a status panel
    # (clock + launcher icon) over the TV picture.  Kodi is the only client.
    weston --backend=drm --drm-device="$NVIDIA_CARD" --continue-without-input \
           --shell=kiosk --renderer=gl --log="$WESTON_LOG" &
    COMPOSITOR_LOG="$WESTON_LOG"
fi

# The compositor chooses the socket name, so discover it instead of assuming.
WAYLAND_SOCKET=""
for _ in $(seq 1 60); do
    WAYLAND_SOCKET="$(ls "$XDG_DIR" 2>/dev/null | grep -m1 '^wayland-[0-9]*$' || true)"
    [ -n "$WAYLAND_SOCKET" ] && break
    sleep 1
done
if [ -z "$WAYLAND_SOCKET" ]; then
    echo "[kodi-wayland] ERROR: no compositor socket; see $COMPOSITOR_LOG" >&2
    tail -25 "$COMPOSITOR_LOG" >&2 || true
    exit 1
fi

chown -R ${UID_GID}:${UID_GID} "$XDG_DIR" 2>/dev/null || true
chmod 700 "$XDG_DIR"
echo "[kodi-wayland] compositor up (${COMPOSITOR}, display ${WAYLAND_SOCKET})"

stop_all() {
    echo "[kodi-wayland] container stopping -- SIGTERM to clients, compositor, seatd"
    pkill -TERM -x kodi.bin 2>/dev/null || true
    pkill -TERM -x mpv 2>/dev/null || true
    pkill -TERM -x weston 2>/dev/null || true
    pkill -TERM -x kwin_wayland 2>/dev/null || true
    pkill -TERM -x dbus-daemon 2>/dev/null || true
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
    env HOME=/data XDG_RUNTIME_DIR="$XDG_DIR" WAYLAND_DISPLAY="$WAYLAND_SOCKET" \
        DBUS_SESSION_BUS_ADDRESS="$DBUS_SESSION_BUS_ADDRESS" \
        KODI_DATA=/data/.kodi /usr/bin/kodi --standalone &
kodi_child=$!

wait "$kodi_child" || true
echo "[kodi-wayland] Kodi exited; stopping compositor"
stop_all
