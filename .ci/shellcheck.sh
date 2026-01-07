#!/bin/sh -e
# Copyright 2021 Oliver Smith, Clayton Craft
# SPDX-License-Identifier: GPL-3.0-or-later
# Description: shellcheck
# https://postmarketos.org/pmb-ci

set -e
if [ "$(id -u)" = 0 ]; then
	set -x
	apk -q add shellcheck
	exec su "${TESTUSER:-build}" -c "sh -e $0"
fi

sh_files="
	./boot-deploy
	./boot-deploy-functions.sh
	./test_boot_deploy_functions.sh
	./tests/*.sh
	./.ci/*.sh
"

for file in $sh_files; do
	echo "shellcheck: $file"
	shellcheck -x "$file"
done
