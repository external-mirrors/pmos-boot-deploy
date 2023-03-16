#!/bin/sh -e

# shellcheck disable=SC1091
. boot-deploy-functions.sh

wdir="$(mktemp -d /tmp/boot-deploy-test.XXXXXX)"
trap 'rm -rf $wdir; exit 1' INT EXIT TERM

test_get_size_of_files() {
	for f in f1 f2 f3 f4 f5; do
		dd if=/dev/zero of="$wdir/$f" bs=1K count=37 >/dev/null 2>&1
	done
	size=$(get_size_of_files "$wdir/f1 $wdir/f2 $wdir/f3 $wdir/f4 $wdir/f5:/foo/f5")

	ret=0
	# exact size depends on the filesystem, so just make sure it's roughly in the same ballpark
	if [ "$size" -ge 225 ] || [ "$size" -le 150 ]; then
		echo "test_get_size_of_files: failed, expected: ~150-225 kilobytes, got: $size kilobytes"
		ret=1
	fi

	[ $ret -eq 0 ] && echo "test_get_size_of_files: pass"
	return $ret
}

test_copy_files() {
	output_dir="$wdir/out"
	_in="$wdir/in"
	mkdir -p "$_in"
	mkdir -p "$output_dir"
	touch "$_in/foo"
	touch "$_in/bar"

	copy_files "$_in/foo:/usr/bin/foo $_in/bar"

	ret=0
	if [ ! -e "$output_dir/usr/bin/foo" ]; then
		echo "test_copy_files: fail - expected to copy a file with src:dest format!"
		ret=1
	elif [ ! -e "$output_dir/bar" ]; then
		echo "test_copy_files: fail - expected to copy a file!"
		ret=1
	fi
	[ $ret -eq 0 ] && echo "test_copy_files: pass"
	return $ret
}

test_get_size_of_files
test_copy_files

rm -rf "$wdir"
trap - INT EXIT TERM
