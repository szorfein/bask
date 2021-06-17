#!/usr/bin/env sh

set -o errexit -o nounset

# Load functions
DIR=$(pwd)
FUNCS="$DIR"/src/functions
. "${FUNCS}"

FEATS="$DIR"/kernel
BASE=false
AUTO_SEARCH=false
KERNEL=/usr/src/linux
POLICY="default"
MOD="/proc/modules"

# colors
red=$'\e[0;91m'
magenta=$'\e[0;95m'
cyan=$'\e[0;96m'
white=$'\e[0;97m'
endc=$'\e[0m'

# update config after apply a rule
upd_conf() {
  printf "\n$magenta%s$white%s$endc\n" " ===>" " Update kernel config..."
  if [ "$POLICY" = "default" ] ; then
    make olddefconfig >/dev/null || die "update conf failed"
  fi
  # To debug, when see a warning, we can apply:
  #make oldconfig
}

# Return the regex for the sed command from apply_rule()
ret_rule() {
  s=$1
  clean=${s%%=*}
  q=${s#*=}
  if_comma=$(echo "$s" | sed "s:,: :g")
  # First try to find for example CONFIG_CMDLINE=
  old="$(grep -ie "$clean=" "$SOURCE_CONF" | head -1)"
  # If fail, grab the full line, ex: # CONFIG_CMDLINE_BOOL is not set
  [ -z "$old" ] && old="$(grep -ie "$clean is not set$" "$SOURCE_CONF" | head -1)"
  # And if nothing is found, exit
  [ -z "$old" ] && return
  if [ "$q" = "n" ]; then
    rule="s:${old}:${clean}=n:g"
  elif [ "$q" = "y" ] ; then
    rule="s:${old}:${clean}=y:g"
  elif [ "$q" = "m" ] ; then
    rule="s:${old}:${clean}=m:g"
  else
    rule="s:${old}:${if_comma}:g"
  fi
  echo "$rule"
}

apply_rules() {
  s="$1"
  rule=$(ret_rule "$s")
  [ -z "$rule" ] && die "rule void - $s"
  sed -i "$rule" "$SOURCE_CONF" || die "sed $rule on $s"
  printf "${cyan}%s${white}%s${endc}" \
    "[OK]" " new rule apply $rule"
  if [ "$q" = "y" ] || [ "$q" = "m" ] ; then
    upd_conf
  else
    echo
  fi
}

check_option() {
  s="$1"
  clean=${s%%=*}
  q=${s#*=}
  if grep -q "$1" "$SOURCE_CONF" ; then
    printf "${cyan}%s${white}%s${endc}\n" "[OK]" " $1"
  elif [ "$q" = "n" ] && grep -qi "^# $clean is not set" "$SOURCE_CONF" ; then
    printf "${cyan}%s${white}%s${endc}\n" "[OK]" " $1"
  elif ! grep -qi "$clean[^_]" "$SOURCE_CONF" ; then
    printf "${red}%s${endc}\n" "Option $clean no found..."
  else
    apply_rules "$1"
  fi
}

apply_conf() {
  [ -f "$1" ] || die "apply_conf <$1> no found."
  for config in $(grep -ie "^config" $1) ; do
    check_option "$config"
  done
}

for_intel() {
  if cat /proc/cpuinfo | grep -qi intel ; then
    log "Add intel features." 
    apply_conf "$FEATS"/cpu/intel.txt
  fi
}

for_X86_64() {
  if grep "^CONFIG_X86_64=y" "$SOURCE_CONF" ; then
    log "Add content for x86_64"
    apply_conf "$FEATS"/cpu/x86_64.txt
  fi
}

uefi() {
  apply_conf "$FEATS"/auto/gpt.txt
  if [ -d /sys/firmware/efi/efivars ] ; then
    log "Add content for UEFI"
    apply_conf "$FEATS"/auto/uefi.txt
  fi
}

apply_base() {
  apply_conf "$FEATS"/auto/init.txt
  log "Apply base settings."
  apply_conf "$FEATS"/auto/base.txt
  apply_conf "$FEATS"/net/basic.txt
  POLICY="no"
  apply_conf "$FEATS"/auto/blacklist.txt
  apply_conf "$FEATS"/auto/kconfig.txt
  POLICY="default"
  apply_conf "$FEATS"/net/netfilter.txt
  apply_conf "$FEATS"/net/netfilter_gw.txt
  apply_conf "$FEATS"/security/basic.txt
  apply_conf "$FEATS"/auto/kspp.txt
  apply_conf "$FEATS"/auto/graphics.txt
  apply_conf "$FEATS"/boards.txt
  apply_conf "$FEATS"/debug.txt
  for_X86_64
  for_intel
  uefi
}

# Add kernel boot params to grub2
applyGrubCmdArgs() {
  grub_conf=/etc/default/grub
  line=$(grep -iE "^GRUB_CMDLINE_LINUX=" $grub_conf)
  only_args="${line#*=}"

  [ -f "$grub_conf" ] || die "$grub_conf no found"

  if [ -z "$line" ] ; then
    die "Option GRUB_CMDLINE_LINUX no found in $grub_conf"
  fi

  log "Check kernel boot params..."
  for opt in $(grep -ie "^[a-z]" "$FEATS"/grub.txt) ; do
    if is_here=$(echo "$line" | grep -i "$opt") ; then
      log "Option lacked, apply additional value '$opt'"
      only_args="$only_args $opt"
    fi
  done

  only_args="GRUB_CMDLINE_LINUX=\"$(echo "$only_args" | sed "s:\"::g")\""
  log "Your line cmdline is $only_args"

  sed -i "s:$line:$only_args:g" "$grub_conf"
}

forTheEnd() {
  log "File(s) $FILE has been applying"
  echo "You should probably in order: "
  printf "\n[re]compile your kernel source:"
  echo "ex -> make && make modules_install && make install"
  printf "\n[re]install your modules if gentoo:"
  echo "ex -> emerge --ask @module-rebuild"
  printf "\n[re]make your initramfs"

  printf "\n[re]do a grub.conf:"
  echo "ex -> grub-mkconfig -o /boot/grub/grub.cfg"
}

#########################################################
# Command line parser

usage() {
  echo "Usage:"
  printf "%s [-a \"value1 value2 value3\"] [-k kernel_source_dir]\\n" $0
  printf "%s -s, search module in /proc/modules and apply the matching file automatically\\n" $0
  echo 
  exit 0
}

while getopts ":a:k:sbvh" args ; do
  case "$args" in
    a ) FILE="$OPTARG" ;;
    b ) BASE=true ;;
    k ) KERNEL="$OPTARG" ;;
    s ) AUTO_SEARCH=true ;;
    v | h ) usage 1 ;;
    \? ) usage 2 ;;
  esac
done
shift $(( $OPTIND - 1 ))

# Check arg
check_txt() {
  for f in ${FILE:-} ; do
    [ -f "$FEATS"/"$f".txt ] || die "Config $f.txt not yet available in $FEATS"
  done
}

check_kern() {
  if ! [ -s "$KERNEL" ] || ! [ -d "$KERNEL" ] ; then
    die "Link or Dir $KERNEL no found ..."
  fi
}

function check_mod {
  if ! tmp=$(grep "^$1" "$MOD") ; then
    return 1
  else
    _1=$(echo "$tmp" | awk '{print $1}')
    _3=$(echo "$tmp" | awk '{print $3}')
    _4=$(echo "$tmp" | awk '{print $4}')
    second=${2:-false}
    if [ "$second," == "$_4" ] ; then
      #echo "With second arg, $2 - $_2"
      return 0
    else
      if [ "$_3" -ge 1 ] ; then
      #echo "$_1 , $_2"
          return 0
      else
          return 1
      fi
    fi
  fi
}

function add_support {
  echo "[+] Adding $1"
  apply_conf "$FEATS"/"$1".txt
}

# Detect more things on a distro like Archlinux.
function auto_search {
#	check_mod "radeon" && add_support "radeon"
#	check_mod "nouveau" && add_support "nouveau"
#	check_mod "mdio_devres" "r8169" && add_support "r8169"
#	check_mod "mei_txe" && add_support "mei_txe"
#	check_mod "kvm" "kvm_intel" && add_support "kvm intel"

  check_mod "i915" && add_support "drivers/gpu/i915"
  check_mod "amdgpu" && add_support "drivers/gpu/amdgpu"
	check_mod "pwm_lpss" "pwm_lpss_platform," && add_support "drivers/pwm_lpss"
	check_mod "iwlwifi" "iwlmvm" && add_support "drivers/net/wireless/iwlmvm"
	check_mod "xhci_pci_renesas" "xhci_pci" && add_support "drivers/usb/xhci_pci_renesas"
	check_mod "xhci_hcd" "xhci_pci" && add_support "drivers/usb/xhci_hcd"
	check_mod "rtsx_pci" "rtsx_pci_sdmmc" && add_support "drivers/misc/rtsx_pci_sdmmc"
	check_mod "intel_spi" "intel_spi_platform" && add_support "drivers/mtd/intel_spi"
	check_mod "snd_hda_intel" && add_support "sound/hda_intel"
	check_mod "snd_usb_audio" && add_support "sound/usb_audio"
}

SOURCE_CONF="$KERNEL/.config"

main() {
  check_root
  check_kern
  check_txt

  log "Patching kernel source located at $KERNEL"
  backup_file "$KERNEL/.config"
  cd "$KERNEL" || die "$KERNEL no found"

  # Check if .config exist or generate a new
  if ! [ -f "$SOURCE_CONF" ] ; then 
    log "Generate a base .config file"
    make defconfig >/dev/null || die "make defconfig not available."
  fi

  "$BASE" && apply_base

  # Kernel options to check
  for f in ${FILE:-} ; do
    log "Applying $f"
    apply_conf "$FEATS"/"$f".txt
    if [ "$f" = "grub" ] ; then
      applyGrubCmdArgs
    fi
  done

  "$AUTO_SEARCH" && auto_search

  exit 0
}

main "$@"
