# Boot Deploy

boot-deploy is a distro-agnostic script for finalizing and deploying files
related to booting Linux on mobile devices. It's used extensively by
postmarketOS for all supported devices, but was split off into a separate
project to allow other distributions to utilize it too.

## Configuration

### deviceinfo

boot-deploy uses the "deviceinfo" format from postmarketOS, which is specified
[here on the postmarketOS
wiki.](https://wiki.postmarketos.org/wiki/Deviceinfo_reference)

The `deviceinfo` file is sourced by boot-deploy, providing configuration at
runtime.

Note: not all of the variables on the deviceinfo reference wiki page are used
by boot-deploy, some of them are used internally by postmarketOS. For an up to
date list of variables that boot-deploy can use at runtime, see the top of the
`boot-deploy-functions.sh` file.

### OS-level Customization

`boot-deploy` requires a file at `/usr/share/boot-deploy/os-customization`,
which is used to provide OS distribution customization for some aspects of
its output. This file is sourced in shell script, so it must be in
`var=value` format. It must contain the following variables (the given values
are just examples):
```
distro_name="postmarketOS"
distro_prefix="pmos"
crypttab_entry="root"
```

## Usage

```
Usage:
	./boot-deploy -i <file> -k <file> -d <path> [-o <path>] [files...]
Where:
	-i  filename of the initfs in the input directory
	-k  filename of the kernel in the input directory
	-d  path to directory containing input initfs, kernel
	-o  path to output directory {default: /boot}
	-c  path to deviceinfo {default: both /usr/share/deviceinfo/deviceinfo and /etc/deviceinfo are sourced, in that order }

		Additional files listed are copied from the input directory into the output directory as-is
```

The script implementation is found in `boot_deploy_functions.sh`, which it
looks for under `/usr/share/boot-deploy/boot_deploy_functions.sh`. The default
location can be overridden, e.g. for testing purposes, by setting the
environment variable `BOOT_DEPLOY_FUNCTIONS`.


## Contributing

Thanks for wanting to help out! See `CONTRIBUTING.md` for important information
about sending patches to add support for weird devices/bootloaders/whatever!
