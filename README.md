# Lockdown Hibernate Linux
Automated build and installation of patched kernel + related system environments,  
that enables linux hibernation on kernel_lockdown mode (which is default on secure boot).

- Utilize a fixed-size encrypted swap partition for hibernation
- Inspired by the [guide to enable hibernation with secure boot](https://community.frame.work/t/guide-fedora-36-hibernation-with-enabled-secure-boot-and-full-disk-encryption-fde-decrypting-over-tpm2/25474)

# Note: WIP Repository

## Prerequisites
- Pre-installed Fedora distribution
- A partition for swap, bigger than your memory size

## System Environments
- Commands here should be run **PER MACHINE**  
  (DO NOT run this every time you build your new lockdown-hibernate kernel! It is sufficient to run only the first time)

### Install
```shell
# NOTE: set this 'SWAP_DEV_PATH' variable to where you want to install encrypted swap partition
#SWAP_DEV_PATH=/dev/nvme?n?p1234

# install encrypted swap
./fedora/system-environments/install/1-install-encrypted-swap.sh "$SWAP_DEV_PATH"

# create and install keys for signing every new lockdown-hibernate kernel on this system
./fedora/system-environments/install/2-install-kernel-signing-key.sh

# requires a reboot once you finish the script above and requesting MOK enrollment succeeded
```

### Uninstall
```shell
# remove encrypted swap
# note: this will not wipe the swap partition,
#       only disabling it by removing related entries from
#       '/etc/fstab' and '/etc/crypttab'
./fedora/system-environments/remove/1-remove-encrypted-swap.sh

# remove signing key on Fedora, and revoke cert from MOK manager on the current machine
./fedora/system-environments/remove/2-remove-kernel-signing-key.sh

# requires a reboot once you finish the script above and requesting MOK deletion succeeded
```

## Kernel Build
- Commands here should be run **PER KERNEL INSTALL**  

### Install
```shell
# build a patched kernel of the current running Fedora kernel
#
# e.g.) if current running kernel is 6.17.11-300.fc43.x86_64,
#       command below will build '6.17.11-300.lckdn_hiber.fc43.x86_64'
./fedora/kernel/install/1-patch-and-build.sh

# install, sign the kernel, then set appropriate params for it
#
# e.g.) if current running kernel is 6.17.11-300.fc43.x86_64,
#       command below will install '6.17.11-300.lckdn_hiber.fc43.x86_64' which is built above
./fedora/kernel/install/2-install.sh


# note: to install specific kernel version other than current one,
#       specify a full kernel version by command parameter
#       (the version provided should be an existing version at koji)
# e.g.)
# ./fedora/kernel/install/1-patch-and-build.sh 6.17.9-300.fc43.x86_64
# ./fedora/kernel/install/2-install.sh 6.17.9-300.fc43.x86_64
```

### Uninstall
```shell
# remove the lockdown hibernate kernel,
# corresponding to the current running Fedora kernel
#
# e.g.) if current running kernel is 6.17.11-300.fc43.x86_64,
#       command below will remove '6.17.11-300.lckdn_hiber.fc43.x86_64'
./fedora/kernel/remove/1-remove.sh


# note: to remove specific kernel version other than current one,
#       specify a full kernel version by command parameter
#       (the version provided should be an existing version on this machine)
# e.g.)
# ./fedora/kernel/remove/1-remove.sh 6.17.9-300.fc43.x86_64
```
