#!/bin/sh

PATTERN="${1?:"No pattern! Pass an argument like 'kernel-6.17.*'"}"
koji list-builds --quiet --package=kernel --state=COMPLETE --pattern="$PATTERN"
