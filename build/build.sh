#!/bin/bash

# This is the actual build script that runs as the entrypoint for the
# container.  This will actually build the kernel and such,
#
# Build output will go to /kern.
# After this script completes, /kern will contain the config used to build the kernel,
# the actual kernel image, and the updated raspberry pi firmware.
# When build can be modified by environment variables, they will be listed below.
#
# Available env variables:
#   AUFS_ENABLE -> make the setup part patch the kernel source with aufs3.1-standalone and enable kern module. [default: YES]
#   PARALLEL_OPT -> set the value that make uses for -j (parallel execution) [default: 3]
#   PLATFORM -> set build platform [default: bcmrpi]
#   UPDATE_EXISTING -> if USE_EXISTING_SRC=YES, do we also run a pull to update the sources? [default: NO]
#   USE_EXISTING_SRC -> make the build system use existing sources, if present [default: NO]
#   USE_HARDFLOAT -> build the kernel with armhf support instead of soft-float. [default: YES]

# Functions for parsing source,dest pairs out of an array.
function arr_get_source() {
  declare -a array=("${!1}")
  idx=$2
  echo "${array[$idx]}" | awk '{ split($0, spl, ","); print spl[1] }'
}

function arr_get_dest() {
  declare -a array=("${!1}")
  idx=$2
  echo "${array[$idx]}" | awk '{ split($0, spl, ","); print spl[2] }'
}

# Repositories for aufs, firmware, and kernel.
AUFS_GIT="git://aufs.git.sourceforge.net/gitroot/aufs/aufs3-standalone.git"
AUFS_BRANCH="aufs3.18.1+"

RPI_FW_GIT="https://github.com/raspberrypi/firmware.git"
RPI_FW_BRANCH="master"
RPI_FW_SUBDIR="/boot"

RPI_KERN_GIT="https://github.com/raspberrypi/linux.git"
RPI_KERN_BRANCH="rpi-3.18.y"

# Directories.
AUFS_SOURCE="/data/aufs"
KERN_SOURCE="/data/rpi-linux"
FW_SOURCE="/data/rpi-firmware"

KERN_OUTPUT="/kern/linux"
MOD_OUTPUT="/kern/linux/modules"
FW_OUTPUT="/kern/firmware"

# Cross-compiler prefix
ARMHF_CC_PFX="/usr/bin/arm-linux-gnueabihf-"
ARMSF_CC_PFX="/usr/bin/arm-linux-gnueabi-"
CROSS_COMPILE=""

# Environment variables / defaults.
AUFS_ENABLE=${AUFS_ENABLE:-"YES"}
PARALLEL_OPT=${PARALLEL_OPT:-3}
PLATFORM=${PLATFORM:-"bcmrpi"}
UPDATE_EXISTING=${UPDATE_EXISTING:-"NO"}
USE_EXISTING_SRC=${USE_EXISTING_SRC:-"NO"}
USE_HARDFLOAT=${USE_HARDFLOAT:-"YES"}

# Files to patch into the kernel source from aufs source.
declare -a AUFS_PATCHES=( "aufs3-base.patch" "aufs3-kbuild.patch" "aufs3-loopback.patch" "aufs3-mmap.patch" \
               "aufs3-standalone.patch" "tmpfs-idr.patch" "vfs-ino.patch" )

declare -a AUFS_KERN_CPY=( "/fs,/" "/Documentation,/" "/include/uapi/linux/aufs_type.h,/include/uapi/linux/" )

declare -a FILE_APPEND_PATCH=( "header-y += aufs_type.h,${KERN_SOURCE}/include/uapi/linux/Kbuild" )

# Set the cross-compiler prefix.
if [[ "${USE_HARDFLOAT}" == "YES" ]] ; then
  echo ' [!] Compiling with HardFP.'
  export CROSS_COMPILE="${ARMHF_CC_PFX}"
elif [[ "${USE_HARDFLOAT}" != "YES" ]] ; then
  echo ' [!] Compiling with SoftFP.'
  export CROSS_COMPILE="${ARMSF_CC_PFX}"
fi

# Check the platform.
if [[ "${PLATFORM}" != "bcmrpi" && "${PLATFORM}" != "bcm2709" ]] ; then
  echo " [-] Invalid platform '${PLATFORM}'"
  exit 1
fi

# Echo out build settings.
echo " [!] ------------------- Repository Settings ------------------- [!]"
echo " [+] AUFS_GIT         => ${AUFS_GIT}"
echo " [+] AUFS_BRANCH      => ${AUFS_BRANCH}"
echo " [+] RPI_FW_GIT       => ${RPI_FW_GIT}"
echo " [+] RPI_FW_BRANCH    => ${RPI_FW_BRANCH}"
echo " [+] RPI_FW_SUBDIR    => ${RPI_FW_SUBDIR}"
echo " [+] RPI_KERN_GIT     => ${RPI_KERN_GIT}"
echo " [+] RPI_KERN_BRANCH  => ${RPI_KERN_BRANCH}"
echo " [!] ------------------- Source Directories -------------------- [!]"
echo " [+] AUFS_SOURCE      => ${AUFS_SOURCE}"
echo " [+] FW_SOURCE        => ${FW_SOURCE}"
echo " [+] KERN_SOURCE      => ${KERN_SOURCE}"
echo " [!] ---------------- Build / Install Variables ---------------- [!]"
echo " [+] KERN_OUTPUT      => ${KERN_OUTPUT}"
echo " [+] MOD_OUTPUT       => ${MOD_OUTPUT}"
echo " [+] FW_OUTPUT        => ${FW_OUTPUT}"
echo " [+] CROSS_COMPILE    => ${CROSS_COMPILE}"
echo " [!] ------------------ Environment Variables ------------------ [!]"
echo " [+] AUFS_ENABLE      => ${AUFS_ENABLE}"
echo " [+] PARALLEL_OPT     => ${PARALLEL_OPT}"
echo " [+] PLATFORM         => ${PLATFORM}"
echo " [+] UPDATE_EXISTING  => ${UPDATE_EXISTING}"
echo " [+] USE_EXISTING_SRC => ${USE_EXISTING_SRC}"
echo " [+] USE_HARDFLOAT    => ${USE_HARDFLOAT}"

# Check the availability of sources and if USE_EXISTING_SRC is
# set so we can override if one of the sources are not available.
( ( [[ ! -d ${AUFS_SOURCE} ]] || [[ ! -d ${FW_SOURCE} ]] || [[ ! -d ${KERN_SOURCE} ]] ) && \
  [[ "${USE_EXISTING_SRC}" != "NO" ]] ) && \
    echo " [-] Some or all source trees are missing, setting USE_EXISTING_SRC=NO." && \
    export USE_EXISTING_SRC="NO"

# Determine what to do with source directories.
if [[ "${USE_EXISTING_SRC}" == "NO" ]] ; then
  echo " [!] Cloning source, grab some popcorn because this will take a bit..."
  # Pull AUFS
  ( [[ -d ${AUFS_SOURCE} ]] && \
    rm -rf ${AUFS_SOURCE} && mkdir ${AUFS_SOURCE} ) || mkdir ${AUFS_SOURCE}
  echo " [*] Cloning AUFS source from ${AUFS_GIT}..."
  git clone --branch ${AUFS_BRANCH} ${AUFS_GIT} ${AUFS_SOURCE}
  # Sparse-clone the /boot subdir of raspberrypi/firmware
  ( [[ -d ${FW_SOURCE} ]] && \
    rm -rf ${FW_SOURCE} && mkdir ${FW_SOURCE} ) || mkdir ${FW_SOURCE}
  echo " [*] Sparse-cloning RPI firmware from ${RPI_FW_GIT}..."
  ( cd ${FW_SOURCE} && \
    git init && \
    git config core.sparsecheckout true && \
    echo ${RPI_FW_SUBDIR} >> .git/info/sparse-checkout && \
    git remote add -f origin ${RPI_FW_GIT} && \
    git pull origin ${RPI_FW_BRANCH} )
  # Pull the kernel source
  ( [[ -d ${KERN_SOURCE} ]] && \
    rm -rf ${KERN_SOURCE} && mkdir ${KERN_SOURCE} ) || mkdir ${KERN_SOURCE}
  echo " [*] Cloning RPI Linux kernel source from ${RPI_KERN_GIT}..."
  git clone --branch ${RPI_KERN_BRANCH} ${RPI_KERN_GIT} ${KERN_SOURCE}

elif [[ "${USE_EXISTING_SRC}" != "NO" ]] && [[ "${UPDATE_EXISTING}" != "NO" ]] ; then
  # Update AUFS source
  ( [[ -d ${AUFS_SOURCE} ]] && \
    cd ${AUFS_SOURCE} && \
    echo " [*] Attempting to update AUFS sources..."
    git pull origin && \
    git checkout origin/${AUFS_BRANCH} )
  # Update rpi firmware
  ( [[ -d ${FW_SOURCE} ]] && \
    cd ${FW_SOURCE} && \
    echo " [*] Attempting to update RPI firmware..."
    git pull origin ${RPI_FW_BRANCH} && \
    git checkout origin/${RPI_FW_BRANCH} )
  # Update kernel source
  ( [[ -d ${KERN_SOURCE} ]] && \
    cd ${KERN_SOURCE} && \
    echo " [*] Attempting to update RPI Linux kernel sources..."
    git pull origin && \
    git checkout origin/${RPI_KERN_BRANCH} )
fi

# Copy AUFS files into place.
for (( i=0 ; $i < ${#AUFS_KERN_CPY[@]}; i++ )) ; do
  SRCPATH="${AUFS_SOURCE}$(arr_get_source AUFS_KERN_CPY[@] $i)"
  DESTPATH="${KERN_SOURCE}$(arr_get_dest AUFS_KERN_CPY[@] $i)"
  echo " [*] Copying ${SRCPATH} to ${DESTPATH}.."
  cp -rp ${SRCPATH} ${DESTPATH}
done

# Perform simple append patches. (eg., for Kbuild header things)
for (( i=0 ; $i < ${#FILE_APPEND_PATCH[@]}; i++ )) ; do
  PATCHDATA="`arr_get_source FILE_APPEND_PATCH[@] $i`"
  PATCHFILE="`arr_get_dest FILE_APPEND_PATCH[@] $i`"
  if [[ -z `grep "${PATCHDATA}" ${PATCHFILE}` ]] ; then
    echo " [*] Appending '${PATCHDATA}' to ${PATCHFILE}.."
    echo ${PATCHDATA} >> ${PATCHFILE}
  else
    echo " [*] ${PATCHFILE} already contains '${PATCHDATA}', not appending."
  fi
done

# Perform AUFS patches in the kernel directory.
for (( i=0; $i < ${#AUFS_PATCHES[@]}; i++ )) ; do
  export PATCHPATH=${AUFS_SOURCE}/${AUFS_PATCHES[$i]}
  ( cd ${KERN_SOURCE} && \
    echo " [*] Applying patch '${PATCHPATH}' to kernel source tree." && \
    patch -p1 < ${PATCHPATH} )
  unset PATCHPATH
done

# Create output directories.
( [[ ! -d ${KERN_OUTPUT} ]] && mkdir ${KERN_OUTPUT} )
( [[ ! -d ${MOD_OUTPUT} ]] && mkdir ${MOD_OUTPUT} )
( [[ ! -d ${FW_OUTPUT} ]] && mkdir ${FW_OUTPUT} )

# Load the config, if present.
( [[ -d /config ]] && [[ -f /config/rpi-config ]] && \
  cd /data/rpi-linux && \
  cp /config/rpi-config .config ) || \
  echo " [-] No /config volume or no rpi-config in /config"

# Create a kernel from the bcmrpi defaults if no kernel config was provided.
# If a kernel config was provided, tell the build system to use the "old"
#  configuration and use PLATFORM defaults for all NEW symbols.
( [[ ! -f ${KERN_SOURCE}/.config ]] && \
  cd ${KERN_SOURCE} && \
  echo " [!] Building kern. conf. with defaults from PLATFORM=${PLATFORM}." && \
  make ARCH=arm PLATFORM=${PLATFORM} CROSS_COMPILE=${CROSS_COMPILE} ${PLATFORM}_defconfig ) ||
( [[ -f ${KERN_SOURCE}/.config ]] && \
  cd ${KERN_SOURCE} && \
  echo " [!] Building rpi-config with NEW symbol defaults from PLATFORM=${PLATFORM}." && \
  make ARCH=arm PLATFORM=${PLATFORM} CROSS_COMPILE=${CROSS_COMPILE} olddefconfig )

# ALWAYS enable loadable kernel module support
( [[ -z `grep "CONFIG_MODULES=" ${KERN_SOURCE}/.config` ]] && \
  cd ${KERN_SOURCE} && \
  echo "CONFIG_MODULES=y" >> .config )

# Set aufs to load as a module (aufs3-standalone)
( [[ "${AUFS_ENABLE}" == "YES" ]] && [[ -z `grep "CONFIG_AUFS_FS=" ${KERN_SOURCE}/.config` ]] && \
  cd ${KERN_SOURCE} && \
  echo "CONFIG_AUFS_FS=m" >> .config )

# Cross-compile kernel.
( cd ${KERN_SOURCE} && \
  make ARCH=arm PLATFORM=${PLATFORM} CROSS_COMPILE=${CROSS_COMPILE} -k -j ${PARALLEL_OPT} )

# Copy the kernel output to $KERN_OUTPUT
( cd ${KERN_SOURCE} && \
  cp -v arch/arm/boot/Image ${KERN_OUTPUT}/kernel.img )

# Build kernel modules.
( cd ${KERN_SOURCE} && \
  make ARCH=arm PLATFORM=${PLATFORM} modules_install INSTALL_MOD_PATH=${MOD_OUTPUT} )

# Copy new firmware.
( cp ${FW_SOURCE}${RPI_FW_SUBDIR}/*.dtb ${FW_OUTPUT} && \
  cp ${FW_SOURCE}${RPI_FW_SUBDIR}/*.elf ${FW_OUTPUT} && \
  cp ${FW_SOURCE}${RPI_FW_SUBDIR}/*.dat ${FW_OUTPUT} && \
  cp ${FW_SOURCE}${RPI_FW_SUBDIR}/bootcode.bin ${FW_OUTPUT} )

# Expose the config that was used to build the kernel.
( cp ${KERN_SOURCE}/.config ${KERN_OUTPUT}/rpi-config )