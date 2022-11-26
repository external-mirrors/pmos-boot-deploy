#!/bin/sh -e

# shellcheck disable=SC1091
. boot-deploy-functions.sh

run_status=0
# $1: directory to remove/cleanup
# $2: return code
cleanup() {
	if [ -d "$1" ]; then
		rm -r "$1"
	fi

	if [ "$run_status" -eq "$2" ]; then
		run_status=1
	fi
}

make_android_boot_img() {
	if [ "${deviceinfo_bootimg_pxa}" = "true" ]; then
		require_package "pxa-mkbootimg" "pxa-mkbootimg" "bootimg_pxa"
		MKBOOTIMG=pxa-mkbootimg
	else
		require_package "mkbootimg-osm0sis" "mkbootimg" "generate_bootimg"
		MKBOOTIMG=mkbootimg-osm0sis
	fi

	echo "kernel" > "$1/kernel"
	echo "ramdisk" > "$1/ramdisk"
	cat << EOF > "$1/dts1"
/dts-v1/;
/ {
	chosen { };
};
EOF
	cat << EOF > "$1/dts2"
/dts-v1/;
/ {
	chosen { };
};
EOF
	dtc -I dts -O dtb -o "$1/dtb1" "$1/dts1"
	dtc -I dts -O dtb -o "$1/dtb2" "$1/dts2"
	cat "$1/dtb1" "$1/dtb2" > "$1/dtb"
	$MKBOOTIMG \
	--kernel "$1/kernel" \
	--ramdisk "$1/ramdisk" \
	--dtb "$1/dtb" \
	--cmdline "cmdline" \
	--base "0x0" \
	--kernel_offset "0x8000" \
	--ramdisk_offset "0x4000" \
	--tags_offset "0x5000" \
	--pagesize "4096" \
	-o "$1/boot/android.img"
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

test_unpack_android_boot_image() {
	wdir=$(mktemp -d /tmp/boot-deploy-test.XXXXXX)

	should_unpack_android_image=1
	bootimg_vendor_filename="android.img"
	bootimg_vendor="$wdir/boot/$bootimg_vendor_filename"
	bootimg_vendor_extract_dir="${bootimg_vendor%.*}"
	mkdir -p "$wdir/boot/"
	make_android_boot_img "$wdir"
	unpack_android_boot_image

	if [ "$(cat "$bootimg_vendor_extract_dir/${bootimg_vendor_filename}-kernel")" != "kernel" ]; then
		echo "file $bootimg_vendor_extract_dir/${bootimg_vendor_filename}-kernel should be extracted with 'kernel' content"
		cleanup "$wdir" 1
		exit 1
	fi
	if [ "$(cat "$bootimg_vendor_extract_dir/${bootimg_vendor_filename}-ramdisk")" != "ramdisk" ]; then
		echo "file $bootimg_vendor_extract_dir/${bootimg_vendor_filename}-ramdisk should be extracted with 'ramdisk' content"
		cleanup "$wdir" 1
		exit 1
	fi
	if [ "$(cat "$bootimg_vendor_extract_dir/${bootimg_vendor_filename}-cmdline")" != "cmdline" ]; then
		echo "file $bootimg_vendor_extract_dir/${bootimg_vendor_filename}-cmdline should be extracted with 'cmdline' content"
		cleanup "$wdir" 1
		exit 1
	fi
	if [ "$(cat "$bootimg_vendor_extract_dir/${bootimg_vendor_filename}-base")" != "0x00000000" ]; then
			echo "file $bootimg_vendor_extract_dir/${bootimg_vendor_filename}-base should be extracted with '0x00000000' content"
			cleanup "$wdir" 1
			exit 1
	fi
	if [ "$(cat "$bootimg_vendor_extract_dir/${bootimg_vendor_filename}-kernel_offset")" != "0x00008000" ]; then
		echo "file $bootimg_vendor_extract_dir/${bootimg_vendor_filename}-kernel_offset should be extracted with '0x00008000' content"
		cleanup "$wdir" 1
		exit 1
	fi
	if [ "$(cat "$bootimg_vendor_extract_dir/${bootimg_vendor_filename}-ramdisk_offset")" != "0x00004000" ]; then
		echo "file $bootimg_vendor_extract_dir/${bootimg_vendor_filename}-ramdisk_offset should be extracted with '0x00004000' content"
		cleanup "$wdir" 1
		exit 1
	fi
	if [ "$(cat "$bootimg_vendor_extract_dir/${bootimg_vendor_filename}-tags_offset")" != "0x00005000" ]; then
		echo "file $bootimg_vendor_extract_dir/${bootimg_vendor_filename}-tags_offset should be extracted with '0x00005000' content"
		cleanup "$wdir" 1
		exit 1
	fi
	if [ "$(cat "$bootimg_vendor_extract_dir/${bootimg_vendor_filename}-pagesize")" != "4096" ]; then
		echo "file $bootimg_vendor_extract_dir/${bootimg_vendor_filename}-pagesize should be extracted with '4096' content"
		cleanup "$wdir" 1
		exit 1
	fi

	echo "test_unpack_android_boot_image: pass"

	cleanup "$wdir" 0
}

test_find_dtb() {
	wdir=$(mktemp -d /tmp/boot-deploy-test.XXXXXX)
	export input_dir="$wdir/boot"

	bootimg_vendor_filename="android.img"
	bootimg_vendor="$wdir/boot/$bootimg_vendor_filename"
	export bootimg_vendor_extract_dir="${bootimg_vendor%.*}"
	mkdir -p "$bootimg_vendor_extract_dir/dt"
	# shellcheck disable=SC2034
	deviceinfo_bootimg_vendor_device_tree_identifiers="qcom,msm-id\s*=\s*<0x141\s*0x20001>; qcom,board-id\s*=\s*<0x08\s*0x0e>;"

	cat << EOF > "$wdir/dts1"
/dts-v1/;
/ {
	chosen { };
};
EOF
	cat << EOF > "$wdir/dts2"
/dts-v1/;
/ {
	qcom,msm-id = <0x141 0x20001>;
	qcom,board-id = <0x08 0x0e>;
	chosen { };
};
EOF
	dtc -I dts -O dtb -o "$bootimg_vendor_extract_dir/dt/dtbdump_1.dtb" "$wdir/dts1"
	dtc -I dts -O dtb -o "$bootimg_vendor_extract_dir/dt/dtbdump_2.dtb" "$wdir/dts2"

#	find "${bootimg_vendor_extract_dir}/dt" -name "*dtbdump*" | sed -E 's/(.*)\..*/\1/g' | xargs -I{} dtc -q -I dtb -O dts -o {}.dts {}.dtb
	find_board_dtb

	dtb_found=$(find "$input_dir" -maxdepth 1 -name "*.dtb")
	if [ -z "$dtb_found" ]; then
		echo "dtb should exist: $input_dir/*.dtb"
		cleanup "$wdir" 1
	fi
	dtc -I dtb -O dts -o "$input_dir/actual.dts" "$dtb_found"
	if ! grep -q -e "qcom,msm-id\s*=\s*<0x141\s*0x20001>;" "$input_dir/actual.dts"; then
		echo "dtb should contain pattern qcom,msm-id\s*=\s*<0x141\s*0x20001>;"
		cleanup "$wdir" 1
	fi

	echo "test_find_dtb: pass"

	cleanup "$wdir" 0
}

test_get_size_of_files
test_unpack_android_boot_image
test_find_dtb
