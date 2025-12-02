#!/bin/sh

#
# usage: 2-install.sh [kernel_ver]
#
#   Install built kernel rpms, sign, and set kernel parameters
#   to make kernel hibernate-enabled
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



### functions ###

print_bar() { ( a="$1"; w="${COLUMNS:-$(tput cols 2>/dev/null)}" || w=80; aw="${#a}"; lw="$(( ( w - aw ) / 2 ))"; rw="$(( w - aw - lw ))"; bl="$(printf "%*s" "$lw" "" | tr " " "_")"; br="$(printf "%*s" "$rw" "" | tr " " "_")"; printf "%s%s%s" "$bl" "$a" "$br" ) }

verify_signed() {
  (
    target_file="$1"
    shift
    unset verified
    for der_file in "$@"
    do
      pesigcheck -n 0 -c "$der_file" --in "$target_file" >/dev/null 2>/dev/null \
        && verified=1 && break
    done
    [ -n "$verified" ]  # return true if signed
  )
}



### vars ###

uid_before_sudo="${SUDO_UID:-0}"
home_before_sudo="$(getent passwd "$uid_before_sudo" | cut -d: -f6)"

kname="lckdn_hiber"
kver_full="$(printf "%s" "$TARGET_KVER_FULL" | sed "s/\.$kname\./\./g")"
kver_target="$(printf "%s" "$kver_full" | cut -d. -f-3).$kname.$(printf "%s" "$kver_full" | cut -d. -f4-)"
karch="$(printf "%s" "$kver_full" | cut -d. -f5)"
workspace="$home_before_sudo/.lckdn-hiber-workspace"
workspace_kver="$workspace/$kver_full"
rpmbuild="${workspace_kver}/unpack${home_before_sudo}/rpmbuild"

swap_label="lckdn-hiber-swp"
luksdev="luks-$swap_label"
unlocked_luksdev_path="/dev/mapper/$luksdev"
detected_luksdev_id="$(grep "^$luksdev" /etc/crypttab | tail -n1 | tr -s '[:space:]' | tr '[:space:]' ' ' | cut -d' ' -f2)"
detected_luksdev="${detected_luksdev_id:+$(blkid | tr -d '"' | grep "$detected_luksdev_id" | cut -d: -f1 | head -n1)}"

luksdev_uuid="$(blkid -o export "$detected_luksdev" | grep '^UUID=' | cut -d= -f2)"
unlocked_luksdev_uuid="$(blkid -o export "$unlocked_luksdev_path" | grep '^UUID=' | cut -d= -f2)"
if [ ! -n "$luksdev_uuid" ]
then
  printf " * Installed LUKS device for swap not detected!\n"
  exit 1
elif [ ! -n "$unlocked_luksdev_uuid" ]
then
  printf " * Installed swap device not detected!\n"
  exit 1
fi

vmlinuz_path="/boot/vmlinuz-${kver_target}"



### routine ###


# install kernel
(
  export IFS="
"
  r_list="$(find "$rpmbuild/RPMS/$karch" -maxdepth 1 -type f -name "*.rpm" ! -name "kernel-uki-*.rpm")" || exit 1
  dnf install ${LCKDN_HIBER_FORCE:+-y} $r_list || exit 1
) || exit 1


trap 'ret=$?; cd; [ -n "$tmpdir" ] && umount "$tmpdir"; rm -rf "$tmpdir"; exit $ret;' INT TERM HUP QUIT EXIT
tmpdir="$(mktemp -d)" || exit 1
mount -t tmpfs tmpfs "$tmpdir" || exit 1


# sign kernel if needed
(
  if ! (
      # check if the target kernel is verifiable by MOK manager
      cd "$tmpdir" || exit 1
      mokutil --export || exit 1
      key_idx_list="$(mokutil --list-enrolled --short | grep -n "^[0-9a-f]* $kname\$" | cut -d: -f1)"
      der_file_list="$(for idx in $key_idx_list; do printf "MOK-%04d.der " "$idx"; done)"
      [ -n "$der_file_list" ] || exit 1
      mkdir "$tmpdir/pesign-cert" || exit 1
      cp -f $der_file_list "$tmpdir/pesign-cert" || exit 1

      # verify signed
      verify_signed "$vmlinuz_path" "$tmpdir/pesign-cert/"*.der || exit 1
    )
  then

    printf "\n - Signing the kernel '%s'...\n" "$vmlinuz_path"

    # sign
    pesign --certificate "$kname" --in "$vmlinuz_path" \
           --sign --out "${vmlinuz_path}.signed" || exit 1

    # verify signed
    verify_signed "${vmlinuz_path}.signed" "$tmpdir/pesign-cert/"*.der \
      || { printf " * Signed file not verifiable by MOK manager!\n" >&2; exit 1; }
    mv "${vmlinuz_path}.signed" "$vmlinuz_path" || exit 1


    # update initramfs
    printf "\n - Updating initramfs...\n"
    dracut -f --kver="$kver_target" || exit 1

  else
    printf "\n - The kernel '%s' already signed and verifiable. Signing skipped.\n" "$vmlinuz_path"
  fi
) || exit 1


# Add kparam for the target kernel
(
  printf "\n - Modifying grub configurations for the kernel '%s'...\n" "$vmlinuz_path"
  grubby_before="$(grubby --info="$vmlinuz_path" | grep "^args=")"

  # remove new additional args first to prevent duplicates
  new_additional_args="lockdown_hibernate=1 rd.luks.uuid=luks-${luksdev_uuid} resume=UUID=${unlocked_luksdev_uuid}"
  grubby --remove-args="$new_additional_args" --update-kernel="$vmlinuz_path" || exit 1

  # build new args from old args
  old_args_export="$(grubby --info="$vmlinuz_path" | grep "^args=" | sed 's/^args=/old_args=/g')"
  if ! printf "%s" "$old_args_export" | grep -q "^old_args="
  then
    printf " * Unexpected output from 'grubby --info=\"%s\"'!\n" "$vmlinuz_path" >&2
    exit 1
  fi
  eval "$old_args_export"   # source $old_args
  new_args="$old_args $new_additional_args"

  # update to new args
  grubby --args="$new_args" --update-kernel="$vmlinuz_path" || exit 1
  printf "\n%s\n%s\n%s\n%s\n%s\n" \
         "$(print_bar "[ BEFORE ]")" \
         "$grubby_before" \
         "$(print_bar "[ AFTER ]")" \
         "$(grubby --info="$vmlinuz_path" | grep "^args=")" \
         "$(print_bar)"

  printf "\n - Grubby is used to set kernel parameters for the current installed kernel.\n   If you want to use another tool other than grubby, add following kernel parameters manually:\n%s\n%s\n%s\n" \
         "$(print_bar "[ PARAMETERS ]")" \
         "$new_additional_args" \
         "$(print_bar)"

  printf "\n *** WARNING: Refreshing the grub using the 'grub2-mkconfig' command will revert the current kernel parameter changes!\n              In that case, you need to set kernel parameters again by running the following command:\n%s\n%s\n%s\n" \
         "$(print_bar "[ COMMAND ]")" \
         "\"$0\" \"$TARGET_KVER_FULL\"" \
         "$(print_bar)"
) || exit 1


printf "\n + The kernel '%s' is installed, signed and parameters are set!\n" "$kver_target"
