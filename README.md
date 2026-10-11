# docker-kodi — Fclem's fork

Fork of [`ehough/docker-kodi`](https://github.com/ehough/docker-kodi), used to run **Kodi 21
"Omega" on a headless NVIDIA GPU** driving a TV, from a Docker/Portainer stack on a NAS.

| | |
| --- | --- |
| Upstream | `ehough/docker-kodi`, default branch `master` |
| SDR deployment (runs today) | `example/nvidia-xorg-vaapi-kodi21` — proposed upstream as [PR #56](https://github.com/ehough/docker-kodi/pull/56): Xorg in the container, NVDEC via VA-API for 10-bit HEVC decode, SDR output |
| Wayland deployment (SDR today) | branch `example/nvidia-wayland-hdr`: Kodi as a **Wayland client** under **weston** on the NVIDIA GPU (4K surface, VA-API decode), with **mpv** wired in for 4K/HDR files. HDR *output* is not live yet: weston's colour management aborts on NVIDIA (`color-lcms: color operations capability missing`), so the pipe is SDR. The compositor that works on `nvidia-drm` is KWin/Plasma (driver **≥ 610.43.02**). Details in the example README |
| `master` here | upstream `master` + this README |

Upstream's documentation is preserved verbatim at the bottom of this file.

## What this image is

| Component | Detail |
| --- | --- |
| Base | `ubuntu:26.04` (Kodi 21.3 is the distro package; no PPA, no source build) |
| Kodi | 21.3 "Omega" + `kodi-inputstream-adaptive` 21.5.16 |
| Hardware decode | `nvidia-vaapi-driver` 0.0.14 — NVDEC exposed as VA-API (`LIBVA_DRIVER_NAME=nvidia`) |
| X server | `xserver-xorg-core` with the NVIDIA DDX: `nvidia_drv.so` and `libglxserver_nvidia.so` extracted from the version-matched official `.run` (570.172.08) |
| Runtime user | `kodi`, uid/gid 568 (the NAS "apps" identity), groups `video render audio`; profile under `/data` |
| Entry point | `kodi-xorg-entrypoint.sh` — brings up Xorg on the GPU output, then Kodi; SIGTERM-clean shutdown |

## Why not upstream's x11docker model

Upstream runs Kodi like an interactive desktop application: x11docker provides X and audio from
the host, and its prerequisites say *"If you're looking for a headless Kodi installation, look
elsewhere!"*. There is no desktop here. The container must:

* start **its own X server** on a GPU passed through to it, whose only output is HDMI to the TV;
* tolerate a host whose NVIDIA driver install creates **no `/dev/nvidia-modeset`**;
* use **host networking**, because SSDP discovery is multicast and does not traverse Docker's NAT bridge.

So: Xorg inside the container, Kodi unprivileged, no host X, no x11docker.

## The non-obvious parts

### 1. Kodi cannot hardware-decode 10-bit HEVC on NVIDIA, in any version

Kodi's VDPAU decoder maps only `VDP_DECODER_PROFILE_HEVC_MAIN` (8-bit) — the same in Matrix,
Nexus, Omega and current master — even though the GPU advertises `HEVC_MAIN_10`. So 4K HDR HEVC
falls back to software decoding while the TV shows HDR10.

`nvidia-vaapi-driver` sidesteps this: it exposes NVDEC through VA-API, so decoding arrives on a
path Kodi does hardware-accelerate. Measured on one 2160p DV/HDR HEVC remux:

| Decode path | CPU | Drops |
| --- | --- | --- |
| VDPAU (8-bit profile only) | 500–1789 % | constant |
| VA-API via `nvidia-vaapi-driver` | ~110–390 % | none |

`vainfo` should report `VAProfileHEVCMain10 : VAEntrypointVLD` through the
`VA-API NVDEC driver [direct backend]`. Verify before blaming playback.

### 2. Xorg cannot set a display mode without `/dev/nvidia-modeset`

The NVIDIA X driver needs it; some host driver installs (notably on TrueNAS) do not create it.
The entry point creates it inside the container:

```
mknod /dev/nvidia-modeset c 195 254
```

which requires the device cgroup rule `c 195:254 rwm` in the service definition. The X
configuration pins the GPU by BusID and the output by name, so X starts with no monitor
attached at boot:

```
BusID       "PCI:2:0:0"        # adjust to your GPU
Option      "ConnectedMonitor" "HDMI-0"
Option      "AllowEmptyInitialConfiguration" "true"
```

X DPMS is disabled (`xset -dpms s off s noblank`); otherwise X blanks the TV after the idle
timeout.

### 3. Not discoverable as a DLNA/UPnP renderer: the SSDP join fails with `ENOBUFS`

Kodi's libPlatinum joins `239.255.255.250` on **every** host interface. The kernel allows 20
memberships per socket by default; with ~46 interfaces `JoinGroup` fails with `ENOBUFS` and
Platinum aborts UPnP initialisation entirely — no SSDP socket, no renderer advertisement.

`net.ipv4.igmp_max_memberships` cannot be raised from compose `sysctls:` under
`network_mode: host` ("not allowed in host network namespace"), so a small privileged one-shot
sidecar raises it and a healthcheck gates Kodi's start on the value — Kodi must not initialise
UPnP before the limit is in place. The Kodi container also keeps ambient
`CAP_NET_ADMIN`/`CAP_NET_RAW` for the multicast join.

### 4. Audio, and making the TV switch to 23.976 Hz

`/dev/snd` is passed through and Kodi talks to ALSA directly (no audio daemon in the image).
Read the sink's capabilities before tuning anything (`/proc/asound/card*/eld#*`): a TV
typically advertises 2-channel LPCM plus 6-channel AC-3/DTS. Decoding and downmixing to stereo
loses the centre channel and LFE, so enable AC-3/DTS passthrough *only* for a sink that accepts
it. Kodi's audio output settings live in `guisettings.xml`; the passthrough codec flags also
exist under `<audiooutput>` in `advancedsettings.xml`.

`videoplayer.adjustrefreshrate = 2` (switch on start/stop) makes the TV follow the content's
refresh rate — 23.976 Hz for film — when the EDID advertises it.

## Deployment

```yaml
services:
  # Raise the SSDP membership limit before Kodi starts (see "non-obvious parts" #3).
  sysctl-init:
    image: docker:cli
    network_mode: host
    privileged: true
    restart: unless-stopped
    entrypoint:
      - /bin/sh
      - -c
      - |
        echo 256 > /proc/sys/net/ipv4/igmp_max_memberships
        exec sleep 100000000
    healthcheck:
      test: ["CMD-SHELL", "test \"$$(cat /proc/sys/net/ipv4/igmp_max_memberships)\" -ge 64"]
      interval: 5s
      retries: 12

  kodi:
    image: kodi-tv:21.3          # built from this repository
    container_name: kodi
    init: true
    restart: unless-stopped
    runtime: nvidia              # requires nvidia-container-toolkit on the host
    network_mode: host           # required for SSDP/DLNA (multicast)
    depends_on:
      sysctl-init:
        condition: service_healthy
    environment:
      - TZ=Europe/Berlin
      - NVIDIA_VISIBLE_DEVICES=all
      - NVIDIA_DRIVER_CAPABILITIES=all
    devices:
      - /dev/dri/card1           # adjust to your GPU nodes
      - /dev/dri/renderD128
      - /dev/tty0
      - /dev/tty1
      - /dev/snd
    device_cgroup_rules:
      - "c 195:254 rwm"          # /dev/nvidia-modeset, created by the entry point
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: 1
              capabilities: [gpu, compute, video, graphics, utility]
    volumes:
      - /srv/kodi/data-omega:/data        # Kodi profile (per Kodi version!)
      - /srv/media:/media:ro
      - /srv/recorded:/recorded:ro
```

## Build

The build context is `examples/nvidia-xorg-vaapi` from the deployment branch: `Dockerfile`,
`kodi-xorg-entrypoint.sh`, `kodi-xorg.conf`, `advancedsettings.xml`, `sources.xml.example`.

```
docker build -t kodi-tv:21.3 .
```

`advancedsettings.xml` and `sources.xml` are copied into the image as *seeds*: the entry point
only installs them when the profile has no copy, so your live configuration under `/data` is
never overwritten by a rebuild or an image update. **Set a real `<webserverpassword>`** — the
seed ships `CHANGE-ME`.

## Upgrades and rollback

Kodi migrates its SQLite library to the version's schema on first start, and that migration is
one-way. Keep one profile directory per Kodi version (here: `data` for Kodi 19, `data-omega`
for Kodi 21) and tag the previous image before switching:

```
docker tag kodi-tv:21.3 kodi-tv:previous
# rollback: point the stack back at the old tag and the old profile directory
```

## Security notes

* The webserver is password protected (`<webserverauthentication>true</webserverauthentication>`);
  that JSON-RPC port is the intended control surface.
* The EventServer is **unauthenticated by design** (JSON-RPC over TCP 9090, remote input on UDP
  9777). Keep it on a trusted LAN; never port-forward or reverse-proxy it.
* The image contains no credentials; everything is seeded from files you control.

## Attribution

Upstream's code, documentation and license are unchanged below. The fork adds the NVIDIA/Xorg
container design described above.

---

## Upstream README (unchanged)

# erichough/kodi

Dockerized [Kodi](https://kodi.tv/) with audio and video.

![Kodi screenshot](https://kodi.tv/sites/default/files/page/field_image/about--devices.jpg "Kodi screenshot")

## Features

* fully-functional [Kodi](https://kodi.tv/) installation in a [Docker](https://www.docker.com/) container
* **audio** ([ALSA or PulseAudio](https://kodi.wiki/view/Linux_audio)) and **video** (with optional OpenGL hardware 
  video acceleration) via [x11docker](https://github.com/mviereck/x11docker/)
* simple, Ubuntu-based image that adheres to the [official Kodi installation instructions](https://kodi.wiki/view/HOW-TO:Install_Kodi_for_Linux#Installing_Kodi_on_Ubuntu-based_distributions)
* clean shutdown of Kodi when its container is terminated

## Host Prerequisites

The host system will need the following:

1. **Linux** and [**Docker**](https://www.docker.com)

   This image should work on any Linux distribution with a functional Docker installation.
   
1. **A connected display and speaker(s)**

   If you're looking for a headless Kodi installation, look elsewhere!

1. **[X](https://www.x.org/) or [Wayland](https://wayland.freedesktop.org/)**

   Ensure that the packages for an X or Wayland server are present on the Docker host. Please consult your distribution's 
   documentation if you're not sure what to install. A display server does *not* need to be running ahead of time.

1. **[x11docker](https://github.com/mviereck/x11docker/)**

   `x11docker` allows Docker-based applications to utilize X and/or Wayland on the host. Please follow the `x11docker` 
   [installation instructions](https://github.com/mviereck/x11docker#installation) and ensure that you have a 
   [working setup](https://github.com/mviereck/x11docker#examples) on the Docker host.
       
## Usage

### Starting Kodi

Use `x11docker` to start the `erichough/kodi` Docker image. Detailing the myriad of `x11docker` options is beyond the 
scope of this document; please consult the [`x11docker` documentation](https://github.com/mviereck/x11docker/) to find 
the set of options that work for your setup.

Below is an example command (split into multiple lines for clarity) that starts Kodi with a fresh X.Org X server with
PulseAudio sound, hardware video acceleration, a persistent Kodi home directory, and a shared read-only Docker mount for
media files:

    $ x11docker --xorg                                 \
                --pulseaudio                           \
                --gpu                                  \
                --homedir /host/path/to/kodi/home      \
                -- -v /host/path/to/media:/media:ro -- \
                erichough/kodi
           
Note that the optional argument passed between a pair of `--` defines additional arguments to be passed to `docker run`.

### Stopping Kodi

You can shut down Kodi just as you normally would; i.e. by using the power menu from the Kodi home screen. 
Behind the scenes, the Docker container and `x11docker` processes will terminate cleanly.

You can also [terminate the container from the command line](doc/advanced.md#command-line-shutdown).

### Example systemd Service Unit

    [Unit]
    Description=Dockerized Kodi
    Requires=docker.service
    After=network.target docker.service
    
    [Service]
    ExecStartPre=/usr/bin/docker pull erichough/kodi
    ExecStart=/usr/bin/x11docker ... erichough/kodi
    Restart=always
    KillMode=process
    
    [Install]
    WantedBy=multi-user.target

## Advanced

The [advanced topics](doc/advanced.md) documentation describes a few more useful features and functionality:

 * [Custom add-ons](doc/advanced.md#custom-add-ons)
 * [Image Variants](doc/advanced.md#image-variants)
 * [Custom Startup Behavior](doc/advanced.md#custom-startup-behavior)
 * [Command-Line Shutdown](doc/advanced.md#command-line-shutdown)

## Help!

Something not working quite right? Are you stuck? Please ask your questions in the
[discussion group](https://github.com/ehough/docker-kodi/discussions), where we exchange help and share ideas.

## Contributing

Constructive criticism and contributions are welcome! Please 
[submit an issue](https://github.com/ehough/docker-kodi/issues/new) or 
[pull request](https://github.com/ehough/docker-kodi/compare).
