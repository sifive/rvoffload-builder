# rvoffload-builder

## Instructions

1. Run `build.sh`, which build the files needed for run and test to share/.
2. Run `boot.sh`, which copy the static files for boot and test to assets/ and share/. It also bring-up the qemu-sys
3. Login with `root`
4. Run the following commands to prepare the drive
```
mount /dev/vda /mnt
mount -t proc none /mnt/proc
mount -t sysfs none /mnt/sys

mount -o bind /dev /mnt/dev
mount -t devpts devpts /mnt/dev/pts

mount -o bind /run /mnt/run

chroot /mnt /bin/bash
```
5. Run `/host_share/run_test.sh`
6. Wait for a while and it should show
```
search path: librvo.so
EXEC @run_initialize
result[0]: hal.buffer_view
1x1xi64=[29892]
```
