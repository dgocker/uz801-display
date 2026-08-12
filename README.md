# uz801-display

Working ST7735S/GC9107 SPI panel support and a status dashboard for MSM8916
4G LTE sticks (UZ801 v3.0 profile, MF601-family hardware) running OpenWrt.

The panel on these sticks is undocumented and no upstream device tree enables
it. Everything here was derived from the stock Android device tree dumped off
the device itself.

## What works

* 128x128 SPI panel via `fbtft` — `/dev/fb0`, framebuffer console
* Backlight through PM8916 MPP4 in current-sink mode
* Status dashboard: operator, network type, signal, SSID, IP, clients,
  battery, throughput
* Wi-Fi QR code (SSID + password) on a double press of the power button
* Custom boot logo
* **LTE data** via `zhihe-qmi` (ModemManager is deliberately absent)
* **Web UI** to change network mode, LTE bands and APN, scan for operators
  and pick one, with automatic rollback if the modem fails to register

## Hardware facts (from the stock Android DTB)

Dumped from the `boot` partition of the device (`qcom,board-id = <0x8 0x100>`):

| what | value |
|---|---|
| SPI bus | `spi@78b7000` = `blsp_spi3` (`aliases { spi0 = ... }`) |
| chip select | GPIO 10 |
| data/command | GPIO 23 |
| reset | GPIO 25 |
| panel power | `pm8916_l17` (2.85 V) |
| panel I/O power | `pm8916_l6` (1.8 V) |
| backlight | PM8916 **MPP4**, current sink (`lcdwled-backlight`) |
| panel | labelled `st7735s`, actually a **GC9107**-class controller |

### The panel is not an ST7735

The stock init sequence starts with `0xFE 0xEF` (inter-register enable) and
uses `0xEB/0xE8/0xE9/0xEA`, `0xC6/0xC7` — none of which exist on an ST7735.
That is a GalaxyCore GC9xxx register map. Driving it with `fb_st7735r`
leaves the panel white.

`patches/901-fbtft-fb_gc9107.patch` carries a GC9107 fbtft driver whose
`init_display()` is the stock sequence verbatim, including the `0xFE/0xEF`
unlock that the panel needs before it accepts any configuration.

### Chip select must be a GPIO

`blsp_spi3_default` in mainline muxes GPIO10 to plain `gpio` function and
parks it high, so the controller's native chip select never reaches the pin.
Without `cs-gpios` the panel is never selected: SPI clocks out data, the
backlight is on, and the screen still shows nothing. `spi-qup` sets
`use_gpio_descriptors`, so `cs-gpios = <&tlmm 10 GPIO_ACTIVE_LOW>` is all it
takes.

### GPIO conflicts with the upstream uz801 mapping

`msm8916-yiming-uz801v3.dts` describes a different board: it puts the restart
button on GPIO23 (the panel's D/C) and the green LED on GPIO8 (`blsp_spi3`
MOSI). Both are removed in `patches/806-*.patch`.

## Build

Built on top of [hkfuertes/msm8916-openwrt](https://github.com/hkfuertes/msm8916-openwrt),
which is what the known-good stock images for these sticks come from.

```sh
git clone https://github.com/hkfuertes/msm8916-openwrt
cd msm8916-openwrt
git clone --depth 1 -b v25.12.5 https://git.openwrt.org/openwrt/openwrt.git openwrt

# target + packages, per that project's workflow
./apply_patches.sh openwrt
cp -r msm89xx  openwrt/target/linux/msm89xx
cp -r packages openwrt/package/msm8916

# this repository
cp patches/*.patch            openwrt/target/linux/msm89xx/patches/
cp -r package/router-display  openwrt/package/msm8916/
cat config/kernel-additions.txt >> openwrt/target/linux/msm89xx/config-6.12

cd openwrt
./scripts/feeds update -a && ./scripts/feeds install -a
cp ../config/diffconfig_uz801 .config
export FORCE_UNSAFE_CONFIGURE=1     # building as root
make defconfig
make -j$(nproc)
```

Output: `bin/targets/msm89xx/msm8916/openwrt-msm89xx-msm8916-yiming-uz801v3-squashfs-{boot,system}.img`

### Kernel options that matter

`CONFIG_FB_TFT` has a hard `depends on FB_DEVICE`. Without
`CONFIG_FB_DEVICE=y` kconfig silently drops the whole driver and the build
succeeds with no display support at all — see `config/kernel-additions.txt`.

## Flashing

Only `boot` and `rootfs` are written; GPT, bootloaders and the radio
partitions are left alone.

```sh
edl w boot   openwrt-msm89xx-msm8916-yiming-uz801v3-squashfs-boot.img
edl w rootfs openwrt-msm89xx-msm8916-yiming-uz801v3-squashfs-system.img
edl reset
```

`edl reset` must be called **without** `--memory=eMMC`; with it the command
is misparsed and the device never restarts.

## Power

With the backlight actually lit the stick draws more than some USB ports will
supply — it browns out and reboots. Use a battery or a powered port.

## Display package

`package/router-display` renders straight into `/dev/fb0`:

* `router-display` — the renderer (FreeType text, vector widgets, QR)
* `update-display` — collects state and calls it
* `display-manager` — FIFO daemon: brightness, dim/off timers, lock screen
* `20_power_button` — single press wakes/refreshes, double press shows the QR

Layout tweaks do not need a reflash: rebuild the binary, copy it to
`/usr/bin/router-display` over the network, run `update-display`.

## The modem does not work with ModemManager

ModemManager leaves this modem in QMI operating mode `offline` and every
attempt to bring it online is refused with `InvalidTransition`; the SIM then
reads as missing even though `--uim-get-card-status` shows it present and
ready. postmarketOS documents the same for this device. The build therefore
ships `zhihe-qmi` (a netifd protocol driving `qmicli` directly, from
[ImMALWARE/uz801-openwrt](https://github.com/ImMALWARE/uz801-openwrt)) and no
ModemManager at all.

Two fixes were needed on top of the original:

* the netmask was matched against a hardcoded list of three values, so the /28
  this operator hands out silently became a /32 and the gateway was
  unreachable — it now derives the prefix from any mask;
* `device` was declared as `"device:device"`, which makes netifd and LuCI
  resolve it to a network interface: saving the interface page in the browser
  rewrote `/dev/wwan0qmi0` to `wwan0` and killed the connection until someone
  noticed. It is a plain string now, and the protocol rejects anything that is
  not a character device.

Operator selection goes over `AT+COPS` rather than QMI: this firmware answers
the QMI equivalent with a bare `Internal` error. It only works with the data
session down, which is why applying anything takes the interface down first.

## One owner for the QMI channel

The LCD dashboard, the info page and the control page all read through a
single ubus service (`modem-control`). Nothing else calls `qmicli`, so there
is no concurrency to get wrong, and a minute-long operator scan does not
freeze the display — readers get the cached values plus a `busy` flag.

Applying settings runs detached: rpcd aborts calls that outlive its timeout,
and an aborted apply used to leave the modem half-configured with the busy
flag stuck on, disabling every button in the UI until a reboot. The flag now
carries a timestamp and expires, and a failed registration restores the
previous mode, bands *and* operator.

## Credits

* [hkfuertes/msm8916-openwrt](https://github.com/hkfuertes/msm8916-openwrt) —
  the OpenWrt target these images are built from, and the original
  `router-display` package this one is based on
* [ImMALWARE/uz801-openwrt](https://github.com/ImMALWARE/uz801-openwrt) —
  `zhihe-qmi` and `luci-app-cellular-info`
* [msm8916-mainline](https://github.com/msm8916-mainline) — mainline support
  for these SoCs
