#!/bin/sh

# run as root if not
if [ "$(id -u)" -ne 0 ]
  then
  sudo true || { printf " *** Run as root! ***\n" >&2; exit 1; } || exit 1
  sudo "$0" "$@"; exit "$?"
fi

# all commands are basically root commands from now on

# remove keys
while true
do
  certutil -d /etc/pki/pesign -L || exit 1
  printf " - Cert to remove (Exit if empty): "; read -r input
  if [ -z "$input" ]
  then
    break
  else
    if certutil -d /etc/pki/pesign -D -n "$input"
    then
      printf "   + Removed '%s'!\n" "$input"
    else
      printf "   * Failed to remove '%s'\n" "$input"
    fi
  fi
done
