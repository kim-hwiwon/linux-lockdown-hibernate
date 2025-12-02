#!/bin/sh

# run as root if not
if [ "$(id -u)" -ne 0 ]
  then
  sudo true || { printf " *** Run as root! ***\n" >&2; exit 1; } || exit 1
  sudo -E "$0" "$@"; exit "$?"
fi

# all commands are basically root commands from now on



### functions ###

print_bar() { ( a="$1"; w="${COLUMNS:-$(tput cols 2>/dev/null)}" || w=80; aw="${#a}"; lw="$(( ( w - aw ) / 2 ))"; rw="$(( w - aw - lw ))"; bl="$(printf "%*s" "$lw" "" | tr " " "_")"; br="$(printf "%*s" "$rw" "" | tr " " "_")"; printf "%s%s%s" "$bl" "$a" "$br" ) }



### vars ###

kname="lckdn_hiber"

certutil -d /etc/pki/pesign -L -n "$kname" >/dev/null 2>/dev/null; keyset_exists="$?"
mokutil --list-enrolled --short | grep -q " $kname\$" >/dev/null 2>/dev/null; mok_exists="$?"



### routine ###

# development environments
dnf install -y fedpkg rpm-build rpmdevtools koji mokutil nss-tools pesign || exit 1

# tmpdir
trap 'ret=$?; [ -n "$tmpdir" ] && umount "$tmpdir"; rm -rf "$tmpdir"; exit $ret;' INT TERM HUP QUIT EXIT
tmpdir="$(mktemp -d)" || exit 1
mount -t tmpfs tmpfs "$tmpdir" || exit 1


# generate key set
(
  # check if valid state
  (
    # stop if enrolling is already requested
    if mokutil --list-new --short | grep -q " $kname\$" >/dev/null 2>/dev/null
    then
      printf " * A MOK certificate '%s' already in enrollment request list to MOK manager!\n   It seems that you are trying to install related key twice.\n   If you want to cancel all current import request including '%s',\n   run the following command 'sudo mokutil --revoke-import' yourself.\n" "$kname" "$kname" >&2
      exit 1
    fi
  ) || exit 1

  # key set generation
  (
    printf " - Generating a key set...\n"
    # generate a new key set if not exists
    if [ "$keyset_exists" -ne 0 ]
    then
      efikeygen --dbdir /etc/pki/pesign --common-name "CN=$kname" \
                --nickname "$kname" --self-sign --kernel 2>/dev/null || exit 1
    else
      printf " - A key set '%s' already exists on '/etc/pki/pesign'! Key set generation skipped.\n" "$kname"
    fi
  ) || exit 1
) || exit 1

# enroll mok
(
  if [ "$mok_exists" -eq 0 ]
  then
    # MOK manager already has a cert

    (
      if [ "$keyset_exists" -ne 0 ]
      then
        # but key set is generated above, which makes previous cert invalid

        printf " - A MOK certificate '%s' already enrolled on MOK manager!\n   Adding a new delete request to request queue before importing a new certificate...\n" "$kname"

        key_idx_list="$(mokutil --list-enrolled --short | grep -n "^[0-9a-f]* $kname\$" | cut -d: -f1)"
        (
          cd "$tmpdir" || exit 1
          mokutil --export || exit 1
          der_file_list="$(for idx in $key_idx_list; do printf "MOK-%04d.der " "$idx"; done)"
          [ -n "$der_file_list" ] || exit 1
          printf " - Requesting certificate deletion to MOK manager...\n   Now enter any one-time password needed for [Delete MOK] stage, which appears during the next reboot.\n   You can run this script again after the reboot and complete the deletion.\n"
          mokutil --delete $der_file_list || exit 1
        ) || exit 1
        printf " + Certificate deletion requested to MOK manager!\n"
        printf "\n ***** IMPORTANT *****\n   To finish certificate deletion:\n   1. Reboot the device.\n   2. MOK manager menu will appear during the reboot. Choose '"'Delete MOK'"'\n   3. Finish the rest procedures according to the screen.\n      (The one-time password you entered right before will be prompt during the enrollment.)\n"

        exit 0

      else
        # key is not generated above, no need to re-enroll
        exit 0
      fi

    ) || exit 1

  else
    # MOK manager does not have a cert

    # request enrollment
    (
      printf " - Exporting a certificate...\n"
      tmp_cert="$tmpdir"/crt
      certutil -d /etc/pki/pesign -Lr -n "$kname" > "$tmp_cert" || exit 1

      printf " - Requesting certificate enrollment to MOK manager...\n   Now enter any one-time password needed for [Enroll MOK] stage, which appears during the next reboot.\n"
      mokutil --import "$tmp_cert" || exit 1

      printf " + Certificate enrollment requested to MOK manager!\n"
      printf "\n ***** IMPORTANT *****\n   To finish certificate enrollment:\n   1. Reboot the device.\n   2. MOK manager menu will appear during the reboot. Choose '"'Enroll MOK'"'\n   3. Finish the rest procedures according to the screen.\n      (The one-time password you entered right before will be prompt during the enrollment.)\n"
    ) || exit 1

  fi
) || exit 1
