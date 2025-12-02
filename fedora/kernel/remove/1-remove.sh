#!/bin/sh

#
# usage: 1-remove.sh [kernel_ver]
#
#   Remove the specified lockdown-hibernate kernel
#
# <args>
#   - kernel_ver: full kernel version
#                 (which can be obtained with a command 'uname -r')
#     -> If set to lockdown-hibernate kernel,
#        it will be automatically converted to non-lockdown-hibernate version.
#        (e.g. '6.17.11-300.lckdn_hiber.fc43.x86_64' -> '6.17.11-300.fc43.x86_64')
#
# <envs>
#   - LCKDN_HIBER_FORCE: if set to any value, do not ask user and always say YES
#

TARGET_KVER_FULL="${1:-$(uname -r)}"
#LCKDN_HIBER_FORCE

# run as root if not
if [ "$(id -u)" -ne 0 ]
  then
  sudo true || { printf " *** Run as root! ***\n" >&2; exit 1; } || exit 1
  sudo -E "$0" "$@"; exit "$?"
fi

# all commands are basically root commands from now on



### vars ###

kname="lckdn_hiber"
kver_full="$(printf "%s" "$TARGET_KVER_FULL" | sed "s/\.$kname\./\./g")"
kver_target="$(printf "%s" "$kver_full" | cut -d. -f-3).$kname.$(printf "%s" "$kver_full" | cut -d. -f4-)"



### routine ###

# remove kernel
kver_to_rm="$kver_full"
if ! printf "%s" "$kver_to_rm" | grep -q "\.$kname\."
then
  kver_to_rm="$kver_target"
fi

dnf remove ${LCKDN_HIBER_FORCE:+-y} 'kernel*-*:'"$kver_to_rm" || exit 1
rm -rf /lib/modules/"$kver_to_rm"

printf " + Removed the kernel '%s'!\n" "${kver_target}"
