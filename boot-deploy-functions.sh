#!/bin/sh
# Copyright 2021 postmarketOS Contributors
# Copyright 2021 Clayton Craft <clayton@craftyguy.net>
# SPDX-License-Identifier: GPL-3.0-or-later
set -eu

# Declare used deviceinfo variables to pass shellcheck (order alphabetically)
deviceinfo_append_dtb=""
deviceinfo_arch=""
deviceinfo_bootimg_amazon_omap_header_size=""
deviceinfo_bootimg_append_seandroidenforce=""
deviceinfo_bootimg_custom_args=""
deviceinfo_bootimg_blobpack=""
deviceinfo_bootimg_dtb_second=""
deviceinfo_bootimg_mtk_label_kernel=""
deviceinfo_bootimg_mtk_label_ramdisk=""
deviceinfo_bootimg_prepend_dhtb=""
deviceinfo_bootimg_pxa=""
deviceinfo_bootimg_qcdt=""
deviceinfo_bootimg_qcdt_type=""
deviceinfo_bootimg_override_payload=""
deviceinfo_bootimg_override_payload_compression=""
deviceinfo_bootimg_override_payload_append_dtb=""
deviceinfo_bootimg_override_initramfs=""
deviceinfo_cgpt_kpart=""
deviceinfo_depthcharge_board=""
deviceinfo_depthcharge_compression=""
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
deviceinfo_generate_cmdline_txt=""
deviceinfo_generate_depthcharge_image=""
deviceinfo_generate_extlinux_config=""
deviceinfo_generate_grub_config=""
deviceinfo_generate_uboot_fit_images=""
deviceinfo_generate_legacy_uboot_initfs=""
deviceinfo_generate_systemd_boot=""
deviceinfo_mkinitfs_postprocess=""
deviceinfo_kernel_cmdline=""
deviceinfo_kernel_cmdline_append=""
deviceinfo_legacy_uboot_load_address=""
deviceinfo_legacy_uboot_image_name=""
deviceinfo_flash_kernel_on_update=""

# Declare used /usr/share/boot-deploy/os-customization variables to pass shellcheck (order alphabetically)
crypttab_entry=""
distro_name=""
distro_prefix=""

# getopts / get_options set the following 'global' variables:
kernel_filename=
initfs_filename=
work_dir=
output_dir="/boot"
additional_files=
local_deviceinfo=""

usage() {
	printf "Usage:
	%s -i <file> -k <file> -d <path> [-o <path>] [files...]
Where:
	-i  filename of the initfs in the input directory
	-k  filename of the kernel in the input directory
	-d  path to directory containing input initfs, kernel
	-o  path to output directory {default: /boot}
	-c  path to local deviceinfo {default: source /etc/deviceinfo after /usr/share/deviceinfo/deviceinfo}

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
				work_dir="$OPTARG";;
			o)
				output_dir="$OPTARG";;
			c)
				local_deviceinfo="$OPTARG";;
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
	if [ -z "$work_dir" ]; then
		usage
		exit 1
	fi

	if [ ! -d "$work_dir" ]; then
		log "Input directory does not exist: $output_dir"
		exit 1
	fi

	for f in "$kernel_filename" "$initfs_filename" $additional_files; do
		if [ ! -f "$work_dir/$f" ]; then
			log "File does not exist: $work_dir/$f"
			exit 1
		fi
	done
}

# Return the free space (bytes) for the mount point that contains the given
# path. This only returns up to 90% of the actual free space, to avoid possibly
# filling the filesystem.
# Note: In order to avoid returning a float, which makes comparisons and other
# operations more complicated, this function rounds down to the nearest byte.
#
# $1: Path
get_free_space() {
	[ -z "$1" ] && log "No path given to free space check" && exit 1

	local _df_out
	_df_out="$(df -P "$1" | tail -1 | awk '{ print $4; }')"
	_df_out="$(echo "$_df_out*0.9" | bc -s)"
	# Effectively convert the value to an integer, rounding down to the nearest
	# byte.
	printf "%.0f" "$_df_out"
}

# Validate deviceinfo variables, exiting the program if any of them fail
# validation
validate_deviceinfo() {
	local _fail=false

	# deviceinfo_arch must exist. If this is missing, something is off
	if [ -z "$deviceinfo_arch" ]; then
		log "ERROR: required variable 'deviceinfo_arch' is unset in the given deviceinfo"
		exit 1
	fi

	# These variables have values that are used by the script to do string
	# comparison, and should be lower case since sh doesn't support
	# case-insensitive comparisons.
	for _e in \
		deviceinfo_append_dtb \
		deviceinfo_arch \
		deviceinfo_bootimg_prepend_dhtb \
		deviceinfo_bootimg_append_seandroidenforce \
		deviceinfo_bootimg_blobpack \
		deviceinfo_bootimg_dtb_second \
		deviceinfo_bootimg_override_payload_compression \
		deviceinfo_bootimg_pxa \
		deviceinfo_bootimg_qcdt \
		deviceinfo_bootimg_qcdt_type \
		deviceinfo_flash_kernel_on_update \
		deviceinfo_generate_bootimg \
		deviceinfo_generate_depthcharge_image \
		deviceinfo_generate_extlinux_config \
		deviceinfo_generate_grub_config \
		deviceinfo_generate_systemd_boot \
		deviceinfo_generate_legacy_uboot_initfs \
		deviceinfo_generate_uboot_fit_images \
		deviceinfo_header_version \
		deviceinfo_mkinitfs_postprocess \
		; do
			# Expand the variable
			local _val
			_val="$(eval "echo \${$_e}")"
			# Check that the value is lowercase
			if [ "$_val" != "$( echo "$_val" | tr '[:upper:]' '[:lower:]')" ]; then
				echo "ERROR: variable should have a lowercase value: $_e"
				_fail=true
			fi
		done

	if "$_fail"; then
		echo "For more information, see: https://wiki.postmarketos.org/wiki/Deviceinfo_reference#Case_sensitivity"
		exit 1
	fi
}

source_deviceinfo() {
	if [ -n "$local_deviceinfo" ]; then
		if [ ! -e "$local_deviceinfo" ]; then
			log "ERROR: $local_deviceinfo file not found!"
			exit 1
		fi

		# shellcheck disable=SC1090
		. "$local_deviceinfo"
	elif [ -f /usr/share/misc/source_deviceinfo ]; then
		# shellcheck disable=SC1091
		. /usr/share/misc/source_deviceinfo
	else
		# shellcheck disable=SC1091
		[ -f /usr/share/deviceinfo/deviceinfo ] && . /usr/share/deviceinfo/deviceinfo
		# shellcheck disable=SC1091
		[ -f /etc/deviceinfo ] && . /etc/deviceinfo
	fi

	validate_deviceinfo
}

source_boot_deploy_config() {
	local _file="/usr/share/boot-deploy/os-customization"
	if [ ! -e "$_file" ]; then
		log "ERROR: $_file not found!"
		exit 1
	fi
	# shellcheck disable=SC1090
	. "$_file"
	if [ -z "$crypttab_entry" ]; then
		log "ERROR: crypttab_entry from $_file is not set"
		exit 1
	fi
	if [ -z "$distro_name" ]; then
		log "ERROR: distro_name from $_file is not set"
		exit 1
	fi
	if [ -z "$distro_prefix" ]; then
		log "ERROR: distro_prefix from $_file is not set"
		exit 1
	fi
}

execute_hooks() {
	log_arrow "Running hooks"

	for _hook in /usr/share/boot-deploy/hooks/* /etc/boot-deploy/hooks/*; do
		[ ! -x "$_hook" ] && continue
		sh "$_hook"
	done
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
	local _src="$1"
	local _dest="$2"
	local _dest_dir
	_dest_dir="$(dirname "$_dest")"

	[ ! -d "$_dest_dir" ] && mkdir -p "$_dest_dir"

	local _src_chksum
	_src_chksum="$(md5sum "$_src" | cut -d' ' -f1)"

	# does target have enough free space to copy atomically?
	local _size
	_size=$(get_size_of_files "$_src")
	local _target_free_space
	_target_free_space=$(get_free_space "$_dest_dir")
	if [ "$_size" -ge "$_target_free_space" ]; then
		local _dest_tmp="$_dest"
		log "*NOT* copying file atomically (not enough free space at target): $_dest_dir"
	else
		# copying atomically, by copying to a temp file in the target filesystem first
		local _dest_tmp="${_dest}".tmp
	fi

	cp "$_src" "$_dest_tmp"
	sync "$_dest_dir"

	local _dest_chksum
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
		local _src
		_src="$(echo "$f" | cut -d':' -f1 -s)"
		local _dest=
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

	local _dtb
	_dtb="$(find_all_dtbs)"

	# Remove excess whitespace
	_dtb=$(echo "$_dtb" | xargs)

	if [ "$deviceinfo_header_version" = "2" ] && [ "$(echo "$_dtb" | tr ' ' '\n' | wc -l)" -gt 1 ]; then
		log "ERROR: deviceinfo_header_version is 2, but"
		log "'deviceinfo_dtb' specifies more than one dtb!"
		exit 1
	fi

	local _outfile="$work_dir/$kernel_filename-dtb"
	if [ "${deviceinfo_append_dtb}" = "true" ]; then
		log_arrow "kernel: appending device-tree ${deviceinfo_dtb}"
		# shellcheck disable=SC2086
		cat "$work_dir/$kernel_filename" $_dtb > "$_outfile"
	fi

	# In some corner cases, where multiple bootloader implementations
	# can be used, user can request both appended dtb and FS based boot config.
	# Thus we always copy the dtb files into the boot fs.
	for _dtb_path in $_dtb; do
		local _dtb_filename
		_dtb_filename=$(basename "$_dtb_path")
		copy "$_dtb_path" "$work_dir/$_dtb_filename"
		additional_files="$additional_files ${_dtb_filename}"
	done
}

# Compare the given image to the given partition size. Returns true/0 if the
# image is smaller than the partition, else returns false/1.
# $1: image file
# $2: partition / block device
check_image_size() {
	local img="$1"
	local part="$2"
	local img_size
	# note: using 'du' instead of get_size_of_files since the function returns
	# KiB and lsblk returns bytes, it saves us a conversion step
	img_size="$(du -b "$img" | cut -f1)"

	local part_size
	part_size="$(lsblk "$part" --noheadings --bytes --output size)"

	if [ "$img_size" -gt "$part_size" ]; then
		log "ERROR: The $img size ($img_size bytes) is greater than the $part size ($part_size bytes)"
		return 1
	fi

	return 0
}

# Add MediaTek header to kernel and/or initramfs
add_mtk_header() {
	local _kernel_label=""
	local _ramdisk_label=""

	if [ -n "${deviceinfo_bootimg_mtk_label_kernel}" ]; then
		_kernel_label=$deviceinfo_bootimg_mtk_label_kernel
	fi
	if [ -n "${deviceinfo_bootimg_mtk_label_ramdisk}" ]; then
		_ramdisk_label=$deviceinfo_bootimg_mtk_label_ramdisk
	fi

	if [ -n "${_kernel_label}" ] || [ -n "${_ramdisk_label}" ]; then
		require_package "mtk-mkimage" "mtk-mkimage" "bootimg_mtk_mkimage"
	else
		return 0
	fi

	if [ -n "${_ramdisk_label}" ]; then
		local _infile="$work_dir/$initfs_filename"
		local _outfile="$work_dir/$initfs_filename.mtk"
		log_arrow "initramfs: adding MediaTek header"
		mtk-mkimage "${_ramdisk_label}" "$_infile" "$_outfile"
		copy "$_outfile" "$_infile"
		rm "$_outfile"
	fi
	if [ -n "${_kernel_label}" ]; then
		log_arrow "kernel: adding MediaTek header"
		# shellcheck disable=SC3060
		local _kernel="$work_dir/$kernel_filename"
		rm -f "${_kernel}-mtk"
		mtk-mkimage "${_kernel_label}" "$_kernel" "${_kernel}-mtk"
		additional_files="$additional_files $(basename "${_kernel}"-mtk)"
	fi
}

create_uboot_files() {
	create_legacy_uboot_images
	create_uboot_fit_image
}

create_legacy_uboot_images() {
	local _arch="arm"
	if [ "${deviceinfo_arch}" = "aarch64" ]; then
		_arch="arm64"
	fi

	[ "${deviceinfo_generate_legacy_uboot_initfs}" = "true" ] || return 0
	require_package "mkimage" "u-boot-tools" "generate_legacy_uboot_initfs"

	log_arrow "initramfs: creating uInitrd"
	local _infile="$work_dir/$initfs_filename"
	local _outfile="$work_dir/uInitrd"
	mkimage -A "$_arch" -T ramdisk -C none -n uInitrd -d "$_infile" \
		"$_outfile" || exit 1

	log_arrow "kernel: creating uImage"
	local _kernelfile="$work_dir/$kernel_filename"
	if [ "${deviceinfo_append_dtb}" = "true" ]; then
		_kernelfile="$work_dir/$kernel_filename-dtb"
	fi

	if [ -z "$deviceinfo_legacy_uboot_load_address" ]; then
		deviceinfo_legacy_uboot_load_address="80008000"
	fi

	if [ -z "$deviceinfo_legacy_uboot_image_name" ]; then
		deviceinfo_legacy_uboot_image_name="$distro_name"
	fi

	# shellcheck disable=SC3060
	mkimage -A "$_arch" -O linux -T kernel -C none -a "$deviceinfo_legacy_uboot_load_address" \
		-e "$deviceinfo_legacy_uboot_load_address" \
		-n "$deviceinfo_legacy_uboot_image_name" -d "$_kernelfile" "$work_dir/uImage" || exit 1

	# shellcheck disable=SC3060
	if [ "${deviceinfo_mkinitfs_postprocess}" != "" ]; then
		sh "${deviceinfo_mkinitfs_postprocess}" "$work_dir/$initfs_filename"
	fi

	additional_files="$additional_files uImage uInitrd"
}

create_uboot_fit_image() {
	[ "${deviceinfo_generate_uboot_fit_images}" = "true" ] || return 0
	log_arrow "u-boot: creating FIT images"
	local _fit_source_files
	_fit_source_files=$(ls -A "$work_dir"/*.its)
	if [ -z "$_fit_source_files" ]; then
		log_arrow "u-boot: no FIT image source files found"
		return 0
	fi
	require_package "mkimage" "u-boot-tools" "generate_bootimg_uboot"
	require_package "dtc" "dtc" "generate_uboot_fit_image"
	require_package "dtc" "dtc" "generate_bootimg_uboot_and_fit_image"

	for _uboot_fit_source in $_fit_source_files; do
		log_arrow "u-boot: creating FIT image from $_uboot_fit_source file"
		local _uboot_fit_image
		_uboot_fit_image=$(echo "$_uboot_fit_source" | sed -e 's/\.its/.itb/g')
		# shellcheck disable=SC3060
		mkimage -f "$_uboot_fit_source" "$_uboot_fit_image" || exit 1

		local _uboot_fit_image_filename
		_uboot_fit_image_filename=$(basename "$_uboot_fit_image")
		additional_files="$additional_files $_uboot_fit_image_filename"
	done
}

# Generate a Bootloader Spec entry for the current kernel / initramfs
# See: https://uapi-group.org/specifications/specs/boot_loader_specification/
generate_bootloader_spec_conf() {
	local _dtb=""
	local _kernel_filename="$kernel_filename"
	if [ -n "${deviceinfo_dtb}" ]; then
		_dtb="$(find_dtb "$deviceinfo_dtb")"
	fi
	local _dtb_line=""
	if [ -n "$_dtb" ]; then
		_dtb_line="devicetree $(basename "$deviceinfo_dtb").dtb"
	fi

	# (assuming kernel_filename is "vmlinuz") if "vmlinuz.efi" exists then
	# we should prefer using that as it will definitely include the ZBOOT
	# EFI decompressor. It's possible that "vmlinuz" will exist but just be
	# the regular GZIP compressed kernel and won't actually boot with
	# systemd-boot
	if [ -e "${output_dir}/${kernel_filename}.efi" ]; then
		_kernel_filename="${kernel_filename}.efi"
	fi

	# Notes:
	# 	- The ucode lines need to come before the real initramfs in the final
	# 	bootloader config, see:
	# 	https://www.kernel.org/doc/html/next/x86/microcode.html
	# 	- TODO: need to guarantee that distro_prefix is always going to be
	# 	compliant with the BLS!
	cat <<-EOF > "$work_dir/${distro_prefix}.conf"
		title	$distro_name
		sort-key $distro_name
		linux	$_kernel_filename
		$(printf "%s" "$(list_ucode $output_dir)" | sed 's|^|initrd\t|')
		initrd	$initfs_filename
		options $(get_cmdline)
		$_dtb_line
	EOF

	additional_files="$additional_files ${distro_prefix}.conf:loader/entries/${distro_prefix}.conf"
}

# Add support for systemd-boot (and/or gummiboot) by generating necessary
# config and adding dependencies to $additional_files.
add_systemd_boot() {
	[ "$deviceinfo_generate_systemd_boot" = "true" ] || return 0
	log_arrow "systemd-boot: adding support"

	generate_bootloader_spec_conf

	local _found="false"
	# Note: the order of these directories is important! The intention is to
	# prefer systemd-boot over gummiboot, in case both happen to be installed.
	for _basedir in /usr/lib/systemd/boot/efi /usr/lib/gummiboot; do
		[ ! -d "$_basedir" ] && continue
		# only copy app(s) from the first base directory found, to prevent the
		# second set of apps found from overwriting the first
		[ "$_found" = "true" ] && break
		# Copy multiple efi apps if they exist, to allow supporting multiple
		# archs (e.g. 32-bit EFI on x86_64)
		for _efi_app in "$_basedir"/*.efi; do
			log_arrow "systemd-boot: found '$_efi_app'"
			# remove gummi* and systemd-* prefixes
			local _fname
			_fname="$(basename "$_efi_app")"
			_fname="${_fname##gummi}"
			_fname="${_fname##systemd-}"
			_found="true"
			copy "$_efi_app" "$work_dir/$_fname"
			additional_files="$additional_files $_fname:efi/boot/$_fname"
		done
	done
	if [ "$_found" = "false" ]; then
		log "ERROR: no EFI bootloader app found for systemd or gummiboot"
		exit 1
	fi

	local _driver

	# Copy installed efi drivers into the systemd-boot specific directory.
	for _driver in /usr/share/boot-deploy/efi-drivers/*.efi /etc/boot-deploy/efi-drivers/*.efi; do
		[ ! -e "$_driver" ] && continue
		local _fname
		_fname="$(basename "$_driver")"
		copy "$_driver" "$work_dir/$_fname"
		additional_files="$additional_files $_fname:efi/systemd/drivers/$_fname"
	done
}

# Android devices
create_bootimg() {
	[ "${deviceinfo_generate_bootimg}" = "true" ] || return 0
	# shellcheck disable=SC3060
	local _bootimg="$work_dir/boot.img"

	local _mkbootimg
	if [ "${deviceinfo_bootimg_pxa}" = "true" ]; then
		require_package "pxa-mkbootimg" "pxa-mkbootimg" "bootimg_pxa"
		_mkbootimg=pxa-mkbootimg
	elif [ -n "$(command -v mkbootimg-osm0sis)" ]; then
		require_package "mkbootimg-osm0sis" "mkbootimg" "generate_bootimg"
		_mkbootimg=mkbootimg-osm0sis
	else
		require_package "mkbootimg" "android-tools" "generate_bootimg"
		_mkbootimg=mkbootimg
	fi

	log_arrow "initramfs: creating boot.img"
	local _base="${deviceinfo_flash_offset_base}"
	[ -z "$_base" ] && _base="0x10000000"

	local _kernelfile
	if [ -n "$deviceinfo_bootimg_override_payload" ]; then
		if [ -f "$work_dir/$deviceinfo_bootimg_override_payload" ]; then
			payload="$work_dir/$deviceinfo_bootimg_override_payload"
			log_arrow "initramfs: replace kernel with file $payload"
			if [ "$deviceinfo_bootimg_override_payload_compression" = "gzip" ]; then
				log_arrow "initramfs: gzip payload replacement"
				gzip "$payload"
				_kernelfile="$payload.gz"
			else
				_kernelfile="$payload"
			fi
			if [ -n "$deviceinfo_bootimg_override_payload_append_dtb" ]; then
				log_arrow "initramfs: append $deviceinfo_bootimg_override_payload_append_dtb at payload end"
				cat "$work_dir/$deviceinfo_bootimg_override_payload_append_dtb" >> "$_kernelfile"
			fi
		else
			log "File $work_dir/$deviceinfo_bootimg_override_payload not found,"
			log "please, correct deviceinfo_bootimg_override_payload option value."
			exit 1
		fi
	else
		# shellcheck disable=SC3060
		_kernelfile="$work_dir/$kernel_filename"
		if [ "${deviceinfo_append_dtb}" = "true" ]; then
			_kernelfile="${_kernelfile}-dtb"
		fi

		if [ -e "${_kernelfile}-mtk" ]; then
			_kernelfile="${_kernelfile}-mtk"
		fi
	fi

	local _dtb=""
	if [ -n "${deviceinfo_dtb}" ]; then
		_dtb="$(find_dtb "$deviceinfo_dtb")"
	fi

	local _second=""
	if [ "${deviceinfo_bootimg_dtb_second}" = "true" ]; then
		if [ -z "${deviceinfo_dtb}" ]; then
			log "ERROR: deviceinfo_bootimg_dtb_second is set, but"
			log "'deviceinfo_dtb' is missing. Set 'deviceinfo_dtb'"
			log "to the device tree blob for your device."
			log "See also: <https://postmarketos.org/deviceinfo>"
			exit 1
		fi
		if [ -z "${_dtb}" ]; then
			log "ERROR: Couldn't find DTB for ${deviceinfo_dtb}"
			exit 1
		fi
		_second="--second $_dtb"
	fi
	local _dt_img=""
	if [ "${deviceinfo_bootimg_qcdt}" = "true" ]; then
		# Only mkbootimg-osm0sis has support for dt.img
		# Make sure that the program is available.
		require_package "mkbootimg-osm0sis" "mkbootimg" "bootimg_qcdt"
		if [ -n "${deviceinfo_bootimg_qcdt_type}" ]; then
			_dt_img="$work_dir/dt.img"
			if [ -z "${deviceinfo_dtb}" ]; then
				log "ERROR: deviceinfo_bootimg_qcdt_type is set, but"
				log "'deviceinfo_dtb' is missing. Set 'deviceinfo_dtb'"
				log "to the device tree blob for your device."
				log "See also: <https://postmarketos.org/deviceinfo>"
				exit 1
			fi
			if [ -z "${_dtb}" ]; then
				log "ERROR: Couldn't find DTB for ${deviceinfo_dtb}"
				exit 1
			fi
			local _tmp_dtb_path="$work_dir/tmp-dtb"
			case "${deviceinfo_bootimg_qcdt_type}" in
				"exynos")
					require_package "dtbTool-exynos" "dtbtool-exynos" "bootimg_qcdt_type"
					dtbTool-exynos -o "${_dt_img}" "${_dtb}";;
				"sprd")
					require_package "dtbTool-sprd" "dtbtool-sprd" "bootimg_qcdt_type"
					copy "${_dtb}" "$_tmp_dtb_path/$(basename "$_dtb")"
					dtbTool-sprd -o "${_dt_img}" "${_tmp_dtb_path}"
					rm -r "$_tmp_dtb_path";;
				"qcom")
					require_package "dtbTool" "dtbtool" "bootimg_qcdt_type"
					copy "${_dtb}" "$_tmp_dtb_path/$(basename "$_dtb")"
					dtbTool -o "${_dt_img}" "${_tmp_dtb_path}"
					rm -r "$_tmp_dtb_path";;
				"")
					# When 'bootimg_qcdt_type` is not set, expect that
					# dt.img has been generated by the linux APKBUILD.
					;;
				*)
					log "ERROR: deviceinfo_bootimg_qcdt_type has an unrecognized"
					log "value. See also <https://postmarketos.org/deviceinfo>"
					exit 1
			esac
			additional_files="$additional_files $(basename "$_dt_img")"
		else
			# The kernel APKBUILD usually installs the dt.img in /boot/.
			# Check whether the file exists or not.
			_dt_img="/boot/dt.img"
			if ! [ -e "$_dt_img" ]; then
				log "ERROR: File not found: $_dt_img, but"
				log "'deviceinfo_bootimg_qcdt' is set. Please verify that your"
				log "device is a QCDT device by analyzing the boot.img file"
				log "(e.g. 'pmbootstrap bootimg_analyze path/to/twrp.img')"
				log "and based on that, set the deviceinfo variable to false or"
				log "adjust your linux APKBUILD to properly generate the dt.img"
				log "file. See also: <https://postmarketos.org/deviceinfo>"
				exit 1
			fi
		fi
		# Prepend --dt to pass it as an parameter to mkbootimg.
		_dt_img="--dt $_dt_img"
	fi

	local _header_v2=""
	# XXX: Some deviceinfo files used custom_args for header v2 support before it was implemented
	# here. We check if deviceinfo_bootimg_custom_args is set to avoid breaking those devices.
	if [ "$deviceinfo_header_version" = "2" ] && [ -z "$deviceinfo_bootimg_custom_args" ]; then
		if [ -z "$deviceinfo_flash_offset_dtb" ]; then
			log "ERROR: deviceinfo_header_version is 2, but"
			log "'deviceinfo_flash_offset_dtb' is missing. Set it"
			log "to the device tree blob offset for your device."
			log "See also: <https://postmarketos.org/deviceinfo>"
			exit 1
		fi
		if [ -z "${deviceinfo_dtb}" ]; then
			log "ERROR: deviceinfo_header_version is 2, but"
			log "'deviceinfo_dtb' is missing. Set 'deviceinfo_dtb'"
			log "to the device tree blob for your device."
			log "See also: <https://postmarketos.org/deviceinfo>"
		fi
		if [ -z "${_dtb}" ]; then
			log "ERROR: Couldn't find DTB for ${deviceinfo_dtb}"
			exit 1
		fi
		_header_v2="--header_version 2 --dtb_offset $deviceinfo_flash_offset_dtb --dtb $_dtb"
	fi

	local _ramdisk="$work_dir/$initfs_filename"
	if [ -n "$deviceinfo_bootimg_override_initramfs" ]; then
		if [ -f "$work_dir/$deviceinfo_bootimg_override_initramfs" ]; then
			log_arrow "initramfs: replace initramfs with file $work_dir/$deviceinfo_bootimg_override_initramfs"
			_ramdisk="$work_dir/$deviceinfo_bootimg_override_initramfs"
		else
			log "ERROR: file $work_dir/$deviceinfo_bootimg_override_initramfs not found,"
			log "please, correct deviceinfo_bootimg_override_initramfs option value."
			exit 1
		fi
	fi
	# shellcheck disable=SC2039 disable=SC2086
	"${_mkbootimg}" \
		--kernel "${_kernelfile}" \
		--ramdisk "$_ramdisk" \
		--base "${_base}" \
		--second_offset "${deviceinfo_flash_offset_second}" \
		--cmdline "$(get_cmdline)" \
		--kernel_offset "${deviceinfo_flash_offset_kernel}" \
		--ramdisk_offset "${deviceinfo_flash_offset_ramdisk}" \
		--tags_offset "${deviceinfo_flash_offset_tags}" \
		--pagesize "${deviceinfo_flash_pagesize}" \
		${_second} \
		${_dt_img} \
		${_header_v2} \
		${deviceinfo_bootimg_custom_args} \
		-o "$_bootimg" || exit 1
	# shellcheck disable=SC3060
	if [ "${deviceinfo_mkinitfs_postprocess}" != "" ]; then
		sh "${deviceinfo_mkinitfs_postprocess}" "$work_dir/$initfs_filename"
	fi
	if [ "${deviceinfo_bootimg_blobpack}" = "true" ] || [ "${deviceinfo_bootimg_blobpack}" = "sign" ]; then
		log_arrow "initramfs: creating blob"
		local _flags=""
		if [ "${deviceinfo_bootimg_blobpack}" = "sign" ]; then
			_flags="-s"
		fi
		# shellcheck disable=SC3060
		blobpack $_flags "${_bootimg}.blob" \
				LNX "$_bootimg" || exit 1
		# shellcheck disable=SC3060
		copy "${_bootimg}.blob" "$_bootimg"
	fi
	if [ "${deviceinfo_bootimg_append_seandroidenforce}" = "true" ]; then
		log_arrow "initramfs: appending 'SEANDROIDENFORCE' to boot.img"
		printf "SEANDROIDENFORCE" >> "$_bootimg"
	fi
	if [ "${deviceinfo_bootimg_prepend_dhtb}" = "true" ]; then
		printf 'DHTB' | dd of="$work_dir/dhtb_header"
		dd if=/dev/zero bs=508 count=1 >> "$work_dir/dhtb_header"
		log_arrow "initramfs: prepending 'DHTB' to boot.img"
		cat "$work_dir/dhtb_header"  $_bootimg > "$work_dir/boot.temp"
		mv "$work_dir/boot.temp" $_bootimg
	fi
	if [ -n "${deviceinfo_bootimg_amazon_omap_header_size}" ]; then
		log_arrow "initramfs: prepending Amazon OMAP signature exploit to boot.img"
		# Header data sourced from soho exploit.mk
		# https://github.com/TeamWin/android_device_amazon_soho/blob/cm-12.0/exploit.mk#L6
		local _header_data='\x50\x03\x00\x00\x00\x25\xE4\x00'
		local _header_offset=$((0x34))
		local _tmp_file="${work_dir}/boot.temp"
		# Create blank header
		dd if=/dev/zero bs="${deviceinfo_bootimg_amazon_omap_header_size}" count=1 \
			status=none > "${_tmp_file}"
		# Insert header string in the right place
		printf "%b" "${_header_data}" |
			dd of="${_tmp_file}" bs="${_header_offset}" seek=1 conv=notrunc status=none
		# Attach header to bootimg
		cat "${_bootimg}" >> "${_tmp_file}"
		mv "${_tmp_file}" "${_bootimg}"
	fi
	additional_files="$additional_files $(basename "$_bootimg")"
}

is_in_chroot() {
	# This compares the device and inode IDs for / to /proc/1/root, they do
	# not match when in a chroot.
	# It was taken from https://unix.stackexchange.com/a/14346, and this
	# check is also what Debian does in their ischroot tool.
	[ "$(stat -c %d:%i /)" != "$(stat -c %d:%i /proc/1/root/.)" ]
}

flash_updated_boot_parts() {
	[ "${deviceinfo_flash_kernel_on_update}" = "true" ] || return 0
	if is_in_chroot; then
		log_arrow "Not flashing boot in chroot"
		return 0
	fi

	log_arrow "Flashing boot image"

	local method="${deviceinfo_flash_method:?}"
	case $method in
		fastboot)
			flash_android_bootimg "${deviceinfo_flash_fastboot_partition_kernel:-boot}"
			;;
		fastboot-bootpart)
			# Flash the boot image IFF not booting with EFI
			if ! [ -e /sys/firmware/efi ]; then
				flash_android_bootimg boot
			else
				echo "SKIP: booting with EFI"
			fi
			;;
		heimdall-bootimg)
			flash_android_bootimg "${deviceinfo_flash_heimdall_partition_kernel:-KERNEL}"
			;;
		heimdall-isorec)
			flash_android_split_kernel_initfs
			;;
		*)
			log "Flash method \"$method\" is not supported for deviceinfo_flash_kernel_on_update=true."
			return 1
			;;
	esac
	log "Done."
}

# On A/B devices with bootloader cmdline ON this will return the slot suffix
# if booting with an alternate method which erases the stock bootloader cmdline
# this will be empty and the update will fail.
# https://source.android.com/devices/bootloader/updating#slots
# On non-A/B devices this will be empty
ab_get_slot() {
	local ab_slot_suffix
	ab_slot_suffix=$(grep -o 'androidboot\.slot_suffix=..' /proc/cmdline |  cut -d "=" -f2) || :
	echo "$ab_slot_suffix"
}

# $1: partition to flash from deviceinfo
flash_android_bootimg() {
	local partition="$1"
	local boot_part_suffix
	local boot_partition
	boot_part_suffix=$(ab_get_slot) # Empty for non-A/B devices
	boot_partition=$(findfs PARTLABEL="${partition}${boot_part_suffix}")
	log "Flashing boot.img to '${partition}${boot_part_suffix}'"

	if ! check_image_size "$work_dir/boot.img" "$boot_partition"; then
		log_boot_partition_too_small_suggestion
		exit 1
	fi

	dd if="$work_dir/boot.img" of="$boot_partition" bs=1M
}

flash_android_split_kernel_initfs() {
	local kernel_partition
	local initfs_partition
	kernel_partition=$(findfs PARTLABEL="${deviceinfo_flash_heimdall_partition_kernel:?}")
	initfs_partition=$(findfs PARTLABEL="${deviceinfo_flash_heimdall_partition_initfs:?}")

	if [ -z "$kernel_partition" ]; then
		log -n "Couldn't find Heimdall kernel partition! Is"
		log " deviceinfo_flash_heimdall_partition_kernel set correctly?"
		return 1
	fi

	if [ -z "$initfs_partition" ]; then
		log -n "Couldn't find Heimdall initfs partition! Is"
		log " deviceinfo_flash_heimdall_partition_initfs set correctly?"
		return 1
	fi

	local _kernel_path
	_kernel_path="$work_dir"/"$kernel_filename"
	if [ "${deviceinfo_append_dtb}" = "true" ]; then
		_kernel_path="$_kernel_path-dtb"
	fi

	if ! check_image_size "$_kernel_path" "$kernel_partition"; then
		exit 1
	fi

	if ! check_image_size "$work_dir/$initfs_filename" "$initfs_partition"; then
		log_boot_partition_too_small_suggestion
		exit 1
	fi

	log "Flashing kernel ($_kernel_path) ..."
	dd if="$_kernel_path" of="$kernel_partition" bs=1M

	log "Flashing initramfs ..."
	gunzip -c "$work_dir/$initfs_filename" | lzop | dd of="$initfs_partition" bs=1M
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

	local compression

	if [ -z "${deviceinfo_depthcharge_compression}" ]; then
		compression="none"
	else
		compression="${deviceinfo_depthcharge_compression}"
	fi

	depthchargectl build --root none \
		--board "$deviceinfo_depthcharge_board" \
		--kernel "$work_dir/$kernel_filename" \
		--kernel-cmdline "$(get_cmdline)" \
		--initramfs "$work_dir/$initfs_filename" \
		--fdtdir "$work_dir" \
		--compress "$compression" \
		--output "$work_dir/$(basename "$deviceinfo_cgpt_kpart")"

	additional_files="$additional_files $(basename "$deviceinfo_cgpt_kpart")"
}

flash_updated_depthcharge_kernel() {
	[ "${deviceinfo_generate_depthcharge_image}" = "true" ] || return 0

	if is_in_chroot; then
		log_arrow "Not flashing vmlinuz.kpart in chroot"
		return 0
	fi

	log_arrow "Flashing depthcharge kernel image"

	local guid
	local partition

	# shellcheck disable=SC2013
	for x in $(cat /proc/cmdline); do
		[ "$x" = "${x#kern_guid=}" ] && continue
		guid="${x#kern_guid=}"
		partition=$(findfs PARTUUID="$guid")

		if [ -z "$partition" ]; then
			log -n "Failed to find partition to flash depthcharge kernel image"
			log " to! Is kern_guid set correctly in /proc/cmdline?"
			return 1
		fi
		local img
		img="$work_dir"/"$(basename "$deviceinfo_cgpt_kpart")"

		if ! check_image_size "$img" "$partition"; then
			log_boot_partition_too_small_suggestion
			exit 1
		fi
		log "Flashing $deviceinfo_cgpt_kpart to $partition"
		dd if="$img" of="$partition"
	done

	log "Done."
}

create_extlinux_config() {
	[ "${deviceinfo_generate_extlinux_config}" = "true" ] || return 0

	log_arrow "Generating extlinux.conf"

	local _dtbs_count
	_dtbs_count="$(find_all_dtbs | wc -w)"

	local _fdt_line=""
	if [ "$_dtbs_count" -eq 1 ]; then
		# If there is only single dtb specified, add it as "fdt" property
		_fdt_line="fdt /$(basename "$deviceinfo_dtb").dtb"
	elif [ "$_dtbs_count" -gt 1 ]; then
		# If there are multiple dtbs specified, all of these dtbs will
		# be copied to /boot, so it is good enough to use "fdtdir /"
		_fdt_line="fdtdir /"
	fi

	local _cmdline_line=""
	if [ ! "$(get_cmdline)" = " " ]; then
		_cmdline_line="append $(get_cmdline)"
	fi

	cat <<EOF > "$work_dir/extlinux.conf"
timeout 1
default $distro_name
menu title boot prev kernel

label $distro_name
	kernel /$kernel_filename
	$_fdt_line
	initrd /$initfs_filename
	$_cmdline_line
EOF

	additional_files="$additional_files extlinux.conf:/extlinux/extlinux.conf"
}

create_grub_config() {
	[ "${deviceinfo_generate_grub_config}" = "true" ] || return 0

	if [ "$(echo "$deviceinfo_dtb" | wc -w)" -gt 1 ]; then
		log "ERROR: deviceinfo_dtb contains more than one dtb"
		exit 1
	fi

	log_arrow "Generating grub.cfg"

	local _dtb_line=""
	if [ -n "$deviceinfo_dtb" ]; then
		_dtb_line="devicetree /$(basename "$deviceinfo_dtb").dtb"
	fi

	cat <<EOF > "$work_dir/grub.cfg"
timeout=0

menuentry "$distro_name" {
	linux /$kernel_filename $(get_cmdline)
	$(printf "%s" "$(list_ucode $output_dir)" | sed 's|^|initrd /|')
	initrd /$initfs_filename
	$_dtb_line
}
EOF

	additional_files="$additional_files grub.cfg:/grub/grub.cfg"
}

create_cmdline_txt() {
	# Raspberry pi and clones parses /boot/cmdline.txt to get
	# cmdline variables. Put our cmdline into the file.

	[ "${deviceinfo_generate_cmdline_txt}" = "true" ] || return 0

	log_arrow "Generating cmdline.txt"

	get_cmdline > "$work_dir/cmdline.txt"

	additional_files="$additional_files cmdline.txt"
}

# $@: list of files to get total size of, in kilobytes
get_size_of_files() {
	local _total=0
	for _f in "$@"; do
		local _file
		_file="$(echo "$_f" | cut -d':' -f1)"
		local _size
		_size=$(du "$_file" | cut -f1 | sed '$ s/\n$//' | tr '\n' + |sed 's/.$/\n/' | bc -s)
		_total=$((_total+_size))
	done
	echo "$_total"
}

# $1: mount point
# $2: field position in fstab
parse_fstab_entry() {
	local _mount_point="$1"
	if [ -z "$_mount_point" ]; then
		log "parse_fstab_entry(): No mount point specified"
		exit 1
	fi

	local _field="$2"
	if [ -z "$_field" ]; then
		log "parse_fstab_entry(): No field specified"
		exit 1
	fi

	local _fstab
	_fstab=$(grep -v ^\# /etc/fstab | grep .)
	local _ret=""

	# shellcheck disable=SC3003
	IFS=$'\n'
	for _entry in $_fstab; do
		if [ "$(echo "$_entry" | xargs | cut -d" " -f2)" = "$_mount_point" ]; then
			_ret="$(echo "$_entry" | xargs | cut -d" " -f"$_field")"
		fi
	done
	unset IFS

	echo "$_ret"
}

# $1: mount point
parse_crypttab_entry() {
	local _crypttab
	_crypttab=$(grep -v ^\# /etc/crypttab | grep .)
	local _ret=""

	# shellcheck disable=SC3003
	IFS=$'\n'
	for _entry in $_crypttab; do
		if [ "$(echo "$_entry" | xargs | cut -d" " -f1)" = "$1" ]; then
			_ret="$(echo "$_entry" | xargs | cut -d" " -f2)"
		fi
	done
	unset IFS

	echo "$_ret"
}

get_cmdline() {
	local _ret="$deviceinfo_kernel_cmdline $deviceinfo_kernel_cmdline_append"

	local _boot_uuid=""
	local _root_uuid=""
	local _root_opts=""

	if [ -f "/etc/fstab" ]; then
		_boot_uuid=$(parse_fstab_entry "/boot" 1)
		_root_uuid=$(parse_fstab_entry "/" 1)
		_root_opts=$(parse_fstab_entry "/" 4)
	fi

	if [ -f "/etc/crypttab" ]; then
		_root_uuid=$(parse_crypttab_entry "$crypttab_entry")
	fi

	# When appropriate fstab entry does not exist, cmdline will not
	# be passed because of -n checks. In this case, postmarketOS
	# init script will look for partitions according to pmOS_boot
	# and pmOS_root labels.

	if [ -n "$_boot_uuid" ] && [ "$_boot_uuid" != "${_boot_uuid#UUID=}" ]; then
		_ret="$_ret ${distro_prefix}_boot_uuid=${_boot_uuid#UUID=}"
	fi

	if [ -n "$_root_uuid" ] && [ "$_root_uuid" != "${_root_uuid#UUID=}" ]; then
		_ret="$_ret ${distro_prefix}_root_uuid=${_root_uuid#UUID=}"
	fi

	if [ -n "$_root_opts" ]; then
		_ret="$_ret ${distro_prefix}_rootfsopts=${_root_opts}"
	fi

	echo "$_ret"
}

# Returns the relative path to ucode files under the given directory
# $1: directory to ucode file(s)
list_ucode() {
	local _path="$1"

	find "$_path" -name "*ucode.img" -exec basename {} \;
}

# Check that the the given list of files can be copied to the destination, $output_dir,
# atomically
# $@: list of files to check
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

	# First check is that target has enough space for all new files/sizes
	# 1) get size of new files
	local _total_new_size
	_total_new_size=$(get_size_of_files "$@")

	# 2) get size of old files at destination
	local _total_old_size=0
	for _f in "$@"; do
		if [ -f "$output_dir/$(basename "$_f")" ]; then
			_total_old_size=$((_total_old_size+$(get_size_of_files "$_f")))
		fi
	done

	# 3) subtract old size from new size
	local _total_diff_size
	_total_diff_size=$((_total_new_size-_total_old_size))

	# 4) get free space at destination
	local _target_free_space
	_target_free_space=$(get_free_space "$output_dir")

	# does the target have enough free space for diff size of all new files?
	if [ "$_total_diff_size" -ge "$_target_free_space" ]; then
		log "Destination filesystem does not have enough free space!"
		log "Need $_total_diff_size kilobytes, have $_target_free_space kilobytes"
		exit 1
	fi

	# Second check is that each file can be replaced atomically
	# for each new file:
	for _f in "$@"; do
		# 1) get size of new file
		local _f_size
		_f_size=$(get_size_of_files "$_f")
		# 2) does target have enough free space for the new file size?
		if [ "$_f_size" -ge "$_target_free_space" ]; then
			log "Destination filesystem does not have enough free space to copy this file atomically: $_f"
			log "Need $_f_size kilobytes, have $_target_free_space kilobytes"
		fi
	done
	echo "... OK!"
}

# $1: name of dtb to find
find_dtb() {
	local _filename="$1"

	if [ -z "$_filename" ]; then
		log "ERROR: dtb name was an empty string"
		exit 1
	fi

	# FIXME: Currently, this always uses the first dtb found, which may not always
	# be correct. This should only be an issue if you have multiple kernels
	# that provide the same dtb installed, which pmOS does not support, but it is
	# still potentially unexpected behaviour.

	local _dtb_found="false"
	local _dtb=
	# Alpine and modern pmOS dtb paths
	_dtb="$(find /boot -path "/boot/dtbs*/$_filename.dtb")"
	if [ -n "$_dtb" ] ; then
		_dtb_found="true"
	fi
	# Legacy postmarketOS dtb path (for backwards compatibility)
	if [ -e "/usr/share/dtb/$_filename.dtb" ] && [ "$_dtb_found" = "false" ]; then
		_dtb="/usr/share/dtb/$_filename.dtb"
		_dtb_found="true"
	fi
	if [ "$_dtb_found" = "false" ]; then
		log "ERROR: Unable to find $_filename.dtb in the following locations:"
		log "    - /boot/dtbs*"
		log "    - /usr/share/dtb/"
		exit 1
	fi

	echo "$_dtb"
}

# Iterates through deviceinfo_dtb and calls find_dtb on each item
find_all_dtbs() {
	local _dtbs=""

	for _filename in $deviceinfo_dtb; do
		_dtbs="$_dtbs $(find_dtb "$_filename")"
	done

	echo "$_dtbs"
}

# Prints a suggestion on how to maybe fix the boot partition too small problem.
log_boot_partition_too_small_suggestion() {
	log "If this is the first time you're seeing this error, please try opting-in to"
	log "initramfs-extra by setting deviceinfo_create_initfs_extra=true"
	log "See https://wiki.postmarketos.org/wiki/Deviceinfo_reference for more information"
}

# $1: Message to log. Will be prefixed by an arrow.
log_arrow() {
	log "==> $1"
}

# $@: Same interface as the one provided by echo.
log() {
	# Redirect the message to stderr so it doesn't get captured as a "return
	# value" in functions that use stdout for returning data.
	echo "$@" 1>&2
}
