#!/bin/bash
set -x
export FORCE_UNSAFE_CONFIGURE=1
cd /root/hk_build/openwrt
make -j24 || make -j1 V=s
echo "=== BUILD FINISHED rc=$? ==="
