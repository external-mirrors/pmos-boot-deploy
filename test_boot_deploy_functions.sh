#!/bin/sh -e

# shellcheck disable=SC1091
. boot-deploy-functions.sh

# $1: directory to remove/cleanup
# $2: return code
cleanup() {
	if [ -d "$1" ]; then
		rm -r "$1"
	fi

	exit "$2"
}

test_get_size_of_files() {
	wdir=$(mktemp -d /tmp/boot-deploy-test.XXXXXX)
	for f in f1 f2 f3 f4 f5; do
		dd if=/dev/zero of="$wdir/$f" bs=1K count=37 >/dev/null 2>&1
	done
	size=$(get_size_of_files "$wdir/f1 $wdir/f2 $wdir/f3 $wdir/f4 $wdir/f5")

	# exact size depends on the filesystem, so just make sure it's roughly in the same ballpark
	if [ "$size" -ge 225 ] || [ "$size" -le 150 ]; then
		echo "test_get_size_of_files: failed, expected: ~150-225 kilobytes, got: $size kilobytes"
		cleanup "$wdir" 1
	fi

	echo "test_get_size_of_files: pass"

	cleanup "$wdir" 0
}

test_get_size_of_files
