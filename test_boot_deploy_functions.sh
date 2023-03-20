#!/bin/sh -e

# shellcheck disable=SC1091
. boot-deploy-functions.sh

wdir="$(mktemp -d /tmp/boot-deploy-test.XXXXXX)"
trap 'rm -rf $wdir' INT EXIT TERM

test_get_size_of_files() {
	for f in f1 f2 f3 f4 f5; do
		dd if=/dev/zero of="$wdir/$f" bs=1K count=37 >/dev/null 2>&1
	done
	# shellcheck disable=SC2086
	size=$(get_size_of_files $wdir/f1 $wdir/f2 $wdir/f3 $wdir/f4 $wdir/f5:/foo/f5)

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
	touch "$_in/has space"

	# shellcheck disable=SC2086
	copy_files $_in/foo:/usr/bin/foo $_in/bar "$_in/has space"

	ret=0
	if [ ! -e "$output_dir/usr/bin/foo" ]; then
		echo "test_copy_files: fail - expected to copy a file with src:dest format!"
		ret=1
	elif [ ! -e "$output_dir/bar" ]; then
		echo "test_copy_files: fail - expected to copy a file!"
		ret=1
	elif [ ! -e "$output_dir/has space" ]; then
		echo "test_copy_files: fail - expected to copy a file with a space in the path!"
		ret=1
	fi

	[ $ret -eq 0 ] && echo "test_copy_files: pass"
	return $ret
}

test_equal() {
	_func="test_equal"
	# lhs:rhs
	_tests="all_lower:all_lower HeYyY:heyyy"

	ret=0
	for _test in $_tests; do
		_l="$(echo "$_test" | cut -d':' -f1 -s)"
		_r="$(echo "$_test" | cut -d':' -f2 -s)"

		# this is fatal, it means I screwed up with writing tests. So don't
		# waste space to print some nice error
		[ -z "$_l" ] && exit 1

		if ! equal "$_l" "$_r" ; then
			echo "$_func: fail - expected strings to be equal: '$_l', '$_r'"
			ret=1
		fi
	done

	[ $ret -eq 0 ] && echo "$_func: pass"

	return $ret
}

test_get_size_of_files || exit 1
test_copy_files || exit 1
test_equal || exit 1
