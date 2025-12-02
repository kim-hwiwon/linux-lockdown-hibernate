#!/bin/sh

#
# usage: 1-patch-and-build.sh [kernel_ver]
#
#   Patch kernel source to enable hibernate on lockdown mode,
#   then build it into lockdown-hibernate kernel rpms.
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



### vars ###

kname="lckdn_hiber"
kver_full="$(printf "%s" "$TARGET_KVER_FULL" | sed "s/\.$kname\./\./g")"
kver_major_minor="$(printf "%s" "$kver_full" | cut -d. -f-2)"
kver_fver="$(printf "%s" "$kver_full" | cut -d. -f-4)"
kver_target="$(printf "%s" "$kver_full" | cut -d. -f-3).$kname.$(printf "%s" "$kver_full" | cut -d. -f4-)"
karch="$(printf "%s" "$kver_full" | cut -d. -f5)"
src_patch_name="v${kver_major_minor}.patch"
src_patch_link_base="https://github.com/kim-hwiwon/linux-lockdown-hibernate/raw/refs/heads/main/patch"
src_patch_link="${src_patch_link_base}/${src_patch_name}"
target_patch_name="lockdown-hibernate-${src_patch_name}"
workspace=~/.lckdn-hiber-workspace
workspace_kver="$workspace/$kver_full"
rpmbuild="${workspace_kver}/unpack${HOME}/rpmbuild"
rpmbuild_subdirs="BUILD RPMS SOURCES SPECS SRPMS"



### routine ###

# tmp workspace
mkdir -p "$workspace_kver" || exit 1
printf " - Temp workspace: \"%s\"\n" "$workspace_kver"

# skip if already exists
if [ -f "$rpmbuild/RPMS/$karch/kernel-${kver_target}.rpm" ]
then
  printf " - Previously built '.rpm' files already exists in '%s'! Build skipped.\n   If you want to rebuild it, remove dir '%s' and try again.\n" "$rpmbuild/RPMS/$karch" "$rpmbuild/RPMS/$karch"
  exit 0
fi

# search an appropriate patch file, if first target not exists
if ! wget --spider "$src_patch_link"
then
  patches="$(curl -sL https://api.github.com/repos/kim-hwiwon/linux-lockdown-hibernate/contents/patch?ref=main | jq -r .[].name | sort -Vr)"
  start_idx="$(printf "%s\n" "$src_patch_name" $patches | sort -Vr | grep -nm 1 "$src_patch_name" | cut -d: -f1)"
  patch_cands="$(printf "%s\n" $patches | awk "NR>=$start_idx {print}")"
  for cur_cand in $patch_cands
  do
    src_patch_link="${src_patch_link_base}/${cur_cand}"
    if wget --spider "$src_patch_link"
    then
      break
    fi
  done

  printf " * No appropriate candidate patch file found at '%s'!\n" "$src_patch_link_base" >&2
  exit 1
fi

# setup build system
(
  cd "$workspace_kver" || exit 1
  for dir in $rpmbuild_subdirs; do mkdir -p "$rpmbuild/$dir" || exit 1; done
  printf " - Downloading kernel source rpm...\n"
  koji download-build --arch=src "kernel-$kver_full" || exit 1
  printf " - Unpacking kernel source rpm...\n"
  rpm -Uvh "kernel-$kver_fver.src.rpm" --root="$workspace_kver/unpack" || exit 1
) || exit 1

# apply patches
(
  printf " - Getting & applying a kernel patch file...\n"
  wget "$src_patch_link" -O "$rpmbuild/SOURCES/$target_patch_name" || exit 1
  patch_list="$(grep -o "^Patch[0-9][0-9]*" "$rpmbuild/SPECS/kernel.spec" | cut -c6- | sort -r)"
  for last_patch in $patch_list
  do
    target_patch="$((last_patch - 1))"
    printf "%s\n" "$patch_list" | grep -qx "$target_patch" || break
  done
  sed -e "/^Patch${last_patch}/i Patch${target_patch}: ${target_patch_name}" \
      -e "/^ApplyOptionalPatch linux-kernel-test.patch/i ApplyOptionalPatch $target_patch_name" \
      -e "s/# define buildid .local/%define buildid .$kname/g" \
      -i "$rpmbuild/SPECS/kernel.spec" || exit 1
) || exit 1

# test prerequisites
(
  printf " - Preparing for kernel build...\n"
  deps_log="$workspace_kver/deps.log"
  if ! rpmbuild --define "_topdir $rpmbuild" -bp "$rpmbuild/SPECS/kernel.spec"
  then
    rpmbuild --define "_topdir $rpmbuild" -bp "$rpmbuild/SPECS/kernel.spec" 2>&1 \
      | tee "$deps_log" >/dev/null
    grep -q "^error: Failed build dependencies:\$" "$deps_log" || exit 1
    dep_list="$(awk '/^error: Failed build dependencies:$/{y=1;next;}y' "$deps_log" | cut -d' ' -f1 | tr -s '[:space:]' ' ' | sed 's/^ \(.*\) $/\1/g')" || exit 1
    printf "\n - Trying to run a dependency installation command:\n     'sudo dnf install -y %s'\n" "$dep_list"
    if ! [ -n "$LCKDN_HIBER_FORCE" ]
    then
      printf " * Continue? [y/N]: "
      read -r selection || exit 1
      [ "$selection" != "y" ] && [ "$selection" != "Y" ] && exit 1
    fi
    sudo dnf install -y $dep_list || exit 1
    rpmbuild --define "_topdir $rpmbuild" -bp "$rpmbuild/SPECS/kernel.spec" || exit 1
  fi
) || exit 1

# build kernel
(
  printf " - Building a new patched kernel...\n"
  time rpmbuild --define "_topdir $rpmbuild" -bb --with baseonly \
       --without debuginfo --target="$karch" \
       "$rpmbuild/SPECS/kernel.spec" || exit 1
) || exit 1

printf " + Built the kernel '%s'!\n" "${kver_target}"
