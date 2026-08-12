# uz801-display

OpenWrt for MSM8916 mobile hotspots (MF601SL / UZ801 v3.0 / Xunyou D623 /
UFI103) **with the built-in screen working** — plus a status dashboard, a
Wi-Fi QR code, and a web UI to control the modem.

These are battery-powered MiFi units with a 128×128 SPI panel, not USB
dongles. The panel is undocumented and no upstream device tree enables it;
everything here was derived from the stock Android device tree dumped off the
device itself.

[Русская версия](README_ru.md)

[![Donate](https://img.shields.io/badge/Donate-DonationAlerts-FF6B00?style=for-the-badge)](https://www.donationalerts.com/r/dgocker)

**If this saved you a weekend, [buy me a coffee](https://www.donationalerts.com/r/dgocker).**

---

## What works

* **Screen** — 128×128 SPI panel, backlight, kernel console during boot
* **Dashboard** — operator, network type, signal, SSID, IP, client count,
  battery, throughput
* **Wi-Fi QR code** with SSID and password, on a double press of the button
* **Custom boot logo**
* **LTE**, Wi-Fi AP, USB networking
* **Modem control from the browser** — network mode, LTE bands, APN, operator
  scan with one-click selection, and automatic rollback if the modem fails to
  register

## Install

Grab `boot.img` and `system.img` from [Releases](../../releases), put the
device into EDL (hold Reset while plugging in USB — it enumerates as
`05c6:9008`), then:

```sh
edl w boot   openwrt-msm89xx-msm8916-yiming-uz801v3-squashfs-boot.img
edl w rootfs openwrt-msm89xx-msm8916-yiming-uz801v3-squashfs-system.img
edl reset
```

Only `boot` and `rootfs` are written. The partition table, the bootloaders and
the radio partitions (IMEI, calibration) are left alone.

> `edl reset` must be called **without** `--memory=eMMC`. With that flag the
> command is misparsed and the device never restarts.

Afterwards Wi-Fi comes up on its own (SSID `OpenWrt`, open — change it) and so
does USB networking. Set your APN under **Network → Modem**.

**Back up first.** Dump every partition over EDL before you start, especially
`modem`, `modemst1`, `modemst2`, `fsg`, `fsc` and `persist` — they hold the
IMEI and the radio calibration, and nothing can regenerate them.

## Power

With the backlight lit the device draws noticeably more. Running it without
the battery on a weak USB port makes it brown out and reboot; with the battery
fitted it is stable.

When the device is off and running from battery, it powers on with a **long
press** of the button — that is the PMIC's behaviour, not the firmware's.

---

## Why the screen did not work anywhere

Four independent reasons, each of which on its own leaves the panel dark.

### 1. It is not an ST7735, despite the label

The stock device tree calls the panel `st7735s`. Its init sequence, however,
opens with `0xFE 0xEF` (inter-register enable) and uses `0xEB`, `0xE8`,
`0xE9`, `0xC6`, `0xC7` — registers an ST7735 does not have. That is a
GalaxyCore GC9xxx register map.

`fb_st7735r` sends commands the controller does not understand and the panel
stays white. And without `0xFE`/`0xEF` the controller ignores *all* subsequent
configuration — those two commands were missing from the GC9107 driver found
in other repositories too.

`patches/901-fbtft-fb_gc9107.patch` carries a GC9107 driver whose
`init_display()` is the vendor sequence verbatim.

### 2. Chip select is parked high

Mainline muxes GPIO10 — the chip select of `blsp_spi3` — as a plain GPIO and
parks it high, so the SPI controller cannot drive it. The panel is never
selected: the clock runs, data goes out, the chip ignores all of it.

`spi-qup` sets `use_gpio_descriptors`, so one line fixes it:

```dts
cs-gpios = <&tlmm 10 GPIO_ACTIVE_LOW>;
```

This one masked the first: nothing reached the panel at all, so no amount of
driver work could have shown a difference.

### 3. The backlight is a current sink, not a GPIO

The backlight hangs off PM8916 **MPP4**, configured by the stock firmware as a
current sink (`MODE_CTL = 0x60`, mode `110`) at 10 mA. Declared as a logic
output it only glitches when the level changes — the screen blinks once and
goes dark. It needs `function = "sink"`.

### 4. The driver silently does not build

`CONFIG_FB_TFT` has a hard `depends on FB_DEVICE`. Without `CONFIG_FB_DEVICE=y`
kconfig drops the whole driver, **the build succeeds without a single error**,
and the resulting firmware simply has no display support. The only way to
catch it is to check `System.map`.

### Pinout

From the stock Android DTB (`qcom,board-id = <0x8 0x100>`):

| what | value |
|---|---|
| SPI bus | `spi@78b7000` = `blsp_spi3` (`aliases { spi0 = … }`) |
| chip select | GPIO 10 |
| data/command | GPIO 23 |
| reset | GPIO 25 |
| panel power | `pm8916_l17` (2.85 V) |
| panel I/O power | `pm8916_l6` (1.8 V) |
| backlight | PM8916 MPP4, current sink |

`msm8916-yiming-uz801v3.dts` upstream describes a different board: it puts the
restart button on GPIO23 (the panel's D/C) and the green LED on GPIO8
(`blsp_spi3` MOSI). Both are removed in `patches/806-*.patch`.

---

## The modem does not work with ModemManager

ModemManager leaves this modem in QMI operating mode `offline`, refuses every
attempt to bring it online (`InvalidTransition`), and reports `sim-missing` —
while `--uim-get-card-status` shows the card present and ready and the IMSI
reads fine. postmarketOS documents the same for this device.

So there is no ModemManager here at all. The data session is brought up by
**zhihe-qmi**, a netifd protocol driving `qmicli` directly (from
[ImMALWARE/uz801-openwrt](https://github.com/ImMALWARE/uz801-openwrt)), with
two fixes on top:

* **Netmask.** It was matched against a hardcoded list of three values, so the
  `/28` this operator hands out silently became a `/32` and the gateway was
  unreachable. The prefix length is now derived from any mask.
* **`device`.** Declared as `"device:device"`, which makes netifd and LuCI
  resolve it to a *network interface*: saving the interface page in the browser
  rewrote `/dev/wwan0qmi0` to `wwan0` and killed the connection. Nasty because
  it breaks later, after a completely harmless action. It is a plain string
  now, and the protocol rejects anything that is not a character device.

Operator selection goes over `AT+COPS`, not QMI: this firmware answers the QMI
equivalent with a bare `Internal` error. It only works with the data session
down, which is why applying anything takes the interface down first.

## One owner for the QMI channel

The LCD dashboard, the info page and the control page all read through a single
ubus service (`modem-control`). Nothing else calls `qmicli`, so there is no
concurrency to get wrong, and a minute-long operator scan does not freeze the
display — readers get cached values plus a `busy` flag.

```
   LCD dashboard ─┐
   Cellular Info ─┼──►  ubus modem  ──►  qmicli  ──►  modem
   Modem control ─┘        + cache
```

Applying settings runs **detached**: rpcd aborts calls that outlive its
timeout, and an aborted apply used to leave the modem half-configured with the
busy flag stuck on, disabling every button until a reboot. The flag now carries
a timestamp and expires, and a failed registration restores the previous mode,
bands *and* operator.

## Packages

| package | what it does |
|---|---|
| `router-display` | the renderer (FreeType text, vector widgets, QR), the FIFO daemon with dim/off timers, the button handler and the boot logo |
| `zhihe-qmi` | netifd protocol for the LTE data session, plus its LuCI page |
| `modem-control` | the ubus service and the **Network → Modem** page |
| `luci-app-cellular-info` | signal, cell and neighbour information |

Layout tweaks do not need a reflash: rebuild `router-display`, copy it to
`/usr/bin/router-display` over the network and run `update-display`.

---

## Build

Built on top of
[hkfuertes/msm8916-openwrt](https://github.com/hkfuertes/msm8916-openwrt),
which is where the known-good stock images for these devices come from.

CI does this automatically — see `.github/workflows/build.yml`, which caches
downloads, the toolchain and ccache, so repeat builds are much faster than the
first one. By hand:

```sh
git clone https://github.com/hkfuertes/msm8916-openwrt upstream
git clone --depth 1 -b v25.12.5 https://git.openwrt.org/openwrt/openwrt.git openwrt

cd upstream
./apply_patches.sh ../openwrt
cp -r msm89xx  ../openwrt/target/linux/msm89xx
cp -r packages ../openwrt/package/msm8916
cd ..

cp patches/*.patch  openwrt/target/linux/msm89xx/patches/
cp -r package/*     openwrt/package/msm8916/
cat config/kernel-additions.txt >> openwrt/target/linux/msm89xx/config-6.12

cd openwrt
./scripts/feeds update -a && ./scripts/feeds install -a
cp ../config/diffconfig_uz801 .config
make defconfig
make -j$(nproc)
```

Output lands in `bin/targets/msm89xx/msm8916/`.

Check that the device tree compiles *before* starting a full build — a typo
there is the most common way this dies, forty minutes in:

```sh
make target/linux/prepare
```

## Support

This was reverse-engineered from a stock Android DTB over a lot of evenings,
and it is given away for free. If it was useful:

**[donationalerts.com/r/dgocker](https://www.donationalerts.com/r/dgocker)**

## Credits

* [hkfuertes/msm8916-openwrt](https://github.com/hkfuertes/msm8916-openwrt) —
  the msm89xx target these images are built from, and the original
  `router-display` package
* [ImMALWARE/uz801-openwrt](https://github.com/ImMALWARE/uz801-openwrt) —
  `zhihe-qmi`, `luci-app-cellular-info`, and the idea of dropping ModemManager
* [msm8916-mainline](https://github.com/msm8916-mainline) — mainline support
  for these SoCs

Discussion (Russian): [4PDA](https://4pda.to/forum/index.php?showtopic=1125029)
