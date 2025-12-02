#!/bin/sh

target_device="${1:?Device path missing}"

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

systemctl daemon-reload || exit 1

# test if already installed
(
  if grep -q "^$luksdev" /etc/crypttab
  then
    printf " * It seems that the same config is already installed. Check the /etc/crypttab file and remove the corresponding line if you really want.\n" >&2; exit 1
  fi

  if grep -q "^$unlocked_luksdev_path" /etc/fstab
  then
    printf " * It seems that the same config is already installed. Check the /etc/fstab file and remove the corresponding line if you really want.\n" >&2; exit 1
  fi
) || exit 1


# test size requirements for hibernation
(
  mem_size="$(free -b | grep "^Mem:" | tr -s '[:space:]' | cut -d' ' -f2)"
  dev_size="$(lsblk -bdnry "$target_device" | cut -d' ' -f4)"

  if [ ! "$mem_size" -gt 0 ] 2>/dev/null || [ ! "$dev_size" -gt 0 ] 2>/dev/null
  then
    printf " * Cannot get size of memory (%d) or device (%d)!\n" "$mem_size" "$dev_size"
    exit 1
  fi

  if [ "$((mem_size + 1048576))" -gt "$dev_size" ] 2>/dev/null
  then
    printf " * Not enough device size for hibernation!\n   - Mem: %s (%s)\n   - Device '%s': %s (%s)\n" \
           "$(numfmt --to=iec-i --suffix=B "$mem_size")" \
           "$(numfmt --to=si --suffix=B "$mem_size")" \
           "$target_device" \
           "$(numfmt --to=iec-i --suffix=B "$dev_size")" \
           "$(numfmt --to=si --suffix=B "$dev_size")"
    exit 1
  fi
) || exit 1


# set up LUKS
(
  # init a new LUKS partition for swap
  trap 'ret=$?; [ -n "$tmp_keyfile" ] && rm -f "$tmp_keyfile"; exit $ret;' INT TERM HUP QUIT EXIT
  tmp_keyfile=$(mktemp) || exit 1
  chmod 0000 "$tmp_keyfile" || exit 1
  dd if=/dev/random of="$tmp_keyfile" bs=512 count=1 status=none >/dev/null || exit 1

  # luksFormat
  (
    printf "\n - Creating a new LUKS device '%s'...\n" "$target_device"

    parent_dev_cand="${target_device%p*}"
    target_dev_partno="${target_device##"${parent_dev_cand}p"}"
    if [ -b "$parent_dev_cand" ] && [ "$target_dev_partno" -gt 0 ] 2>/dev/null
    then
      printf " - Parent device info (%s):\n\n%s\n\n\n" \
             "$parent_dev_cand" \
             "$(parted "$parent_dev_cand" print)" || exit 1
    else
      unset parent_dev_cand
      unset target_dev_partno
      printf " - TARGET device info:\n\n%s\n\n\n" "$(parted "$target_device" print)" || exit 1
    fi

    cryptsetup luksFormat "$target_device" "$tmp_keyfile" \
               --label="$luksdev" || exit 1
    if [ -n "$parent_dev_cand" ] && [ "$target_dev_partno" -gt 0 ] 2>/dev/null
    then
      parted "$parent_dev_cand" name "$target_dev_partno" "$luksdev"
    fi
    exit 0
  ) || exit 1


  # add tpm2 key to luks
  (
    printf "\n - Adding a tpm2 key to LUKS device...\n"

    # Add decryption key to tpm
    #--tpm2-pcrs=0+7 \
    systemd-cryptenroll --wipe-slot=all --tpm2-device=auto \
                        --unlock-key-file="$tmp_keyfile" "$target_device" \
      || exit 1
    rm -f "$tmp_keyfile"


    # add tpm config to /etc/crypttab

    target_uuid="$(blkid -o export "$target_device" | grep '^UUID=' | cut -d= -f2)" || exit 1

    # insert a linebreak if crypttab is not ending with it, before writing a config
    if [ "$(tail -c1 /etc/crypttab | wc -l)" -eq 0 ]
    then
      printf "\n" >> /etc/crypttab || exit
    fi

    # write crypttab config
    printf "\n - Appending config to '/etc/crypttab'...\n\n"
    printf '%s UUID=%s none discard,tpm2-device=auto # lockdown-hibernate <- !!! DO NOT EDIT THE NAME PART (%s) !!!\n' "$luksdev" "$target_uuid" "$luksdev" \
      | tee -a /etc/crypttab || exit 1
    systemctl daemon-reload || exit 1

    # open created luks device
    systemctl start "$luks_systemd_name" || exit 1
  ) || exit 1
) || exit 1


# set up swap
(
  # create new swap above luks
  (
    printf "\n - Creating a new swap above the LUKS device '%s'...\n" \
           "$unlocked_luksdev_path"

    # format as swap
    mkswap -q -L "$swap_label" "$unlocked_luksdev_path" || exit 1

    # insert a linebreak if fstab is not ending with it, before writing a config
    if [ "$(tail -c1 /etc/fstab | wc -l)" -eq 0 ]
    then
      printf "\n" >> /etc/fstab || exit
    fi

    # write fstab config
    printf "\n - Appending config to '/etc/fstab'...\n\n"
    printf '%s none swap defaults 0 0 # lockdown-hibernate <- !!! DO NOT EDIT THE NAME PART (%s) !!!\n' "$unlocked_luksdev_path" "$unlocked_luksdev_path" \
      | tee -a /etc/fstab || exit 1
    systemctl daemon-reload || exit 1
  ) || exit 1

  # test and swapon
  (
    systemctl stop "$luks_systemd_name" || exit 1
    free_before="$(free -h)" || exit 1
    systemctl start "$luks_systemd_name" || exit 1
    swapon "$unlocked_luksdev_path" || exit 1
    printf "\n - Memory info:\n%s\n%s\n%s\n%s\n%s\n" \
           "$(print_bar "[ BEFORE ]")" \
           "$free_before" \
           "$(print_bar "[ AFTER ]")" \
           "$(free -h)" \
           "$(print_bar)" || exit 1

  ) || exit 1
) || exit 1

# update initramfs
printf "\n - Updating initramfs...\n"
dracut -f || exit 1

printf " + Installed the encrypted swap '%s' on LUKS device '%s'!\n" "$unlocked_luksdev_path" "$target_device"
