#!/usr/bin/bash

set -x

PORT=${1:-2225}
PORT2=${2:-2325}

ASSETS_DIR=/nfs/teams/sw/share/yunh/share/rvoffload_tinyllama_test_material

mkdir -p assets
cp $ASSETS_DIR/fsfl-2.1.5-panda-gr6.ext4 assets/.
cp $ASSETS_DIR/fw_dynamic.elf assets/.
cp $ASSETS_DIR/1192296962-lanxin-x3m-moray-fp_HAPS100_mmode.dtb assets/.
cp $ASSETS_DIR/TinyLLama-i4f16-opt-tw.safetensors share/.
cp -r $ASSETS_DIR/qemu_moray .

./qemu_moray/run-qemu.sh \
  -device sifive-loader \
  -serial mon:stdio -serial null -nographic \
  -device '{"driver":"virtio-blk-device","drive":"disk0"}' \
  -drive id=disk0,file=assets/fsfl-2.1.5-panda-gr6.ext4,if=none,format=raw \
  -bios assets/fw_dynamic.elf \
  -dtb assets/1192296962-lanxin-x3m-moray-fp_HAPS100_mmode.dtb \
  -kernel share/Image \
  -device '{"driver":"virtio-9p-device","fsdev":"share","mount_tag":"host0"}' \
  -fsdev local,id=share,path=share,security_model=mapped \
  -append 'ip=dhcp cma=128M watchdog_thresh=300 workqueue.watchdog_thresh=300 console=ttySIF0,115200 earlycon'
