#!/bin/sh

set -e

device=$(pmbootstrap config device)
rootfs="$(pmbootstrap config work)/chroot_rootfs_$device"

# boot-deploy arguments that we source later for checking
kernel_filename=""
initfs_filename=""
work_dir=""
output_dir=""

# boot-deploy distro config
distro_prefix=""

# deviceinfo variables we use (declared to make shellcheck happy)
deviceinfo_generate_extlinux_config=""
deviceinfo_generate_bootimg=""
deviceinfo_generate_systemd_boot=""
# TODO: Implement grub config validation
#deviceinfo_generate_grub_config=""
deviceinfo_append_dtb=""
deviceinfo_dtb=""
deviceinfo_cgpt_kpart=""

assert_failed=""

assert_exists() {
	local _files=""
	if [ -z "$1" ]; then
		echo "ERROR: assert_exists: no argument given"
		exit 1
	fi

	if [ ! -e "$1" ]; then
		echo "    ❌ $1 NOT found"
		return
	fi

	_files="$(find . -wholename "$1")"

	# And check it's not empty!
	for _file in $_files; do
		if [ ! -s "$_file" ]; then
			echo "    ❌ $_file exists but is empty"
			assert_failed="true"
			return
		fi
	done
	echo "    ✅ $1 exists"
}

assert_same() {
	if [ -z "$1" ] || [ -z "$2" ]; then
		echo "ERROR: assert_same: not enough arguments given"
		exit 1
	fi
	# If a third argument is given, print it and skip
	if [ -n "$3" ]; then
		echo "    ❓ assert_same: $1 == $2 ($3)"
		return
	fi
	assert_exists "$1"
	assert_exists "$2"
	if ! diff -q "$1" "$2"; then
		echo "    ❌ $1 and $2 differ"
		assert_failed="true"
		return
	fi
	echo "    ✅ $1 and $2 are identical"
}

assert_equal() {
	if [ -z "$1" ] || [ -z "$2" ]; then
		echo "ERROR: assert_equal: not enough arguments given"
		exit 1
	fi
	if [ "$1" != "$2" ]; then
		echo "    ❌ $1 != $2"
		assert_failed="true"
		return
	fi
	echo "    ✅ $1 == $2"
}

echo "==> Building a pmOS rootfs for $device"
# Now do a full install, running boot-deploy in a real environment
pmbootstrap install --no-image --password 1

# Replace the installed boot-deploy with the local copy
echo "==> Installing boot-deploy to device chroot"
# we use a wrapper script to install it as boot-deploy.real
sudo cp boot-deploy "$rootfs"/sbin/boot-deploy.real
sudo cp boot-deploy-functions.sh "$rootfs"/usr/share/boot-deploy/boot-deploy-functions.sh

echo "==> Installing boot-deploy wrapper"
# Create a wrapper to record the arguments passed to boot-deploy
# and make a copy of the work dir
cat > "boot-deploy-wrapper" <<EOF
#!/bin/sh
orig_args="\$@"
extra_args=""

echo "## Wrapper script for boot-deploy ##"
echo "==> args: \$orig_args"

# getopts / get_options set the following 'global' variables:
kernel_filename=
initfs_filename=
work_dir=
output_dir="/boot"
local_deviceinfo=""

while getopts k:i:d:o:c: opt
do
	case \$opt in
		k)
			kernel_filename="\$OPTARG";;
		i)
			initfs_filename="\$OPTARG";;
		d)
			work_dir="\$OPTARG";;
		o)
			output_dir="\$OPTARG";;
		c)
			local_deviceinfo="\$OPTARG";;
		?)
			extra_args="\$extra_args -\$opt \$OPTARG";;
	esac
done

cp -r "\$work_dir" "\$work_dir.copy"

# Boot-deploy gets run twice so clear the args file
echo "" > /tmp/boot-deploy.args
echo "kernel_filename=\$kernel_filename" >> "/tmp/boot-deploy.args"
echo "initfs_filename=\$initfs_filename" >> "/tmp/boot-deploy.args"
echo "work_dir=\$work_dir.copy" >> "/tmp/boot-deploy.args"
echo "output_dir=\$output_dir" >> "/tmp/boot-deploy.args"
echo "local_deviceinfo=\$local_deviceinfo" >> "/tmp/boot-deploy.args"

exec /sbin/boot-deploy.real \$orig_args
EOF
chmod +x "boot-deploy-wrapper"
sudo mv "boot-deploy-wrapper" "$rootfs/sbin/boot-deploy"

echo "==> Running boot-deploy in chroot"
pmbootstrap chroot -r mkinitfs

echo "❕ Parsing results"

assert_exists "$rootfs/tmp/boot-deploy.args"

# Source the boot-deploy arguments from the wrapper script
# shellcheck disable=SC1091
. "$rootfs/tmp/boot-deploy.args"

echo "    📝 kernel_filename: $kernel_filename"
echo "    📝 initfs_filename: $initfs_filename"
echo "    📝 work_dir: $work_dir"
echo "    📝 output_dir: $output_dir"

# Source boot-deploy distro config
# shellcheck disable=SC1091
. "$rootfs/usr/share/boot-deploy/os-customization"

# shellcheck disable=SC1091
. "$rootfs/usr/share/deviceinfo/deviceinfo"
# shellcheck disable=SC1091
. "$rootfs/etc/deviceinfo"

if [ "$output_dir" != "/boot" ]; then
	echo "WARN: output_dir is not /boot, this is weird: $output_dir"
fi

# take ownership so we can inspect it...
sudo chown -R "$USER" "$rootfs/$work_dir"
sudo chown -R "$USER" "$rootfs/$output_dir"
sudo mv "$rootfs/$work_dir" work
sudo mv "$rootfs/$output_dir" boot

# set -x
# ls -la work
# ls -la boot
# set +x

boot_dir="boot"
kernel_with_dtb="work/$kernel_filename"

##
## Inspect the chroot and validate boot-deploy behaviour
##

if [ "$deviceinfo_append_dtb" = "true" ]; then
	kernel_with_dtb="${kernel_with_dtb}-dtb"
fi

validate_bootimg() {
	if [ -z "$deviceinfo_generate_bootimg" ]; then
		return
	fi

	assert_exists "$boot_dir/boot.img"

	mkdir bootimg_extract
	unpack_bootimg \
		--boot_img "$boot_dir/boot.img" \
		--out bootimg_extract \
		--format=mkbootimg \
		> bootimg_extract/mkbootimg_args

	# Check that the kernel and initramfs are in the boot image
	# and match the source files
	assert_same "$kernel_with_dtb" bootimg_extract/kernel
	echo "    Checking that the boot image contains the initramfs"
	assert_equal "$(stat -c%s bootimg_extract/ramdisk)" "$(stat -c%s work/"$initfs_filename")"
}

parse_conf_entry() {
	local key="$1"
	local file="$2"

	# Find the line with the key and print the value
	# Match bootloader spec config files or anything
	# else space separated
	sed -nr "s/\s*${key}\s+(.+)$/\1/p" "$file"
}

validate_systemd_boot() {
	local sd_dtb=""
	local sd_kernel=""
	if [ -z "$deviceinfo_generate_systemd_boot" ]; then
		return
	fi

	assert_exists "boot/efi/boot/bootaa64.efi"

	local sd_conf="boot/loader/entries/${distro_prefix}.conf"
	assert_exists "$sd_conf"

	# Ensure devicetree is specified if it should be
	if [ -n "$deviceinfo_dtb" ]; then
		if ! grep -q "devicetree" "$sd_conf"; then
			echo "ERROR: systemd-boot config missing devicetree line but \$deviceinfo_dtb is set"
			exit 1
		fi
		sd_dtb="$(parse_conf_entry "devicetree" "$sd_conf")"
		assert_equal "$(basename "$deviceinfo_dtb").dtb" "$sd_dtb"
	fi

	# Check kernel file is correct
	if ! grep -q "linux" "$sd_conf"; then
		echo "ERROR: systemd-boot config missing linux line"
		exit 1
	fi

	sd_kernel="$(parse_conf_entry "linux" "$sd_conf")"
	assert_equal "$(basename "$kernel_filename")" "$sd_kernel"
}

validate_depthcharge() {
	if [ -z "$deviceinfo_generate_depthcharge_image" ]; then
		return
	fi

	assert_exists "boot/$(basename "$deviceinfo_cgpt_kpart")"
}

validate_extlinux() {
	local extlinux_kernel=""
	local extlinux_dtb=""
	if [ -z "$deviceinfo_generate_extlinux_config" ]; then
		return
	fi

	assert_exists "boot/extlinux/extlinux.conf"

	# FIXME: This is quite brittle
	extlinux_kernel="$(parse_conf_entry "kernel" "boot/extlinux/extlinux.conf")"
	assert_equal "$(basename "$kernel_filename")" "$(basename "$extlinux_kernel")"

	if echo "$deviceinfo_dtb" | grep -qe "\( \|\*\)"; then
		# Multiple DTBs
		if ! grep -q "fdtdir" "boot/extlinux/extlinux.conf"; then
			echo "ERROR: extlinux config missing fdt line but \$deviceinfo_dtb is set"
			exit 1
		else
			echo "    ✅ fdtdir specified in extlinux config"
		fi
	else
		# Single DTB
		if [ -n "$deviceinfo_dtb" ]; then
			extlinux_dtb="$(parse_conf_entry "fdt" "boot/extlinux/extlinux.conf")"
			assert_equal "$(basename "$deviceinfo_dtb").dtb" "$(basename "$extlinux_dtb")"
		fi
	fi
}

echo
echo
echo "❕ Checking contents of /boot"
assert_exists "$boot_dir/$kernel_filename"
assert_exists "$boot_dir/$initfs_filename"
# MR 48: always copy DTBs to /boot
for _filename in $deviceinfo_dtb; do
	_dtb="$(basename "$_filename").dtb"
	assert_exists "$boot_dir/$_dtb"
done
# Assert that the dtb was appended if it should have been
if [ "$deviceinfo_append_dtb" = "true" ]; then
	assert_exists "$kernel_with_dtb"
fi
echo "❕ Validating Android bootimg handling"
validate_bootimg
echo "❕ Validating systemd-boot config"
validate_systemd_boot
echo "❕ Validating Chromebook depthcharge image handling"
validate_depthcharge
echo "❕ Validating extlinux config"
validate_extlinux

if [ -n "$assert_failed" ]; then
	echo "❌ Some assertions failed"
	exit 1
fi
