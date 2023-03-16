#!/bin/sh
# Copyright 2021 postmarketOS Contributors
# Copyright 2021 Clayton Craft <clayton@craftyguy.net>
# SPDX-License-Identifier: GPL-3.0-or-later
set -eu

# Declare used deviceinfo variables to pass shellcheck (order alphabetically)
deviceinfo_append_dtb=""
deviceinfo_arch=""
deviceinfo_bootimg_append_seandroidenforce=""
deviceinfo_bootimg_custom_args=""
deviceinfo_bootimg_blobpack=""
deviceinfo_bootimg_dtb_second=""
deviceinfo_bootimg_mtk_mkimage=""
deviceinfo_bootimg_pxa=""
deviceinfo_bootimg_qcdt=""
deviceinfo_bootimg_override_payload=""
deviceinfo_bootimg_override_payload_compression=""
deviceinfo_bootimg_override_payload_append_dtb=""
deviceinfo_bootimg_override_initramfs=""
deviceinfo_cgpt_kpart=""
deviceinfo_depthcharge_board=""
deviceinfo_dtb=""
deviceinfo_header_version=""
deviceinfo_flash_offset_base=""
deviceinfo_flash_offset_dtb=""
deviceinfo_flash_offset_kernel=""
deviceinfo_flash_offset_ramdisk=""
deviceinfo_flash_offset_second=""
deviceinfo_flash_offset_tags=""
deviceinfo_flash_pagesize=""
deviceinfo_generate_bootimg=""
deviceinfo_generate_depthcharge_image=""
deviceinfo_generate_extlinux_config=""
deviceinfo_generate_grub_config=""
deviceinfo_generate_uboot_fit_images=""
deviceinfo_generate_legacy_uboot_initfs=""
deviceinfo_mkinitfs_postprocess=""
deviceinfo_kernel_cmdline=""
deviceinfo_legacy_uboot_load_address=""
deviceinfo_legacy_uboot_image_name=""
deviceinfo_flash_kernel_on_update=""

# Declare used /etc/boot/boot-deploy variables to pass shellcheck (order alphabetically)
crypttab_entry=""
distro_name=""
distro_prefix=""

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
		log "Input directory does not exist: $output_dir"
		exit 1
	fi

	for f in "$kernel_filename" "$initfs_filename" $additional_files; do
		if [ ! -f "$input_dir/$f" ]; then
			log "File does not exist: $input_dir/$f"
			exit 1
		fi
	done
}

# Return the free space (bytes) for the mount point that contains the given
# path. This only returns 90% of the actual free space, to avoid possibly
# filling the filesystem
# $1: Path
get_free_space() {
	[ -z "$1" ] && log "No path given to free space check" && exit 1

	# note: tr is used to reduce extra spaces in df output to a single space,
	# so cut fields are consistent
	_df_out="$(df -P "$1" | tr -s ' ' | tail -1 | cut -d' ' -f4)"
	_df_out="$(echo "$_df_out"/0.9 | bc -s)"
	echo "$_df_out"
}

source_deviceinfo() {
	if [ ! -e "$deviceinfo" ]; then
		log "ERROR: $deviceinfo not found!"
		exit 1
	fi
	# shellcheck disable=SC1090
	. "$deviceinfo"
}

source_boot_deploy_config() {
	file="/etc/boot/boot-deploy"
	if [ ! -e "$file" ]; then
		log "ERROR: $file not found!"
		exit 1
	fi
	# shellcheck disable=SC1090
	. "$file"
	if [ -z "$crypttab_entry" ]; then
		log "ERROR: crypttab_entry from $file is not set"
		exit 1
	fi
	if [ -z "$distro_name" ]; then
		log "ERROR: distro_name from $file is not set"
		exit 1
	fi
	if [ -z "$distro_prefix" ]; then
		log "ERROR: distro_prefix from $file is not set"
		exit 1
	fi
}

# Required command check with useful error message
# $1: command (e.g. "mkimage")
# $2: package (e.g. "u-boot-tools")
# $3: related deviceinfo variable (e.g. "generate_bootimg")
require_package()
{
	[ "$(command -v "$1")" = "" ] || return 0
	log "ERROR: 'deviceinfo_$3' is set, but the package '$2' was not"
	log "installed!"
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

	_src_chksum="$(md5sum "$_src" | cut -d' ' -f1)"

	# does target have enough free space to copy atomically?
	_size=$(get_size_of_files "$_src")
	target_free_space=$(get_free_space "$_dest_dir")
	if [ "$_size" -ge "$target_free_space" ]; then
		log "*NOT* copying file atomically (not enough free space at target): $f"
		_dest_tmp="$_dest"
	else
		# copying atomically, by copying to a temp file in the target filesystem first
		_dest_tmp="${_dest}".tmp
	fi

	cp "$_src" "$_dest_tmp"
	sync "$_dest_dir"

	_dest_chksum="$(md5sum "$_dest_tmp" | cut -d' ' -f1)"

	if [ "$_src_chksum" != "$_dest_chksum" ]; then
		log "Checksums do not match: $_src --> $_dest_tmp"
		log "Have: $_src_chksum, expected: $_dest_chksum"
		exit 1
	fi

	# if not copying atomically, these are set to the same file. mv'ing
	# triggers a warning from mv cmd, so just skip it
	if [ "$_dest_tmp" != "$_dest" ]; then
		mv "$_dest_tmp" "$_dest"
	fi

	sync "$_dest_dir"
}

# Copies files from the given list of files to $output_dir
# $@: list of files to copy
# The file paths support the format <src>:<dest>
# where <dest> is a path within $output_dir.
# For example, `grub.cfg:/grub/grub.cfg` will copy `grub.cfg` to
# `$output_dir/grub/grub.cfg`.
# If the <dest> is omitted, then <src> will be copied to the root of
# $output_dir.
copy_files() {
	for f in "$@"; do
		_src="$(echo "$f" | cut -d':' -f1 -s)"
		_dest=
		if [ -z "$_src" ]; then
			_src="$f"
			_dest="$output_dir/$(basename "$_src")"
		else
			_dest="$output_dir"/"$(echo "$f" | cut -d':' -f2)"
			mkdir -p "$(dirname "$_dest")"
		fi

		echo "==> Installing: $_dest"
		copy "$_src" "$_dest"
	done
}

# Append the correct device tree to the linux image file or copy the dtb to the boot partition
append_or_copy_dtb() {
	if [ -z "${deviceinfo_dtb}" ]; then
		if [ "$deviceinfo_header_version" = "2" ]; then
			log "ERROR: deviceinfo_header_version is 2, but"
			log "'deviceinfo_dtb' is missing. Set 'deviceinfo_dtb'"
			log "to the device tree blob for your device."
			log "See also: <https://postmarketos.org/deviceinfo>"
			exit 1
		else
			return 0
		fi
	fi
	log_arrow "kernel: device-tree blob operations"

	dtb=""
	for filename in $deviceinfo_dtb; do
		dtb="$dtb $(find_dtb "$filename")"
	done

	# Remove excess whitespace
	dtb=$(echo "$dtb" | xargs)

	if [ "$deviceinfo_header_version" = "2" ] && [ "$(echo "$dtb" | tr ' ' '\n' | wc -l)" -gt 1 ]; then
		log "ERROR: deviceinfo_header_version is 2, but"
		log "'deviceinfo_dtb' specifies more than one dtb!"
		exit 1
	fi

	_outfile="$input_dir/$kernel_filename-dtb"
	if [ "${deviceinfo_append_dtb}" = "true" ]; then
		log_arrow "kernel: appending device-tree ${deviceinfo_dtb}"
		# shellcheck disable=SC2086
		cat "$input_dir/$kernel_filename" $dtb > "$_outfile"
		additional_files="$additional_files $(basename "$_outfile")"
	else
		for dtb_path in $dtb; do
			dtb_filename=$(basename "$dtb_path")
			copy "$dtb_path" "$input_dir/$dtb_filename"
			additional_files="$additional_files ${dtb_filename}"
		done
	fi
}

# Add Mediatek header to kernel & initramfs
add_mtk_header() {
	[ "${deviceinfo_bootimg_mtk_mkimage}" = "true" ] || return 0
	require_package "mtk-mkimage" "mtk-mkimage" "bootimg_mtk_mkimage"

	_infile="$input_dir/$initfs_filename"
	_outfile="$input_dir/$initfs_filename.mtk"
	log_arrow "initramfs: adding Mediatek header"
	mtk-mkimage ROOTFS "$_infile" "$_outfile"
	copy "$_outfile" "$_infile"
	rm "$_outfile"

	log_arrow "kernel: adding Mediatek header"
	# shellcheck disable=SC3060
	kernel="$input_dir/$kernel_filename"
	rm -f "${kernel}-mtk"
	mtk-mkimage KERNEL "$kernel" "${kernel}-mtk"
	additional_files="$additional_files $(basename "${kernel}"-mtk)"
}

create_uboot_files() {
	create_legacy_uboot_images
	create_uboot_fit_image
}

create_legacy_uboot_images() {
	arch="arm"
	if [ "${deviceinfo_arch}" = "aarch64" ]; then
		arch="arm64"
	fi

	[ "${deviceinfo_generate_legacy_uboot_initfs}" = "true" ] || return 0
	require_package "mkimage" "u-boot-tools" "generate_legacy_uboot_initfs"

	log_arrow "initramfs: creating uInitrd"
	_infile="$input_dir/$initfs_filename"
	_outfile="$input_dir/uInitrd"
	mkimage -A $arch -T ramdisk -C none -n uInitrd -d "$_infile" \
		"$_outfile" || exit 1

	log_arrow "kernel: creating uImage"
	kernelfile="$input_dir/$kernel_filename"
	if [ "${deviceinfo_append_dtb}" = "true" ]; then
		kernelfile="$input_dir/$kernel_filename-dtb"
	fi

	if [ -z "$deviceinfo_legacy_uboot_load_address" ]; then
		deviceinfo_legacy_uboot_load_address="80008000"
	fi

	if [ -z "$deviceinfo_legacy_uboot_image_name" ]; then
		deviceinfo_legacy_uboot_image_name="$distro_name"
	fi

	# shellcheck disable=SC3060
	mkimage -A $arch -O linux -T kernel -C none -a "$deviceinfo_legacy_uboot_load_address" \
		-e "$deviceinfo_legacy_uboot_load_address" \
		-n "$deviceinfo_legacy_uboot_image_name" -d "$kernelfile" "$input_dir/uImage" || exit 1

	# shellcheck disable=SC3060
	if [ "${deviceinfo_mkinitfs_postprocess}" != "" ]; then
		sh "${deviceinfo_mkinitfs_postprocess}" "$input_dir/$initfs_filename"
	fi

	additional_files="$additional_files uImage uInitrd"
}

create_uboot_fit_image() {
	log_arrow "u-boot: creating FIT images"
	[ "${deviceinfo_generate_uboot_fit_images}" = "true" ] || return 0
	fit_source_files=$(ls -A "$input_dir"/*.its)
	if [ -z "$fit_source_files" ]; then
		log_arrow "u-boot: no FIT image source files found"
		return 0
	fi
	require_package "mkimage" "u-boot-tools" "generate_bootimg_uboot"
	require_package "dtc" "dtc" "generate_uboot_fit_image"
	require_package "dtc" "dtc" "generate_bootimg_uboot_and_fit_image"

	for uboot_fit_source in $fit_source_files; do
		log_arrow "u-boot: creating FIT image from $uboot_fit_source file"
		uboot_fit_image=$(echo "$uboot_fit_source" | sed -e 's/\.its/.itb/g')
		# shellcheck disable=SC3060
		mkimage -f "$uboot_fit_source" "$uboot_fit_image" || exit 1

		uboot_fit_image_filename=$(basename "$uboot_fit_image")
		additional_files="$additional_files $uboot_fit_image_filename"
	done
}

# Android devices
create_bootimg() {
	[ "${deviceinfo_generate_bootimg}" = "true" ] || return 0
	# shellcheck disable=SC3060
	bootimg="$input_dir/boot.img"

	if [ "${deviceinfo_bootimg_pxa}" = "true" ]; then
		require_package "pxa-mkbootimg" "pxa-mkbootimg" "bootimg_pxa"
		MKBOOTIMG=pxa-mkbootimg
	else
		require_package "mkbootimg-osm0sis" "mkbootimg" "generate_bootimg"
		MKBOOTIMG=mkbootimg-osm0sis
	fi

	log_arrow "initramfs: creating boot.img"
	_base="${deviceinfo_flash_offset_base}"
	[ -z "$_base" ] && _base="0x10000000"

	if [ -n "$deviceinfo_bootimg_override_payload" ]; then
		if [ -f "$input_dir/$deviceinfo_bootimg_override_payload" ]; then
			payload="$input_dir/$deviceinfo_bootimg_override_payload"
			log_arrow "initramfs: replace kernel with file $payload"
			if [ "$deviceinfo_bootimg_override_payload_compression" = "gzip" ]; then
				log_arrow "initramfs: gzip payload replacement"
				gzip "$payload"
				kernelfile="$payload.gz"
			else
				kernelfile="$payload"
			fi
			if [ -n "$deviceinfo_bootimg_override_payload_append_dtb" ]; then
				log_arrow "initramfs: append $deviceinfo_bootimg_override_payload_append_dtb at payload end"
				cat "$input_dir/$deviceinfo_bootimg_override_payload_append_dtb" >> "$kernelfile"
			fi
		else
			log "File $input_dir/$deviceinfo_bootimg_override_payload not found,"
			log "please, correct deviceinfo_bootimg_override_payload option value."
			exit 1
		fi
	else
		# shellcheck disable=SC3060
		kernelfile="$input_dir/$kernel_filename"
		if [ "${deviceinfo_append_dtb}" = "true" ]; then
			kernelfile="${kernelfile}-dtb"
		fi

		if [ "${deviceinfo_bootimg_mtk_mkimage}" = "true" ]; then
			kernelfile="${kernelfile}-mtk"
		fi
	fi


	_second=""
	if [ "${deviceinfo_bootimg_dtb_second}" = "true" ]; then
		if [ -z "${deviceinfo_dtb}" ]; then
			log "ERROR: deviceinfo_bootimg_dtb_second is set, but"
			log "'deviceinfo_dtb' is missing. Set 'deviceinfo_dtb'"
			log "to the device tree blob for your device."
			log "See also: <https://postmarketos.org/deviceinfo>"
			exit 1
		fi
		dtb=$(find_dtb "$deviceinfo_dtb")
		_second="--second $dtb"
	fi
	_dt=""
	if [ "${deviceinfo_bootimg_qcdt}" = "true" ]; then
		_dt="--dt /boot/dt.img"
		if ! [ -e "/boot/dt.img" ]; then
			log "ERROR: File not found: /boot/dt.img, but"
			log "'deviceinfo_bootimg_qcdt' is set. Please verify that your"
			log "device is a QCDT device by analyzing the boot.img file"
			log "(e.g. 'pmbootstrap bootimg_analyze path/to/twrp.img')"
			log "and based on that, set the deviceinfo variable to false or"
			log "adjust your linux APKBUILD to properly generate the dt.img"
			log "file. See also: <https://postmarketos.org/deviceinfo>"
			exit 1
		fi
	fi

	if [ "$deviceinfo_header_version" = "2" ] && [ -z "$deviceinfo_bootimg_custom_args" ]; then
		if [ -z "$deviceinfo_flash_offset_dtb" ]; then
			log "ERROR: deviceinfo_header_version is 2, but"
			log "'deviceinfo_flash_offset_dtb' is missing. Set it"
			log "to the device tree blob offset for your device."
			log "See also: <https://postmarketos.org/deviceinfo>"
			exit 1
		fi
		deviceinfo_bootimg_custom_args="--header_version 2 --dtb_offset $deviceinfo_flash_offset_dtb --dtb $dtb"
	fi

	ramdisk="$input_dir/$initfs_filename"
	if [ -n "$deviceinfo_bootimg_override_initramfs" ]; then
		if [ -f "$input_dir/$deviceinfo_bootimg_override_initramfs" ]; then
			log_arrow "initramfs: replace initramfs with file $input_dir/$deviceinfo_bootimg_override_initramfs"
			ramdisk="$input_dir/$deviceinfo_bootimg_override_initramfs"
		else
			log "ERROR: file $input_dir/$deviceinfo_bootimg_override_initramfs not found,"
			log "please, correct deviceinfo_bootimg_override_initramfs option value."
			exit 1
		fi
	fi
	# shellcheck disable=SC2039 disable=SC2086
	"${MKBOOTIMG}" \
		--kernel "${kernelfile}" \
		--ramdisk "$ramdisk" \
		--base "${_base}" \
		--second_offset "${deviceinfo_flash_offset_second}" \
		--cmdline "$(get_cmdline)" \
		--kernel_offset "${deviceinfo_flash_offset_kernel}" \
		--ramdisk_offset "${deviceinfo_flash_offset_ramdisk}" \
		--tags_offset "${deviceinfo_flash_offset_tags}" \
		--pagesize "${deviceinfo_flash_pagesize}" \
		${_second} \
		${_dt} \
		${deviceinfo_bootimg_custom_args} \
		-o "$bootimg" || exit 1
	# shellcheck disable=SC3060
	if [ "${deviceinfo_mkinitfs_postprocess}" != "" ]; then
		sh "${deviceinfo_mkinitfs_postprocess}" "$input_dir/$initfs_filename"
	fi
	if [ "${deviceinfo_bootimg_blobpack}" = "true" ] || [ "${deviceinfo_bootimg_blobpack}" = "sign" ]; then
		log_arrow "initramfs: creating blob"
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
		log_arrow "initramfs: appending 'SEANDROIDENFORCE' to boot.img"
		printf "SEANDROIDENFORCE" >> "$bootimg"
	fi
	additional_files="$additional_files $(basename "$bootimg")"
}

flash_updated_boot_parts() {
	[ "${deviceinfo_flash_kernel_on_update}" = "true" ] || return 0
	# If postmarketos-update-kernel is not installed then nop
	[ -f /sbin/pmos-update-kernel ] || return 0
	# Don't run when in a pmOS chroot
	if [ -f "/in-pmbootstrap" ]; then
		log_arrow "Not flashing boot in chroot"
		return 0
	fi

	log_arrow "Flashing boot image"
	pmos-update-kernel
}

# Chrome OS devices
create_depthcharge_kernel_image() {
	[ "${deviceinfo_generate_depthcharge_image}" = "true" ] || return 0

	require_package "depthchargectl" "depthcharge-tools" "generate_depthcharge_image"

	log_arrow "Generating vmlinuz.kpart"

	if [ -z "${deviceinfo_depthcharge_board}" ]; then
		log "ERROR: deviceinfo_depthcharge_board is not set"
		exit 1
	fi

	depthchargectl build --root none \
		--board "$deviceinfo_depthcharge_board" \
		--kernel "$input_dir/$kernel_filename" \
		--kernel-cmdline "$(get_cmdline)" \
		--initramfs "$input_dir/$initfs_filename" \
		--fdtdir "$input_dir" \
		--output "$input_dir/$(basename "$deviceinfo_cgpt_kpart")"

	additional_files="$additional_files $(basename "$deviceinfo_cgpt_kpart")"
}

flash_updated_depthcharge_kernel() {
	[ "${deviceinfo_generate_depthcharge_image}" = "true" ] || return 0

	[ -f /sbin/pmos-update-depthcharge-kernel ] || return 0

	# Don't run when in a pmOS chroot
	if [ -f "/in-pmbootstrap" ]; then
		log_arrow "Not flashing vmlinuz.kpart in chroot"
		return 0
	fi

	log_arrow "Flashing depthcharge kernel image"
	pmos-update-depthcharge-kernel
}

create_extlinux_config() {
	[ "${deviceinfo_generate_extlinux_config}" = "true" ] || return 0

	if [ "$(echo "$deviceinfo_dtb" | wc -w)" -gt 1 ]; then
		log "ERROR: deviceinfo_dtb contains more than one dtb"
		exit 1
	fi

	log_arrow "Generating extlinux.conf"

	cat <<EOF > "$input_dir/extlinux.conf"
timeout 1
default $distro_name
menu title boot prev kernel

label $distro_name
	kernel /$kernel_filename
	fdt /$(basename "$deviceinfo_dtb").dtb
	initrd /$initfs_filename
	append $(get_cmdline)
EOF
	additional_files="$additional_files extlinux.conf:/extlinux/extlinux.conf"
}

create_grub_config() {
	[ "${deviceinfo_generate_grub_config}" = "true" ] || return 0

	if [ "$(echo "$deviceinfo_dtb" | wc -w)" -gt 1 ]; then
		log "ERROR: deviceinfo_dtb contains more than one dtb"
		exit 1
	fi

	mkdir -p /boot/grub

	log_arrow "Generating /boot/grub/grub.cfg"

	cat <<EOF > /tmp/grub.cfg
timeout=0

menuentry "$distro_name" {
	linux /$kernel_filename $(get_cmdline)
	initrd /$initfs_filename
	devicetree /$(basename "$deviceinfo_dtb").dtb
}
EOF
	copy "/tmp/grub.cfg" "/boot/grub/grub.cfg"
	rm /tmp/grub.cfg
}

# $1: list of files to get total size of, in kilobytes
get_size_of_files() {
	_files=
	for f in $1; do
		# strip off any destination paths
		_files="$_files $(echo "$f" | cut -d':' -f1)"
	done

	# shellcheck disable=SC2086
	ret=$(du $_files | cut -f1 | sed '$ s/\n$//' | tr '\n' + |sed 's/.$/\n/' | bc -s)
	echo "$ret"
}

# $1: mount point
parse_fstab_entry() {
	fstab=$(grep -v ^\# /etc/fstab | grep .)
	ret=""

	# shellcheck disable=SC3003
	IFS=$'\n'
	for entry in $fstab; do
		if [ "$(echo "$entry" | xargs | cut -d" " -f2)" = "$1" ]; then
			ret="$(echo "$entry" | xargs | cut -d" " -f1)"
		fi
	done
	unset IFS

	echo "$ret"
}

# $1: mount point
parse_crypttab_entry() {
	crypttab=$(grep -v ^\# /etc/crypttab | grep .)
	ret=""

	# shellcheck disable=SC3003
	IFS=$'\n'
	for entry in $crypttab; do
		if [ "$(echo "$entry" | xargs | cut -d" " -f1)" = "$1" ]; then
			ret="$(echo "$entry" | xargs | cut -d" " -f2)"
		fi
	done
	unset IFS

	echo "$ret"
}

get_cmdline() {
	ret="$deviceinfo_kernel_cmdline"

	if [ -f "/etc/boot/cmdline.txt" ]; then
		ret="$ret $(xargs < /etc/boot/cmdline.txt)"
	fi

	boot_uuid=""
	root_uuid=""

	if [ -f "/etc/fstab" ]; then
		boot_uuid=$(parse_fstab_entry "/boot")
		root_uuid=$(parse_fstab_entry "/")
	fi

	if [ -f "/etc/crypttab" ]; then
		root_uuid=$(parse_crypttab_entry "$crypttab_entry")
	fi

	# When appropriate fstab entry does not exist, cmdline will not
	# be passed because of -n checks. In this case, postmarketOS
	# init script will look for partitions according to pmOS_boot
	# and pmOS_root labels.

	if [ -n "$boot_uuid" ] && [ "$boot_uuid" != "${boot_uuid#UUID=}" ]; then
		ret="$ret ${distro_prefix}_boot_uuid=${boot_uuid#UUID=}"
	fi

	if [ -n "$root_uuid" ] && [ "$root_uuid" != "${root_uuid#UUID=}" ]; then
		ret="$ret ${distro_prefix}_root_uuid=${root_uuid#UUID=}"
	fi

	echo "$ret"
}

# Check that the the given list of files can be copied to the destination, $output_dir,
# atomically
# $1: list of files to check
check_destination_free_space() {
	# This uses two checks to test whether the destination filesystem has
	# enough free space for copying the given list of files atomically. Since
	# files may exist in the target dir with the same name as those that are to
	# be copied, and files are copied one at a time, it's possible (and almost
	# expected) that the free space at the destination is less than the total
	# size of the files to be copied, so the size delta is checked and then
	# each file is checked to make sure the target dir can hold the new copy of
	# it before the old file is atomically replaced.

	log_arrow "Checking free space at $output_dir"
	files="$1"

	# First check is that target has enough space for all new files/sizes
	# 1) get size of new files
	total_new_size=$(get_size_of_files "$files")

	# 2) get size of old files at destination
	total_old_size=0
	for f in $files; do
		if [ -f "$output_dir/$(basename "$f")" ]; then
			total_old_size=$((total_old_size+$(get_size_of_files "$f")))
		fi
	done

	# 3) subtract old size from new size
	total_diff_size=$((total_new_size-total_old_size))

	# 4) get free space at destination
	target_free_space=$(get_free_space "$output_dir")

	# does the target have enough free space for diff size of all new files?
	if [ "$total_diff_size" -ge "$target_free_space" ]; then
		log "Destination filesystem does not have enough free space!"
		log "Need $total_diff_size kilobytes, have $target_free_space kilobytes"
		exit 1
	fi

	# Second check is that each file can be replaced atomically
	# for each new file:
	for f in $files; do
		# 1) get size of new file
		f_size=$(get_size_of_files "$f")
		# 2) does target have enough free space for the new file size?
		if [ "$f_size" -ge "$target_free_space" ]; then
			log "Destination filesystem does not have enough free space to copy this file atomically: $f"
			log "Need $f_size kilobytes, have $target_free_space kilobytes"
		fi
	done
	echo "... OK!"
}

# $1: name of dtb to find
find_dtb() {
	filename="$1"

	if [ -z "$filename" ]; then
		log "ERROR: dtb name was an empty string"
		exit 1
	fi

	# FIXME: Currently, this always uses the first dtb found, which may not always
	# be correct. This should only be an issue if you have multiple kernels
	# that provide the same dtb installed, which pmOS does not support, but it is
	# still potentially unexpected behaviour.

	dtb_found="false"
	# Modern postmarketOS dtb path
	if [ -e "/boot/dtbs/$filename.dtb" ]; then
		dtb="/boot/dtbs/$filename.dtb"
		dtb_found="true"
	fi
	# Alpine-style dtb paths
	if [ -e "$(find /boot -path "/boot/dtbs-*/$filename.dtb")" ] && [ "$dtb_found" = "false" ]; then
		dtb=$(find /boot -path "/boot/dtbs-*/$filename.dtb")
		dtb_found="true"
	fi
	# Legacy postmarketOS dtb path (for backwards compatibility)
	if [ -e "/usr/share/dtb/$filename.dtb" ] && [ "$dtb_found" = "false" ]; then
		dtb="/usr/share/dtb/$filename.dtb"
		dtb_found="true"
	fi
	if [ "$dtb_found" = "false" ]; then
		log "ERROR: Unable to find $filename.dtb in the following locations:"
		log "    - /boot/dtbs/"
		log "    - /boot/dtbs-*/"
		log "    - /usr/share/dtb/"
		exit 1
	fi

	echo "$dtb"
}

# $1: Message to log. Will be prefixed by an arrow.
log_arrow() {
	message="$1"

	log "==> $message"
}

# $1: Message to log.
log() {
	message="$1"

	# Redirect the message to stderr so it doesn't get captured as a "return
	# value" in functions that use stdout for returning data.
	echo "$message" 1>&2
}
