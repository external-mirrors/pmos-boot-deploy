## Installing files into the output directory

Functions should not install files directly into the output directory (e.g.
using `copy`.) Instead, paths to files in the work directory should be appended
to `$additional_files`.

If functions call `copy` on their own, it's possible that `boot-deploy` might
fail at a later point, leaving potentially broken cruft in the output
directory. For example, the output directory may run out of free space later,
or some other runtime failure may occur. By adding files to
`$additional_files`, everything will be copied at the end of the program, and
the free space check will be more reliable.

## Variable naming

Global variables should be named with lower casing, beginning with a letter.
The use of underscores, e.g. to separate words in a variable name, is allowed.
An example of a global variable name is: **output_dir**.

`boot-deploy` is implemented in POSIX sh, **except** for the use of the
**local** keyword to give variables local scoping where appropriate. **local**
should be used at all times when declaring variables that should only exist
within a function. Function variable names should also begin with a single
underscore, in order to not conflict with any global variables. An example of a
function variable name is: **_uboot_image_files**.

## Testing

Contributions should pass `.ci/run.sh` without errors/warnings.
