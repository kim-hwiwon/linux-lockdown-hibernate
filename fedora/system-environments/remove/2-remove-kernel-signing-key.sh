#!/bin/sh

# run as root if not
if [ "$(id -u)" -ne 0 ]
  then
  sudo true || { printf " *** Run as root! ***\n" >&2; exit 1; } || exit 1
  sudo -E "$0" "$@"; exit "$?"
fi

# all commands are basically root commands from now on



### vars ###

kname="lckdn_hiber"



### routine ###


# remove keys
(
  printf " - Removing certificate '%s'...\n" "$kname"
  if certutil -d /etc/pki/pesign -L -n "$kname" 2>/dev/null
  then
    certutil -d /etc/pki/pesign -F -n "$kname" || exit 1
  else
    printf " - No certificate found. Skipped.\n"
  fi
) || exit 1


# remove MOK keys
(
  printf " - Removing MOK keys...\n"
  key_idx_list="$(mokutil --list-enrolled --short | grep -n " $kname\$" | cut -d: -f1)"
  if [ -n "$key_idx_list" ]
  then

    trap 'ret=$?; [ -n "$tmpdir" ] && umount "$tmpdir"; rm -rf "$tmpdir"; exit $ret;' INT TERM HUP QUIT EXIT
    tmpdir="$(mktemp -d)" || exit 1
    mount -t tmpfs tmpfs "$tmpdir" || exit 1
    (
      cd "$tmpdir" || exit 1
      mokutil --export || exit 1
      der_file_list="$(for idx in $key_idx_list; do printf "MOK-%04d.der " "$idx"; done)"
      [ -n "$der_file_list" ] || exit 1
      printf " - Requesting certificate deletion to MOK...\n   Now enter any one-time password needed for 'Delete MOK' stage, which appears during the next reboot.\n"
      mokutil --delete $der_file_list || exit 1
    ) || exit 1
    rm -rf "$tmpdir"

    trap - INT TERM HUP QUIT EXIT

    printf " + Certificate deletion requested to MOK manager!\n"
    printf "\n ***** IMPORTANT *****\n   To finish certificate deletion:\n   1. Reboot the device.\n   2. MOK manager menu will appear during the reboot. Choose '"'Delete MOK'"'\n   3. Finish the rest procedures according to the screen.\n   (The one-time password you entered right before will be prompt during the enrollment.)\n"


  else

    printf " - No MOK key found. Skipped.\n"

  fi
) || exit 1
