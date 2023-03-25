#!/bin/sh

set -eu

echo "##### Running EditorConfig Check #####"
./.ci/ec.sh
echo "##### Running Shellcheck #####"
./.ci/shellcheck.sh
echo "##### Running Tests #####"
./test_boot_deploy_functions.sh
