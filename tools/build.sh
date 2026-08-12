#!/bin/bash
set -x
export FORCE_UNSAFE_CONFIGURE=1
cd /root/hk_build

chmod +x apply_patches.sh
./apply_patches.sh openwrt || exit 1

rm -rf openwrt/target/linux/msm89xx
cp -r msm89xx openwrt/target/linux/msm89xx || exit 1

cd openwrt
./scripts/feeds update -a
./scripts/feeds install -a

cp ../diffconfig_uz801 .config
make defconfig

echo '=== SANITY: target/device ==='
grep -E 'CONFIG_TARGET_BOARD|CONFIG_TARGET_.*_DEVICE_.*=y|ROOTFS_PARTSIZE|SQUASHFS' .config | head

make download -j8
make -j24 || make -j1 V=s
echo "=== BUILD FINISHED rc=$? ==="
