# Kodi on Wayland (NVIDIA GPU driving a TV)

This example runs **Kodi as a Wayland client** on a headless NVIDIA GPU whose
only output is HDMI to a TV. A **weston** compositor owns the display and the
GPU, Kodi renders at the panel's native resolution, and **mpv** is wired in as
the player for 4K/HDR material.

It is the Wayland sibling of [`../nvidia-xorg-vaapi`](../nvidia-xorg-vaapi): that
one runs Xorg in the container and fixes *decoding* (NVDEC through VA-API).
This one moves the display pipeline to Wayland.

## Verified on

RTX 2070 (`1F02`) → HDMI → Samsung HDR10 TV, TrueNAS 25.10.4 host with driver
**610.43.02**, Kodi 21.3, weston 14.0.2, mpv 0.41.0 (libplacebo 7.360).

Kodi's own log confirms the result:

```
CApplication::CreateGUI - using the wayland windowing system
UpdateSizeVariables: Surface size changed: 0x0 -> 3840x2160
GL_RENDERER = NVIDIA GeForce RTX 2070/PCIe/SSE2
```

## Requirements

* **Host NVIDIA driver ≥ 610.43.02** *including the `nvidia-drm` kernel module*
  (see the note at the bottom — the usual TrueNAS sysext tooling strips it).
* `nvidia-container-toolkit`, and these host devices:
  `/dev/dri/card*`, `/dev/dri/render*`, `/dev/tty0`, `/dev/tty1`, `/dev/snd`.
  The tty pair matters: a compositor needs a VT, and there is no logind inside
  the container.
* `cap_add: [NET_ADMIN, NET_RAW]` — libPlatinum's SSDP multicast join needs
  NET_ADMIN, and the entry point hands both to Kodi as ambient capabilities.
  Without them `setpriv --ambient-caps` fails with `Operation not permitted`.
* `device_cgroup_rules: ["c 195:254 rwm"]`: `/dev/nvidia-modeset` does not exist
  on every host and the entry point creates it.
* Host networking for SSDP/DLNA, and the `igmp_max_memberships` helper sidecar
  (libPlatinum joins the multicast group on every interface; see the SDR example).

## Three things that will bite you

1. **The container sees every `/dev/dri` node the runtime injects — including the
   host's virtual VGA.** On a TrueNAS VM that is a Bochs adapter as `card0`.
   weston picks the first usable card, ends up on **llvmpipe**, and you get
   software rendering while everything still "works". The entry point pins it:

   ```
   weston --drm-device="$(basename "$(readlink -f /dev/dri/by-path/pci-0000:02:00.0-card)")"
   ```

2. **weston treats "failed to create input devices" as fatal.** A NAS has no
   input devices at all. `--continue-without-input` lets it start; control is
   over the webserver/JSON-RPC (Kodi logs `did not announce a wl_seat`).

3. **`setpriv --ambient-caps` needs the caps granted by the container.** The
   entry point checks first and degrades gracefully instead of refusing to start
   Kodi.

## HDR status

The driver and the panel are ready — weston reports the connector's
capabilities:

```
DRM: head 'HDMI-A-1' found, connector 132 is connected, EDID make 'Samsung Electric Company'
     Supported EOTF modes: SDR, ST2084, HLG
     Supported colorimetry modes: default, BT.2020 (YCC), BT.2020 (RGB)
```

but **weston's colour management does not work on this driver**, so this example
currently outputs **SDR**:

```
color-lcms: error: color operations capability missing. Is GL-renderer not in use?
```

NVIDIA's GLES renderer reports `glReadPixels supports y-flip: no`, which weston's
color-lcms module requires — `color-management=true` (and therefore
`[output] eotf=st2084`) is unusable. A colour-managed compositor that *does* work
on `nvidia-drm` is KWin/Plasma: NVIDIA added the DRM color pipeline in the 610
branch precisely so compositors can drive HDR. Swapping weston for KWin is the
next step; `weston.ini` and `mpv.conf` keep the intended HDR settings commented
and documented.

For the same reason Kodi itself cannot signal HDR here (its `wp_color_manager_v1`
path exists only in Kodi 22/master), which is why 4K/HDR files are handed to mpv
via `playercorefactory.xml` — mpv speaks `color-management-v1` and does the HDR
part as soon as a working colour-managed compositor is in place.

## Layout

| File | Purpose |
| --- | --- |
| `Dockerfile` | Ubuntu 26.04 + Kodi 21.3 + weston + mpv (+ `nvidia-vaapi-driver`) |
| `kodi-wayland-entrypoint.sh` | creates `/dev/nvidia-modeset`, starts `seatd` + weston (pinned to the NVIDIA card, no-input allowed), runs Kodi unprivileged (uid 568), clean SIGTERM |
| `weston.ini` | kiosk settings; colour management documented as disabled (see above) |
| `mpv.conf`, `mpv-hdr` | HDR player: `--vo=gpu-next`, `target-colorspace-hint`, VA-API decode |
| `kodi-playercorefactory.xml` | routes 2160p/HDR/DoVi files to mpv, everything else stays in Kodi |
| `advancedsettings.xml`, `sources.xml.example` | seeded only when the profile has no copy |
| `docker-compose.example.yml` | devices, cgroup rule, cap_add, the SSDP sidecar |

## A note for TrueNAS users: `--no-drm`

TrueNAS ships its NVIDIA driver as a systemd-sysext, and the community tooling
that builds a newer one (`truenas-community-sysexts/nvidia-driver-support`)
deliberately passes `--no-drm` to the NVIDIA installer. The resulting sysext has
`nvidia.ko`, `nvidia-modeset.ko`, `nvidia-uvm.ko` and `nvidia-peermem.ko` but
**no `nvidia-drm.ko`** — which is fine for transcoding, and fatal for anything
that drives a display: there is no `/dev/dri/cardN` at all. Dropping `--no-drm`
from the flag list in `build-nvidia-sysext.sh`, rebuilding, and re-merging
restores the DRM card (the stock TrueNAS raw does contain `nvidia-drm.ko`, so it
builds fine on the same kernel).
