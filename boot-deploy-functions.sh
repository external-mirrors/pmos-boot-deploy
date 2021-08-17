#!/bin/sh
set -u

# Declare used deviceinfo variables to pass shellcheck (order alphabetically)
deviceinfo_append_dtb=""
deviceinfo_arch=""
deviceinfo_bootimg_append_seandroidenforce=""
deviceinfo_bootimg_blobpack=""
deviceinfo_bootimg_dtb_second=""
deviceinfo_bootimg_mtk_mkimage=""
deviceinfo_bootimg_pxa=""
deviceinfo_bootimg_qcdt=""
deviceinfo_dtb=""
deviceinfo_flash_offset_base=""
deviceinfo_flash_offset_kernel=""
deviceinfo_flash_offset_ramdisk=""
deviceinfo_flash_offset_second=""
deviceinfo_flash_offset_tags=""
deviceinfo_flash_pagesize=""
deviceinfo_generate_bootimg=""
deviceinfo_generate_legacy_uboot_initfs=""
deviceinfo_mkinitfs_postprocess=""
deviceinfo_kernel_cmdline=""
deviceinfo_legacy_uboot_load_address=""
deviceinfo_flash_kernel_on_update=""

# getopts / get_options set the following 'global' variables:
kernel_filename=
initfs_filename=
input_dir=
output_dir="/boot"
additional_files=
deviceinfo="/etc/deviceinfo"

usage() {
	printf "Usage:
    %s -i <file> -k <file> -d <path> [-o <path>] [files...]
Where:
    -i  filename of the initfs in the input directory
    -k  filename of the kernel in the input directory
    -d  path to directory containing input initfs, kernel  
    -o  path to output directory {default: /boot}
    -c  path to deviceinfo {default: /etc/deviceinfo}

	Additional files listed are copied from the input directory into the output directory as-is\n" "$0"
}

get_options() {
	while getopts k:i:d:o:c: opt
	do
		case $opt in
			k)
				kernel_filename="$OPTARG";;
			i)
				initfs_filename="$OPTARG";;
			d)
				input_dir="$OPTARG";;
			o)
				output_dir="$OPTARG";;
			c)
				deviceinfo="$OPTARG";;
			?)
				usage
				exit 0
		esac
	done
	shift $((OPTIND - 1))
	additional_files=$*

	if [ -z "$kernel_filename" ]; then
		usage
		exit 1
	fi
	if [ -z "$initfs_filename" ]; then
		usage
		exit 1
	fi
	if [ -z "$input_dir" ]; then
		usage
		exit 1
	fi

	if [ ! -d "$input_dir" ]; then
		echo "Input directory does not exist: $output_dir"
		exit 1
	fi

	for f in "$kernel_filename" "$initfs_filename" $additional_files; do
		if [ ! -f "$input_dir/$f" ]; then
			echo "File does not exist: $input_dir/$f"
			exit 1
		fi
	done
}

# Return the free space (bytes) for the mount point that contains the given
# path. This only returns 90% of the actual free space, to avoid possibly
# filling the filesystem
# $1: Path
get_free_space() {
	[ -z "$1" ] && echo "No path given to free space check" && exit 1

	# note: tr is used to reduce extra spaces in df output to a single space,
	# so cut fields are consistent
	_df_out="$(df -P "$1" | tr -s ' ' | tail -1 | cut -d' ' -f4)"
	# 
	_df_out="$(echo "$_df_out"/0.9 | bc -s)"
	echo "$_df_out"
}

source_deviceinfo() {
	if [ ! -e "$deviceinfo" ]; then
		echo "ERROR: $deviceinfo not found!"
		exit 1
	fi
	# shellcheck disable=SC1090
	. "$deviceinfo"
}

# Required command check with useful error message
# $1: command (e.g. "mkimage")
# $2: package (e.g. "u-boot-tools")
# $3: related deviceinfo variable (e.g. "generate_bootimg")
require_package()
{
	[ "$(command -v "$1")" = "" ] || return
	echo "ERROR: 'deviceinfo_$3' is set, but the package '$2' was not"
	echo "installed!"
	exit 1
}

# Copy src (file) to dest (file), verifying checksums and replacing dest
# atomically (or as atomically as probably possible?)
# $1: src file to copy
# $2: destination file to copy to
copy() {
	_src="$1"
	_dest="$2"
	_dest_dir="$(dirname "$_dest")"

	[ ! -d "$_dest_dir" ] && mkdir -p "$_dest_dir"

	# checksum src, and copy to temp file @ dest
	_src_chksum="$(md5sum "$_src" | cut -d' ' -f1)"
	_dest_tmp="${_dest}".tmp
	cp "$_src" "$_dest_tmp"
	_dest_chksum="$(md5sum "$_dest_tmp" | cut -d' ' -f1)"

	sync "$_dest_dir"

	if [ "$_src_chksum" != "$_dest_chksum" ]; then
		echo "Checksums do not match: $_src --> ${_dest}.tmp"
		echo "Have: $_src_chksum, expected: $_dest_chksum"
		exit 1
	fi

	mv "$_dest_tmp" "$_dest"

	sync "$_dest_dir"
}

# Append the correct device tree to the linux image file or copy the dtb to the boot partition
append_or_copy_dtb() {
	[ -n "${deviceinfo_dtb}" ] || return
	echo "==> kernel: device-tree blob operations"
	dtb=""
	for filename in $deviceinfo_dtb; do
		if ! [ -e "/usr/share/dtb/$filename.dtb" ]; then
			echo "ERROR: File not found: /usr/share/dtb/$filename.dtb"
			exit 1
		fi
		dtb="$dtb /usr/share/dtb/$filename.dtb"
	done
	_outfile="$input_dir/$kernel_filename-dtb"
	if [ "${deviceinfo_append_dtb}" = "true" ]; then
		echo "==> kernel: appending device-tree ${deviceinfo_dtb}"
		cat "$input_dir/$kernel_filename" "$dtb" > "$_outfile"
		additional_files="$additional_files $(basename "$_outfile")"
	else
		for filename in $deviceinfo_dtb; do
			copy "/usr/share/dtb/$filename.dtb" "$input_dir/${filename}.dtb"
			additional_files="$additional_files ${filename}.dtb"
		done
	fi
}

# Add Mediatek header to kernel & initramfs
add_mtk_header() {
	[ "${deviceinfo_bootimg_mtk_mkimage}" = "true" ] || return
	require_package "mtk-mkimage" "mtk-mkimage" "bootimg_mtk_mkimage"

	_infile="$input_dir/$initfs_filename"
	_outfile="$input_dir/$initfs_filename.mtk"
	echo "==> initramfs: adding Mediatek header"
	mtk-mkimage ROOTFS "$_infile" "$_outfile"
	copy "$_outfile" "$_infile"
	rm "$_outfile"

	echo "==> kernel: adding Mediatek header"
	# shellcheck disable=SC3060
	kernel="$input_dir/$kernel_filename"
	rm -f "${kernel}-mtk"
	mtk-mkimage KERNEL "$kernel" "${kernel}-mtk"
	additional_files="$additional_files $(basename "${kernel}"-mtk)"
}

# Legacy u-boot images
create_uboot_files() {
	arch="arm"
	if [ "${deviceinfo_arch}" = "aarch64" ]; then
		arch="arm64"
	fi

	[ "${deviceinfo_generate_legacy_uboot_initfs}" = "true" ] || return
	require_package "mkimage" "u-boot-tools" "generate_legacy_uboot_initfs"

	echo "==> initramfs: creating uInitrd"
	_infile="$input_dir/$initfs_filename"
	_outfile="$input_dir/uInitrd"
	mkimage -A $arch -T ramdisk -C none -n uInitrd -d "$_infile" \
		"$_outfile" || exit 1

	echo "==> kernel: creating uImage"
	kernelfile="$input_dir/$kernel_filename"
	if [ "${deviceinfo_append_dtb}" = "true" ]; then
		kernelfile="$input_dir/$kernel_filename-dtb"
	fi

	if [ -z "$deviceinfo_legacy_uboot_load_address" ]; then
		deviceinfo_legacy_uboot_load_address="80008000"
	fi

	# shellcheck disable=SC3060
	mkimage -A $arch -O linux -T kernel -C none -a "$deviceinfo_legacy_uboot_load_address" \
		-e "$deviceinfo_legacy_uboot_load_address" \
		-n postmarketos -d "$kernelfile" "$input_dir/uImage" || exit 1
	additional_files="$additional_files uImage uInitrd"
}

# Android devices
create_bootimg() {
	[ "${deviceinfo_generate_bootimg}" = "true" ] || return
	# shellcheck disable=SC3060
	bootimg="$input_dir/boot.img"

	if [ "${deviceinfo_bootimg_pxa}" = "true" ]; then
		require_package "pxa-mkbootimg" "pxa-mkbootimg" "bootimg_pxa"
		MKBOOTIMG=pxa-mkbootimg
	else
		require_package "mkbootimg-osm0sis" "mkbootimg" "generate_bootimg"
		MKBOOTIMG=mkbootimg-osm0sis
	fi

	echo "==> initramfs: creating boot.img"
	_base="${deviceinfo_flash_offset_base}"
	[ -z "$_base" ] && _base="0x10000000"

	# shellcheck disable=SC3060
	kernelfile="$input_dir/$kernel_filename"
	if [ "${deviceinfo_append_dtb}" = "true" ]; then
		kernelfile="${kernelfile}-dtb"
	fi

	if [ "${deviceinfo_bootimg_mtk_mkimage}" = "true" ]; then
		kernelfile="${kernelfile}-mtk"
	fi

	_second=""
	if [ "${deviceinfo_bootimg_dtb_second}" = "true" ]; then
		if [ -z "${deviceinfo_dtb}" ]; then
			echo "ERROR: deviceinfo_bootimg_dtb_second is set, but"
			echo "'deviceinfo_dtb' is missing. Set 'deviceinfo_dtb'"
			echo "to the device tree blob for your device."
			echo "See also: <https://postmarketos.org/deviceinfo>"
			exit 1
		fi
		dtb="/usr/share/dtb/${deviceinfo_dtb}.dtb"
		_second="--second $dtb"
		if ! [ -e "$dtb" ]; then
			echo "ERROR: File not found: $dtb. Please set 'deviceinfo_dtb'"
			echo "to the relative path to the device tree blob for your"
			echo "device (without .dtb)."
			echo "See also: <https://postmarketos.org/deviceinfo>"
			exit 1
		fi
	fi
	_dt=""
	if [ "${deviceinfo_bootimg_qcdt}" = "true" ]; then
		_dt="--dt /boot/dt.img"
		if ! [ -e "/boot/dt.img" ]; then
			echo "ERROR: File not found: /boot/dt.img, but"
			echo "'deviceinfo_bootimg_qcdt' is set. Please verify that your"
			echo "device is a QCDT device by analyzing the boot.img file"
			echo "(e.g. 'pmbootstrap bootimg_analyze path/to/twrp.img')"
			echo "and based on that, set the deviceinfo variable to false or"
			echo "adjust your linux APKBUILD to properly generate the dt.img"
			echo "file. See also: <https://postmarketos.org/deviceinfo>"
			exit 1
		fi
	fi
	# shellcheck disable=SC2039 disable=SC2086
	"${MKBOOTIMG}" \
		--kernel "${kernelfile}" \
		--ramdisk "$input_dir/$initfs_filename" \
		--base "${_base}" \
		--second_offset "${deviceinfo_flash_offset_second}" \
		--cmdline "${deviceinfo_kernel_cmdline}" \
		--kernel_offset "${deviceinfo_flash_offset_kernel}" \
		--ramdisk_offset "${deviceinfo_flash_offset_ramdisk}" \
		--tags_offset "${deviceinfo_flash_offset_tags}" \
		--pagesize "${deviceinfo_flash_pagesize}" \
		${_second} \
		${_dt} \
		-o "$bootimg" || exit 1
	# shellcheck disable=SC3060
	if [ "${deviceinfo_mkinitfs_postprocess}" != "" ]; then
		sh "${deviceinfo_mkinitfs_postprocess}" "$input_dir/$initfs_filename"
	fi
	if [ "${deviceinfo_bootimg_blobpack}" = "true" ] || [ "${deviceinfo_bootimg_blobpack}" = "sign" ]; then
		echo "==> initramfs: creating blob"
		_flags=""
		if [ "${deviceinfo_bootimg_blobpack}" = "sign" ]; then
			_flags="-s"
		fi
		# shellcheck disable=SC3060
		blobpack $_flags "${bootimg}.blob" \
				LNX "$bootimg" || exit 1
		# shellcheck disable=SC3060
		copy "${bootimg}.blob" "$bootimg"
	fi
	if [ "${deviceinfo_bootimg_append_seandroidenforce}" = "true" ]; then
		echo "==> initramfs: appending 'SEANDROIDENFORCE' to boot.img"
		# shellcheck disable=SC3037
		echo -n "SEANDROIDENFORCE" >> "$bootimg"
	fi
	additional_files="$additional_files $(basename "$bootimg")"
}

flash_updated_boot_parts() {
	[ "${deviceinfo_flash_kernel_on_update}" = "true" ] || return
	# If postmarketos-update-kernel is not installed then nop
	[ -f /sbin/pmos-update-kernel ] || return
	# Don't run when in a pmOS chroot
	if [ -f "/in-pmbootstrap" ]; then
		echo "==> Not flashing boot in chroot"
		return
	fi

	echo "==> Flashing boot image"
	flavor=$(uname -r | sed "s/^[^-]*-//")
	pmos-update-kernel "$flavor"
}

# $1: list of files to get total size of, in kilobytes
get_size_of_files() {
	# shellcheck disable=SC2086
	ret=$(du $1 | cut -f1 | sed '$ s/\n$//' | tr '\n' + |sed 's/.$/\n/' | bc -s)
	echo "$ret"
}

check_destination_free_space() {
	src_size=$(get_size_of_files "$files_to_copy")
	target_free_space=$(get_free_space "$output_dir")

	if [ "$src_size" -ge "$target_free_space" ]; then
		echo "Destination filesystem does not have enough free space!"
		echo "Need $src_size kilobytes, have $target_free_space kilobytes"
		exit 1
	fi
	echo "... OK!"
}
