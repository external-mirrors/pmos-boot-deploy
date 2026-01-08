#!/bin/sh

srcdir="$(dirname "$(realpath "$0")")/.."
testlib_path="$1"
shift
# Used by testlib.sh
# shellcheck disable=SC2034
results_dir="$1"
shift

# All arguments have to be consumed before sourcing testlib!
# shellcheck disable=SC1090
. "$testlib_path"

tool="$srcdir/generate-kernel-cmdline"

### Test 1 ###
start_test "Override params"
create_test_root

mkdir -p usr/lib/kernel-cmdline.d etc/kernel-cmdline.d

cat > usr/lib/kernel-cmdline.d/00-test.conf <<EOF
quiet
console=tty0
EOF

cat > etc/kernel-cmdline.d/00-test.conf <<EOF
loglevel=4
EOF

output=$(CONFIG_ROOT="$(pwd)" "$tool")
expected="loglevel=4"

assert_strequal "$output" "$expected"

cleanup_test_root
end_test

### Test 2 ###
start_test "Basic remove, exact match"
create_test_root

mkdir -p usr/lib/kernel-cmdline.d

cat > usr/lib/kernel-cmdline.d/00-base.conf <<EOF
quiet
console=tty0
loglevel=4
EOF

cat > usr/lib/kernel-cmdline.d/01-remove.conf <<EOF
-quiet
-loglevel=4
EOF

output=$(CONFIG_ROOT="$(pwd)" "$tool")
expected="console=tty0"

assert_strequal "$output" "$expected"

cleanup_test_root
end_test

### Test 3 ###
start_test "Remove nonexistent param, noop"
create_test_root

mkdir -p usr/lib/kernel-cmdline.d

cat > usr/lib/kernel-cmdline.d/00-base.conf <<EOF
quiet
console=tty0
EOF

cat > usr/lib/kernel-cmdline.d/01-remove.conf <<EOF
-nonexistent
-also=nothere
EOF

output=$(CONFIG_ROOT="$(pwd)" "$tool")
expected="quiet console=tty0"

assert_strequal "$output" "$expected"

cleanup_test_root
end_test

### Test 4 ###
start_test "Processing order across directories"
create_test_root

mkdir -p usr/lib/kernel-cmdline.d etc/kernel-cmdline.d

cat > usr/lib/kernel-cmdline.d/00-base.conf <<EOF
from_usr_lib
EOF

cat > usr/lib/kernel-cmdline.d/50-pkg.conf <<EOF
from_usr_lib_50
EOF

cat > etc/kernel-cmdline.d/00-user.conf <<EOF
from_etc
EOF

cat > etc/kernel-cmdline.d/99-local.conf <<EOF
from_etc_99
EOF

output=$(CONFIG_ROOT="$(pwd)" "$tool")
expected="from_usr_lib from_etc from_usr_lib_50 from_etc_99"

assert_strequal "$output" "$expected"

cleanup_test_root
end_test

### Test 5 ###
start_test "Same param from multiple configs, no duplicates"
create_test_root

mkdir -p usr/lib/kernel-cmdline.d

cat > usr/lib/kernel-cmdline.d/00-base.conf <<EOF
console=tty0
quiet
EOF

cat > usr/lib/kernel-cmdline.d/50-pkg.conf <<EOF
console=tty0
loglevel=4
EOF

output=$(CONFIG_ROOT="$(pwd)" "$tool")
expected="console=tty0 quiet loglevel=4"

assert_strequal "$output" "$expected"

cleanup_test_root
end_test

### Test 6 ###
start_test "Removing exact match"
create_test_root

mkdir -p usr/lib/kernel-cmdline.d etc/kernel-cmdline.d

cat > usr/lib/kernel-cmdline.d/00-base.conf <<EOF
console=tty0
console=ttyMSM0,115200
quiet
EOF

# Remove console=ttyMSM0,115200 specifically
cat > etc/kernel-cmdline.d/01-remove.conf <<EOF
-console=ttyMSM0,115200
EOF

output=$(CONFIG_ROOT="$(pwd)" "$tool")
expected="console=tty0 quiet"

assert_strequal "$output" "$expected"

# Try removing valueless console param, should not remove param with value
cat > etc/kernel-cmdline.d/01-remove.conf <<EOF
-console
EOF

output=$(CONFIG_ROOT="$(pwd)" "$tool")
expected="console=tty0 console=ttyMSM0,115200 quiet"

assert_strequal "$output" "$expected"

cleanup_test_root
end_test

### Test 7 ###
start_test "Masking with empty file"
create_test_root

mkdir -p usr/lib/kernel-cmdline.d etc/kernel-cmdline.d

cat > usr/lib/kernel-cmdline.d/00-base.conf <<EOF
from_base
EOF

cat > usr/lib/kernel-cmdline.d/10-pkg.conf <<EOF
splash
EOF

touch etc/kernel-cmdline.d/00-base.conf

output=$(CONFIG_ROOT="$(pwd)" "$tool")
expected="splash"

assert_strequal "$output" "$expected"

cleanup_test_root
end_test

### Test 8 ###
start_test "Masking with symlink to /dev/null"
create_test_root

mkdir -p usr/lib/kernel-cmdline.d etc/kernel-cmdline.d

cat > usr/lib/kernel-cmdline.d/00-base.conf <<EOF
from_base
EOF

cat > usr/lib/kernel-cmdline.d/10-pkg.conf <<EOF
splash
EOF

ln -s /dev/null etc/kernel-cmdline.d/00-base.conf

output=$(CONFIG_ROOT="$(pwd)" "$tool")
expected="splash"

assert_strequal "$output" "$expected"

cleanup_test_root
end_test

### Test 9 ###
start_test "Ignore comments and empty lines"
create_test_root

mkdir -p usr/lib/kernel-cmdline.d

cat > usr/lib/kernel-cmdline.d/00-test.conf <<EOF
# This is a comment
quiet

# Another comment
console=tty0

loglevel=4
# Final comment
EOF

output=$(CONFIG_ROOT="$(pwd)" "$tool")
expected="quiet console=tty0 loglevel=4"

assert_strequal "$output" "$expected"

cleanup_test_root
end_test

end_testsuite
