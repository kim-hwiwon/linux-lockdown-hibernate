#!/bin/sh

# run as root if not
if [ "$(id -u)" -ne 0 ]
  then
  sudo true || { printf " *** Run as root! ***\n" >&2; exit 1; } || exit 1
  sudo -E "$0" "$@"; exit "$?"
fi

# all commands are root from now on



### functions ###

print_bar() { ( a="$1"; w="${COLUMNS:-$(tput cols 2>/dev/null)}" || w=80; aw="${#a}"; lw="$(( ( w - aw ) / 2 ))"; rw="$(( w - aw - lw ))"; bl="$(printf "%*s" "$lw" "" | tr " " "_")"; br="$(printf "%*s" "$rw" "" | tr " " "_")"; printf "%s%s%s" "$bl" "$a" "$br" ) }



### vars ###

swap_label="lckdn-hiber-swp"
luksdev="luks-$swap_label"
unlocked_luksdev_path="/dev/mapper/$luksdev"
luks_systemd_name="systemd-cryptsetup@$(printf "%s" "$luksdev" | sed 's/-/\\x2d/g')"



### routine ###

# remove swap
(
  # remove from fstab
  fstab_config_line_no="$(grep -n "^$unlocked_luksdev_path" /etc/fstab | cut -d: -f1)"
  if [ ! -n "$fstab_config_line_no" ]
  then

    printf "\n * No installed swap found on /etc/fstab file.\n   If you edited /etc/fstab and the actual swap partition still exists, remove it manually.\n" >&2

  else
    printf "\n - Removing swap from /etc/fstab...\n"
    before_fstab="$(cat /etc/fstab)"

    if [ -b "$unlocked_luksdev_path" ]
    then
      swapoff "$unlocked_luksdev_path"
    fi
    sed -i.bak "${fstab_config_line_no}d" /etc/fstab || exit 1

    printf "\n%s\n%s\n%s\n%s\n%s\n\n" \
           "$(print_bar "[ BEFORE ]")" \
           "$before_fstab" \
           "$(print_bar "[ AFTER ]")" \
           "$(cat /etc/fstab)" \
           "$(print_bar)"
    printf "\n - If the change of fstab is unexpected, recover '/etc/fstab' from '/etc/fstab.bak' with the following command:\n%s\n   sudo mv /etc/fstab.bak /etc/fstab\n%s\n" \
           "$(print_bar "[ COMMAND ]")" \
           "$(print_bar)"

    systemctl daemon-reload || exit 1
  fi

  # erase swap label
  detected_swap_label="$([ -b "$unlocked_luksdev_path" ] && swaplabel "$unlocked_luksdev_path" | grep "^LABEL: " | cut -d' ' -f2)"
  [ "$detected_swap_label" = "$swap_label" ] && swaplabel -L "" "$unlocked_luksdev_path"
) || exit 1


# remove LUKS
(
  # disable luks, remove from crypttab
  crypttab_config_line_no="$(grep -n "^$luksdev" /etc/crypttab | cut -d: -f1)"
  detected_luksdev_id="$(grep "^$luksdev" /etc/crypttab | tail -n1 | tr -s '[:space:]' | tr '[:space:]' ' ' | cut -d' ' -f2)"
  detected_luksdev="${detected_luksdev_id:+$(blkid | tr -d '"' | grep "$detected_luksdev_id" | cut -d: -f1 | head -n1)}"
  if [ ! -n "$crypttab_config_line_no" ]
  then

    printf "\n * No installed luks device found on /etc/crypttab file.\n   If you edited /etc/crypttab and the actual luks device still exists, remove it manually.\n" >&2

  else
    printf "\n - Removing LUKS device from /etc/crypttab...\n"
    before_crypttab="$(cat /etc/crypttab)"

    if systemctl list-unit-files "$luks_systemd_name".service >/dev/null
    then
      systemctl stop "$luks_systemd_name".service || exit 1
    fi
    sed -i.bak "${crypttab_config_line_no}d" /etc/crypttab || exit 1

    printf "\n%s\n%s\n%s\n%s\n%s\n\n" \
           "$(print_bar "[ BEFORE ]")" \
           "$before_crypttab" \
           "$(print_bar "[ AFTER ]")" \
           "$(cat /etc/crypttab)" \
           "$(print_bar)"
    printf "\n - If the change of fstab is unexpected, recover '/etc/crypttab' from '/etc/crypttab.bak' with the following command:\n%s\n   sudo mv /etc/crypttab.bak /etc/crypttab\n%s\n" \
           "$(print_bar "[ COMMAND ]")" \
           "$(print_bar)"

    systemctl daemon-reload || exit 1
  fi

  # scan all block devs if not on crypttab
  if [ ! -n "$detected_luksdev" ]
  then
    detected_luksdev="$(blkid -s LABEL -s TYPE | grep -e ' LABEL="$luksdev" TYPE="crypto_LUKS"' | cut -d: -f1 | head -n1)"
  fi

  # wipe label if target luksdev detected
  if [ -n "$detected_luksdev" ]
  then
    cryptsetup config "$detected_luksdev" --label ""

    # clear label for gpt partition
    parent_dev_cand="${detected_luksdev%p*}"
    target_dev_partno="${detected_luksdev##"${parent_dev_cand}p"}"
    if [ -n "$parent_dev_cand" ] && [ "$target_dev_partno" -gt 0 ] 2>/dev/null
    then
      printf " \n" | parted "$parent_dev_cand" name "$target_dev_partno" "" >/dev/null
    fi
  fi
) || exit 1


# update initramfs
printf "\n - Updating initramfs...\n"
dracut -f || exit 1


# finish
printf "\n + Removing encrypted swap finished!\n"
if [ -f /etc/fstab.bak ] || [ -f /etc/crypttab.bak ]
then
  printf "\n - Check backup files ('/etc/fstab.bak', '/etc/crypttab.bak'), and remove them if no problem on new fstab and crypttab file.\n"
fi
