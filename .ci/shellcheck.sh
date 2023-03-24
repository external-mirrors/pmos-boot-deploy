#!/bin/sh -e
# Copyright 2021 Oliver Smith, Clayton Craft
# SPDX-License-Identifier: GPL-3.0-or-later

set -e
DIR="$(cd "$(dirname "$0")" && pwd -P)"
cd "$DIR/.."

# Shell: shellcheck
sh_files="
	./boot-deploy
	./boot-deploy-functions.sh
	./test_boot_deploy_functions.sh
"

for file in $sh_files; do
	echo "Test with shellcheck: $file"
	cd "$DIR/../$(dirname "$file")"
	shellcheck -e SC1008 -e SC3043 -x "$(basename "$file")"
done
