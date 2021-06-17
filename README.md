# bask
Build A Secure Kernel

## About
This tool can help to build a Secure Kernel, following configurations found on:
+ [kspp](http://kernsec.org/wiki/index.php/Kernel_Self_Protection_Project/Recommended_Settings)
+ [clipos](https://docs.clip-os.org/clipos/kernel.html#configuration) - [src](https://github.com/clipos/src_platform_config-linux-hardware)  
+ [kconfig-hardened](https://github.com/a13xp0p0v/kconfig-hardened-check)
+ [whonix](https://github.com/Whonix/hardened-kernel)

## Usage
Add all the base options:

    # ./bask -b

Add support for `docker` and `iptables`:

    # ./bask -a "docker iptables"

Default kernel use `/usr/src/linux`, you can use a different with `-k KERNEL`:

    # ./bask -b -k /usr/src/linux-5.6

When `bask` finish, just compile your kernel as usually.
