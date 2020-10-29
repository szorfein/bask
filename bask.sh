#!/usr/bin/env sh

set -o errexit -o nounset

# Load functions
DIR=$(pwd)
FUNCS="$DIR"/src/functions
. "${FUNCS}"

FEATS="$DIR"/kernel
BASE=false
KERNEL=/usr/src/linux
POLICY="default"

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
    apply_conf "$FEATS"/auto/intel.txt
  fi
}

for_X86_64() {
  if grep "^CONFIG_X86_64=y" "$SOURCE_CONF" ; then
    log "Add content for x86_64"
    apply_conf "$FEATS"/auto/x86_64.txt
  fi
}

uefi() {
  apply_conf "$FEATS"/auto/gpt.txt
  [ -d /sys/firmware/efi/efivars ] && {
    log "Add content for UEFI"
    apply_conf "$FEATS"/auto/uefi.txt
  }
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
  apply_conf "$FEATS"/auto/netfilter.txt
  apply_conf "$FEATS"/auto/secs.txt
  apply_conf "$FEATS"/auto/kspp.txt
  apply_conf "$FEATS"/auto/graphics.txt
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
  printf "Usage: %s [-a \"value1 value2 value3\"] [-k kernel_source_dir]\\n" $0
  exit 0
}

while getopts ":a:k:bvh" args ; do
  case "$args" in
    a ) FILE="$OPTARG" ;;
    b ) BASE=true ;;
    k ) KERNEL="$OPTARG" ;;
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

SOURCE_CONF="$KERNEL/.config"
BACKUP_FILES+=" $SOURCE_CONF"

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

  exit 0
}

main "$@"
