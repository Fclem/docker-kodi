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

## HDR status: works, through `HDR_OUTPUT_METADATA`

Two things are true at different times, and the difference is worth knowing.

* **NVIDIA's 610 `nvidia-drm` does implement `HDR_OUTPUT_METADATA`** (plus
  `Colorspace` and `dithering mode`), even on a 6.12 kernel. The per-plane DRM
  *color pipeline* API that NVIDIA's notes say needs kernel >= 6.19 is a
  separate, newer mechanism; HDR signalling does not depend on it.
* **You only see it once the matching kernel module is actually loaded.**
  Reading the connector while an *older* `nvidia-drm` module is still resident
  shows only NVIDIA's vendor properties (`NV_HDR_STATIC_METADATA`,
  `NV_INPUT_COLORSPACE`) and none of the upstream ones. That trap cost real time
  here: `HDR_OUTPUT_METADATA` appeared on the connector only after the rebuilt
  sysext put the 610 module in place.

With that loaded, **mpv signals HDR10 correctly**. Verified on a 4K HDR10 film,
reading the connector back while it played:

```
prop Colorspace          value=9  (BT2020_RGB)
prop HDR_OUTPUT_METADATA value=<32-byte blob>: eotf=2 (ST2084/PQ), BT.2020 primaries,
                         mastering 1000 cd/m2, CLL 1163 / FALL 256
mpv: Selected mode: 3840x2160 (3840x2160@23.98Hz)
mpv: VAAPI driver: VA-API NVDEC driver [direct backend]
```

and the TV switches into HDR (confirmed on the panel). The recipe is mpv on
DRM/KMS with no compositor in the path:

```
mpv --vo=gpu-next --gpu-context=drm --drm-device=/dev/dri/cardN \
    --drm-connector=HDMI-A-1 --drm-mode=3840x2160@23.976 \
    --target-colorspace-hint=yes --hwdec=vaapi --fs <file>
```

What still does **not** work:

* **weston** cannot do HDR here: its colour management (`color-management=true`,
  which `[output] eotf=` requires) aborts with
  `color-lcms: error: color operations capability missing`, because NVIDIA's GLES
  renderer has no y-flip readback. The compositor in this example is therefore an
  SDR pipe.
* **Kodi's own DRM/GBM path segfaults** on this stack (crashlog written), so
  Kodi-native HDR is not a flag flip.
* **Kodi 22's own GBM backend gets closest, and shows the gap is the driver.**
  `kodi --windowing=gbm` — no compositor at all — *runs* on Kodi 22 (the Kodi 21
  segfault is genuinely fixed), uses the GPU directly, reads the TV's
  `supports hdr static metadata type1: true`, and during playback sets
  `Colorspace=BT2020_RGB` on the connector itself. It then fails at the final
  step: `CWinSystemGbmEGLContext::SetVideoOutput: failed to choose EGL config for
  10-bit`. That function rebuilds the output surface to AR30 and its own comment
  names amdgpu; NVIDIA's GBM/EGL exposes no 10-bit config, so
  `HDR_OUTPUT_METADATA` is never published. So this is not a compositor gap:
  Kodi's Wayland backend does not implement `SetGuiCompositing` at all (only the
  GBM backends do), which is why no compositor can satisfy it, and removing the
  compositor still lands on NVIDIA's GBM. mpv on DRM/KMS sidesteps both by
  driving the DRM plane and the metadata blob directly — which is why it works.
  Debug logging on the GBM run names both driver-side blockers: the hwdec is
  `ff-hevc-vaapi` and the decoder hands back **NV12** (`GLES: using shader
  format: NV12`) instead of a 10-bit surface, because the driver refuses the VPP
  config for HEVC Main10 (`VAAPI/vpp vaCreateConfig error: the requested
  VAProfile is not supported (12)`); and Kodi still asks for a 10-bit EGL config
  that NVIDIA does not expose. `VAAPI EGL interop` does advertise `p010le`, but
  the renderer chosen is `LinuxRendererGLES`, never `RendererDRMPRIME` — that one
  needs a DRM-PRIME hwdec, which this VA-API→GL interop path is not.
* **Kodi on this Wayland stack hangs on 4K HDR titles.** Opening one leaves
  `kodi.bin` alive but unresponsive — the EventServer logs
  `ES: Client … timed out` and remote apps get nothing back. Kodi's log ends at
  `VAAPI/vpp vaCreateConfig error: the requested VAProfile is not supported (12)`:
  it asks nvidia-vaapi-driver for HEVC Main10 **VPP** (video post-processing),
  which that driver does not implement; the render path then never starts. The
  same file plays fine on an X11/VAAPI Kodi (SDR output). Practical split on
  this box: **Kodi (X11) for everything, mpv on DRM for HDR titles** — which is
  what `kodi-playercorefactory.xml` was routing to before it was disabled.

For HDR with Kodi's own UI on screen, use a compositor that sets
`HDR_OUTPUT_METADATA` itself: KWin/Plasma does, given
`KWIN_FORCE_ASSUME_HDR_SUPPORT=1` and `KWIN_DRM_ALLOW_NVIDIA_COLORSPACE=1`
(nvidia-drm exposes no `max_bpc`, which is KWin's normal HDR capability check).
The entry point supports `KODI_COMPOSITOR=kwin` for that.

## Layout

| File | Purpose |
| --- | --- |
| `Dockerfile` | Ubuntu 26.04 + Kodi 21.3 + weston + kwin-wayland + mpv (+ `nvidia-vaapi-driver`) |
| `kodi-wayland-entrypoint.sh` | creates `/dev/nvidia-modeset`, starts `seatd` and a compositor (weston by default — with `--shell=kiosk`, since the default desktop shell paints a status panel over the picture — or KWin with `KODI_COMPOSITOR=kwin`; both pinned to the NVIDIA card, no-input allowed, socket auto-detected), runs Kodi unprivileged (uid 568), clean SIGTERM |
| `weston.ini` | kiosk settings (never blank, black background); colour management documented as disabled (see above) |
| `mpv.conf`, `mpv-hdr` | HDR player: `--vo=gpu-next`, `target-colorspace-hint`, VA-API decode |
| `kodi-playercorefactory.xml` | routes 2160p/HDR/DoVi files to mpv, everything else stays in Kodi — **not seeded** by the entry point: drop it into `userdata/` deliberately if you want the hand-off. If it is active while the helper script is missing from the image, Kodi forks a non-existent binary (`exit 127`) and *nothing* plays |
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
