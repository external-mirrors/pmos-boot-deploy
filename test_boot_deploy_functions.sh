#!/bin/sh -e

# shellcheck disable=SC1091
. boot-deploy-functions.sh

wdir="$(mktemp -d /tmp/boot-deploy-test.XXXXXX)"
trap 'rm -rf $wdir' INT EXIT TERM

test_get_size_of_files() {
	for f in f1 f2 f3 f4 f5; do
		dd if=/dev/zero of="$wdir/$f" bs=1K count=37 >/dev/null 2>&1
	done
	size=$(get_size_of_files "$wdir/f1 $wdir/f2 $wdir/f3 $wdir/f4 $wdir/f5")

	ret=0
	# exact size depends on the filesystem, so just make sure it's roughly in the same ballpark
	if [ "$size" -ge 225 ] || [ "$size" -le 150 ]; then
		echo "test_get_size_of_files: failed, expected: ~150-225 kilobytes, got: $size kilobytes"
		ret=1
	fi

	[ $ret -eq 0 ] && echo "test_get_size_of_files: pass"
	return $ret

}

test_get_size_of_files || exit 1
