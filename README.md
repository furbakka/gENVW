gENVW
=====

Steam/Proton wrapper and helper scripts.

INSTALL FROM RELEASE
--------------------

Download the tarball from:

https://github.com/furbakka/gENVW/releases

Then run:

tar -xzf gENVW_DEV-pre.tar.gz
cd gENVW_DEV-pre
./install.sh

This installs to:

~/.local/bin

Check it:

genvw --version
genvw proton --help


INSTALL FROM GIT
----------------

Clone the repo:

git clone https://github.com/furbakka/gENVW.git
cd gENVW
./install.sh

Update later:

cd gENVW
git pull --ff-only
./install.sh


OTHER COMMANDS
--------------

Preview install:

./install.sh --dry-run

Uninstall:

./install.sh --uninstall

System-wide install:

sudo ./install.sh --system


FILES
-----

These files are installed together:

genvw
genvw.sh
genvw_proton.sh
genvw_fsr4_policy.sh

Keep them in the same directory. The shim and helper scripts expect the sibling files to be next to them.


LICENSE
-------

See LICENSE.
