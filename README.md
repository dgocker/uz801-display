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
* **Battery charging**, with a state of charge derived from the vendor's own
  discharge curve, and a button that can finally switch the device off
* **Modem control from the browser** — network mode, LTE bands, APN, operator
  scan with one-click selection, and automatic rollback if the modem fails to
  register

## Install

Grab `boot.img` and `system.img` from [Releases](../../releases). You also need
the Firehose programmer for this SoC, which `edl` cannot supply on its own:

```sh
curl -sLO https://raw.githubusercontent.com/OneLabsTools/Programmers/master/prog_emmc_firehose_8916.mbn
```

Without `--loader` nothing works: `edl` finds the device, prints
`Mode detected: sahara` and waits forever, because it has no programmer to send
it. That looks exactly like a broken device and is the single most common way
to lose an hour here.

Getting into EDL is the part every guide gets wrong. Holding Reset does **not**
put this device into EDL: with the stock Android on it that lands in fastboot,
from which EDL needs a further command (`fastboot oem edl`). The method that
works whatever is installed is the hardware one: short `DP` to `GND` on the
board and, **holding the short**, plug in USB. That drops the SoC's boot ROM
straight into EDL, bypassing everything else.

Either way the device then enumerates as `05c6:9008` and stays in EDL until it
is reset or unplugged, so there is no hurry:

```sh
EDL="edl --loader=prog_emmc_firehose_8916.mbn --memory=eMMC"

$EDL w boot   openwrt-msm89xx-msm8916-yiming-uz801v3-squashfs-boot.img
$EDL w rootfs openwrt-msm89xx-msm8916-yiming-uz801v3-squashfs-system.img
edl --loader=prog_emmc_firehose_8916.mbn reset
```

That writes `boot` and `rootfs` only, and leaves the partition table, the
bootloaders and the radio partitions alone. **It works if the device already
runs OpenWrt** — coming from the stock Android is a different job, see below.

### Coming from the stock Android

The stock partition table has no `rootfs` at all: it carries `system`,
`userdata` and `cache` instead, so there is nowhere for those two commands to
write. A conversion needs the new partition table and the bootloaders as well,
and the radio partitions have to be saved and put back, because repartitioning
moves them — `modem` goes from sector 131072 to 7170, `persist` from 2067552 to
144386. Miss that and the IMEI and the radio calibration are gone.

`flash.sh`, `*-gpt_both0.bin` and `*-firmware.zip` in the release do all of it:

```sh
bash openwrt-msm89xx-msm8916-yiming-uz801v3-flash.sh
```

The conversion also removes `recovery`, `splash`, `userdata` and `cache`, along
with the backup copies of the bootloaders. Going back to Android means
restoring from a dump, the stock partition table included.

> `edl reset` must be called **without** `--memory=eMMC`. With that flag the
> command is misparsed and the device never restarts.

If the device does not come back after `reset`, **do not press the button** —
pull the USB cable and the battery for a few seconds instead. A boot that dies
early leaves the PMIC still holding power, and in that state it considers the
device to be running: no press of any length will start it, because there is
nothing to start. Removing power is the only way to clear it. See
[Power](#power).

Afterwards Wi-Fi comes up on its own (SSID `OpenWrt`, open — change it) and so
does USB networking. Set your APN under **Network → Modem**.

**Back up first**, and back up everything:

```sh
edl --loader=prog_emmc_firehose_8916.mbn --memory=eMMC rl backup
```

`modem`, `modemst1`, `modemst2`, `fsg`, `fsc` and `persist` hold the IMEI and
the radio calibration, and nothing can regenerate them. Resist the urge to
`--skip` the big partitions: `system` *is* Android, and without it the dump
cannot take you back, however complete the rest of it looks.

## Power

With the backlight lit the device draws noticeably more. Running it without
the battery on a weak USB port makes it brown out and reboot; with the battery
fitted it is stable.

**The button:** a short press wakes the screen, a double press shows the Wi-Fi
QR code, and a **hold of three seconds powers the device off**. Powering on is
a hold of a couple of seconds. Applying USB power also switches it on by
itself — that is the PMIC, which is built to wake for charging.

Two things about it are hardware, not firmware, and cannot be changed from
here:

* Holding the button for about **twelve seconds resets** the device. The PMIC
  does it on its own (`S1` 10.3 s then `S2` 2 s, warm reset), below the
  operating system entirely. Long holds are therefore counterproductive — the
  device starts, and the hold you are still applying restarts it.
* A **hung boot leaves the PMIC powered**. It keeps asserting `PS_HOLD`, so as
  far as it is concerned the device is already on and a press has nothing to
  do. Pull the cable and the battery for a few seconds; that is the only way
  out, and the twelve second reset above is the next best thing.

This is worth knowing because it looks exactly like a dead device. The PMIC
records what happened in `PON_REASON1` and `POFF_REASON1`, readable at
`/sys/kernel/debug/regmap/0-00/registers` (offsets `0x808` and `0x80c`): a
clean shutdown leaves `0x02` there — `PS_HOLD` — while a crash or a brown-out
leaves nothing at all.

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

## The battery never charged

Nothing in mainline enables `pm8916_charger`, so no driver ever programmed a
charge current: the cell got whatever the bootloader happened to leave, which
is little enough that a power bank sees no load at all and switches itself
off. The pack only ever discharged.

Enabling the charger by itself is what breaks USB networking, and it is not
obvious why. `pm8916_charger` and `pm8916_usbin` both claim register `0x1300`
and the `usb_vbus` interrupt, so the two fight over the block and the gadget
loses its VBUS source. The charger driver registers an extcon of its own, so
the fix is to hand USB over to it and retire `pm8916_usbin` rather than run
both:

```dts
&pm8916_charger { status = "okay"; };
&pm8916_usbin   { status = "disabled"; };
&usb            { extcon = <&pm8916_charger>; };
&usb_hs_phy     { extcon = <&pm8916_charger>; };
```

Every value comes from the stock Android device tree of this board, read back
from an EDL dump rather than guessed:

| property | value | where from |
|---|---|---|
| charge voltage | 4.20 V | `qcom,vddmax-mv` |
| safety trip | 4.35 V | `qcom,vddsafe-mv` |
| charge current | 1 A | `qcom,ibatsafe-ma` |
| cutoff | 3.30 V | `qcom,v-cutoff-uv` |
| internal resistance | 180 mΩ | `qcom,default-rbatt-mohm` |

Note the charge ceiling. The cell is labelled *maximum charging voltage
4.35 V*, and the vendor charged it to **4.20** anyway, keeping 4.35 as the trip
only. Following the label would overcharge the pack for its whole life.

### There is no percentage to read

`pm8916_bms_vm` implements `STATUS`, `VOLTAGE_NOW`, `VOLTAGE_OCV` and `HEALTH`
— and no `CAPACITY` at all. No amount of device tree work produces a
percentage, because the driver never publishes one. It is derived in
`update-display` instead, from the vendor's own discharge curve
(`qcom,pc-temp-ocv-lut` at 25 °C, also from the dump).

Three corrections make that estimate usable rather than decorative:

* **The curve, not a straight line.** A linear map of terminal voltage used to
  read 49 % and then 71 % thirty seconds later. The curve is flat through the
  middle and steep at both ends; linear is not an approximation of it.
* **The drop across the cell.** While charging, terminal voltage sits about
  `I × R` above the open circuit value the curve is indexed by — 1 A through
  180 mΩ, so 180 mV.
* **A speed limit.** 3000 mAh at 1 A gains about 1.7 % per minute, so the
  displayed value is not allowed to move faster than the chemistry can.

At boot the estimate anchors on `VOLTAGE_OCV`, which the hardware can only
measure while the system is off and the driver serves for 180 seconds
afterwards. That is exactly when the estimate restarts, and terminal voltage at
that moment is the worst possible input — sagging under the boot load and
riding high on charge current at once.

It is still an estimate from voltage, not a coulomb count: expect a few points
of error, and more while current is flowing.

Charging status comes from the charger, not the gauge. The gauge decides it
through `power_supply_am_i_supplied()`, which needs `power-supplies` on the
gauge itself — put on the battery node it is silently ignored, and the gauge
keeps answering `Discharging` while the charger is plainly pushing current into
the cell.

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
