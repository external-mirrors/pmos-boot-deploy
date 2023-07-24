#!/bin/sh -e

# shellcheck disable=SC1091
. boot-deploy-functions.sh

wdir="$(mktemp -d /tmp/boot-deploy-test.XXXXXX)"
trap 'rm -rf $wdir; exit 1' INT EXIT TERM

test_get_size_of_files() {
	for _f in f1 f2 f3 f4 f5; do
		dd if=/dev/zero of="$wdir/$_f" bs=1K count=37 >/dev/null 2>&1
	done
	local _size
	# shellcheck disable=SC2086
	_size=$(get_size_of_files $wdir/f1 $wdir/f2 $wdir/f3 $wdir/f4 $wdir/f5:/foo/f5)

	local _ret=0
	# exact size depends on the filesystem, so just make sure it's roughly in the same ballpark
	if [ "$_size" -ge 225 ] || [ "$_size" -le 150 ]; then
		echo "test_get_size_of_files: failed, expected: ~150-225 kilobytes, got: $_size kilobytes"
		_ret=1
	fi

	[ $_ret -eq 0 ] && echo "test_get_size_of_files: pass"
	return $_ret
}

test_copy_files() {
	output_dir="$wdir/out"
	local _in="$wdir/in"
	mkdir -p "$_in"
	mkdir -p "$output_dir"
	touch "$_in/foo"
	touch "$_in/bar"
	touch "$_in/has space"

	# shellcheck disable=SC2086
	copy_files $_in/foo:/usr/bin/foo $_in/bar "$_in/has space"

	local _ret=0
	if [ ! -e "$output_dir/usr/bin/foo" ]; then
		echo "test_copy_files: fail - expected to copy a file with src:dest format!"
		_ret=1
	elif [ ! -e "$output_dir/bar" ]; then
		echo "test_copy_files: fail - expected to copy a file!"
		_ret=1
	elif [ ! -e "$output_dir/has space" ]; then
		echo "test_copy_files: fail - expected to copy a file with a space in the path!"
		_ret=1
	fi

	[ $_ret -eq 0 ] && echo "test_copy_files: pass"
	return $_ret
}

test_invalid_dtb() {
	# shellcheck disable=SC2091
	if $(find_dtb "bogus_dts") ; then
		echo "test_invalid_dtb: find_dtb should've failed"
		return 1
	fi

	echo "test_invalid_dtb: pass"
	return 0
}

test_extlinux_config() {
	work_dir="./"
	# shellcheck disable=SC2034
	deviceinfo_generate_extlinux_config="true"
	# shellcheck disable=SC2034
	distro_name="postmarketOS"
	# shellcheck disable=SC2034
	kernel_filename="vmlinuz"
	# shellcheck disable=SC2034
	initfs_filename="initramfs"
	# shellcheck disable=SC2034
	additional_files=""

	local _ret=0
	local _result
	local _expected_result

	# cmdline + 1 dtb

	# shellcheck disable=SC2034
	deviceinfo_dtb="mediatek/mt8173-elm-hana"

	unset -f get_cmdline
	get_cmdline() {
		# shellcheck disable=SC2317
		echo "test test test"
	}

	create_extlinux_config

	_expected_result="$(cat extlinux-examples/extlinux.conf.1)"
	_result="$(cat $work_dir/extlinux.conf)"

	if [ ! "$_result" = "$_expected_result" ]; then
		_ret=1
		echo "test_extlinux_config (cmdline + 1 dtb): fail"
	else
		echo "test_extlinux_config (cmdline + 1 dtb): pass"
	fi

	# cmdline + multiple dtbs

	# shellcheck disable=SC2034
	deviceinfo_dtb="mediatek/mt8173-elm-hana mediatek/mt8173-elm-hana-rev7"

	unset -f get_cmdline
	get_cmdline() {
		# shellcheck disable=SC2317
		echo "test test test"
	}

	create_extlinux_config

	_expected_result="$(cat extlinux-examples/extlinux.conf.2)"
	_result="$(cat $work_dir/extlinux.conf)"

	if [ ! "$_result" = "$_expected_result" ]; then
		_ret=1
		echo "test_extlinux_config (cmdline + multiple dtbs): fail"
	else
		echo "test_extlinux_config (cmdline + multiple dtbs): pass"
	fi

	# no cmdline + 1 dtb

	# shellcheck disable=SC2034
	deviceinfo_dtb="mediatek/mt8173-elm-hana"

	unset -f get_cmdline
	get_cmdline() {
		# shellcheck disable=SC2317
		echo " "
	}

	create_extlinux_config

	_expected_result="$(cat extlinux-examples/extlinux.conf.3)"
	_result="$(cat $work_dir/extlinux.conf)"

	if [ ! "$_result" = "$_expected_result" ]; then
		_ret=1
		echo "test_extlinux_config (no cmdline + 1 dtb): fail"
	else
		echo "test_extlinux_config (no cmdline + 1 dtb)): pass"
	fi

	return $_ret
}

test_find_dtb() {
	# the dtb search path is currently hard-coded in find_dtb to /boot/dtb, so
	# let's doctor up the filename param to include the wdir path to let us
	# test this without having to write to /boot

	local _ret=0
	local _result
	dtb_boot_path="$wdir/find_dtb"
	mkdir -p "$dtb_boot_path/dtbs"
	touch "$dtb_boot_path/dtbs/test_a.dtb"
	touch "$dtb_boot_path/dtbs/test_b.dtb"
	local _expected="$dtb_boot_path/dtbs/test_a.dtb $dtb_boot_path/dtbs/test_b.dtb"

	_result=$(find_dtb "test*")

	if [ ! "$_result" = "$_expected" ]; then
		_ret=1
		echo "test_find_dtb failed"
		echo "    expected: $_expected"
		echo "    got: $_result"
	else
		echo "test_find_dtb: pass"
	fi

	return $_ret
}

test_get_size_of_files
test_copy_files
test_invalid_dtb
test_find_dtb
test_extlinux_config

rm -rf "$wdir"
trap - INT EXIT TERM
