# Kodi 21.3 "Omega" on Wayland, driving the TV through an NVIDIA GPU, with a
# full HDR pipeline (color-managed compositor + color-management-v1 client).
#
# Why this shape:
#   * The X11 image (kodi-tv:21.3) can decode 10-bit HEVC on the GPU (VA-API)
#     but can never *signal* HDR: Kodi's Linux HDR output exists only in the
#     GBM/DRM-PRIME path (needs HDR_OUTPUT_METADATA, which nvidia-drm does not
#     publish) and in the Wayland color-management path (not compiled into
#     distro Kodi 21 builds; the code is master/Kodi 22 only).
#   * On Wayland the display belongs to a compositor.  weston >= 14 has
#     color-management= support (wp_color_manager_v1 server side) and can drive
#     non-SDR output modes, so it is the compositor that puts the TV into HDR.
#   * Kodi 21.3 runs as a Wayland client for library/UI/normal playback, and
#     hands HDR/4K material to mpv (--vo=gpu-next, target-colorspace-hint),
#     which does speak color-management-v1.
#
# Requires the *host* NVIDIA driver to support the DRM color-pipeline / HDR
# output path: 610.43.02 or newer (Turing and newer cards).
FROM ubuntu:26.04

ENV DEBIAN_FRONTEND=noninteractive

# --- Kodi + Wayland compositor + HDR player -------------------------------
# Long apt run keeps printing progress so a reverse proxy in front of the
# builder does not time the build stream out.
RUN set -eux; \
    apt-get update -qq; \
    ( apt-get install -y -qq --no-install-recommends \
        kodi kodi-inputstream-adaptive \
        weston seatd \
        mpv nvidia-vaapi-driver \
        libgbm1 libegl1 libgl1 libgles2 libegl-mesa0 \
        dbus alsa-utils util-linux tzdata ca-certificates bash \
        >/tmp/apt.log 2>&1; echo $? >/tmp/apt.rc ) & \
    ap=$!; while kill -0 $ap 2>/dev/null; do echo "[apt] installing kodi + weston + mpv..."; sleep 10; done; \
    wait $ap || true; rc=$(cat /tmp/apt.rc); tail -6 /tmp/apt.log; [ "$rc" = "0" ]; \
    rm -rf /var/lib/apt/lists/*

# --- runtime user (TrueNAS "apps" uid/gid) + seeded defaults ---------------
RUN set -eux; \
    getent group video  >/dev/null || groupadd -g 44  video; \
    getent group render >/dev/null || groupadd -g 107 render; \
    getent group audio  >/dev/null || groupadd -g 29  audio; \
    getent group kodi   >/dev/null || groupadd -g 568 kodi; \
    useradd -u 568 -g 568 -d /data -s /bin/bash kodi; \
    usermod -aG video,render,audio kodi; \
    install -d -o kodi -g kodi /data; \
    install -d /usr/share/kodi-seed; \
    install -d /etc/xdg/weston

COPY weston.ini /etc/xdg/weston/weston.ini
COPY mpv.conf /etc/mpv/mpv.conf
COPY kodi-playercorefactory.xml /usr/share/kodi-seed/playercorefactory.xml
COPY advancedsettings.xml sources.xml /usr/share/kodi-seed/
COPY kodi-wayland-entrypoint.sh /usr/local/bin/kodi-wayland-entrypoint.sh
COPY mpv-hdr /usr/local/bin/mpv-hdr
RUN chmod 0755 /usr/local/bin/kodi-wayland-entrypoint.sh /usr/local/bin/mpv-hdr

# NVDEC-through-VAAPI for Kodi's own decode path (inputstream.adaptive / DRM).
ENV LIBVA_DRIVER_NAME=nvidia

ENTRYPOINT ["/usr/local/bin/kodi-wayland-entrypoint.sh"]
