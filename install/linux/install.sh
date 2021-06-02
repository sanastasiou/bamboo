#!/usr/bin/env bash
# shellcheck disable=SC1090

# cypher bamboo
# (c) 2021 Tangram
#
# Install with this command (from your Linux machine):
#
# bash <(curl -sSL https://raw.githubusercontent.com/cypher-network/bamboo/master/install/linux/install.sh)

# -e option instructs bash to immediately exit if any command [1] has a non-zero exit status
# We do not want users to end up with a partially working install, so we exit the script
# instead of continuing the installation with something broken
set -e

while test $# -gt 0
do
    case "$1" in
        --help)
          echo "  Install script arguments:"
          echo
          echo "    --uninstall                   : uninstall node"
          echo
          exit 0
          ;;
        --uninstall)
            IS_UNINSTALL=true
            ;;
        --*) echo "bad option $1"
            exit 1
            ;;
    esac
    shift
done


######## VARIABLES #########
# For better maintainability, we store as much information that can change in variables
# This allows us to make a change in one place that can propagate to all instances of the variable
# These variables should all be GLOBAL variables, written in CAPS
# Local variables will be in lowercase and will exist only within functions
# It's still a work in progress, so you may see some variance in this guideline until it is complete
DISTRO=$(grep '^ID=' /etc/os-release | cut -d '=' -f 2)
DISTRO_VERSION=$(grep '^VERSION_ID=' /etc/os-release | cut -d '=' -f 2 | tr -d '"')
ARCHITECTURE=$(uname -m)

ARCHITECTURE_ARM=("armv7l")
ARCHITECTURE_ARM64=("aarch64")
ARCHITECTURE_X64=("x86_64")

if [[ " ${ARCHITECTURE_ARM[@]} " =~ " ${ARCHITECTURE} " ]]; then
  ARCHITECTURE_UNIFIED="arm"
  ARCHITECTURE_DEB="armhf"

elif [[ " ${ARCHITECTURE_ARM64[@]} " =~ " ${ARCHITECTURE} " ]]; then
  ARCHITECTURE_UNIFIED="arm64"
  ARCHITECTURE_DEB="arm64"

elif [[ " ${ARCHITECTURE_X64[@]} " =~ " ${ARCHITECTURE} " ]]; then
  ARCHITECTURE_UNIFIED="x64"
  ARCHITECTURE_DEB="amd64"
else
  # Fall back to x64 architecture
  ARCHITECTURE_UNIFIED="x64"
  ARCHITECTURE_DEB="amd64"
fi


CYPHER_BAMBOO_VERSION=$(curl --silent "https://api.github.com/repos/cypher-network/bamboo/releases/latest" | grep -Po '"tag_name": "\K.*?(?=")')
CYPHER_BAMBOO_VERSION_SHORT=$(echo "${CYPHER_BAMBOO_VERSION}" | cut -c 2-)
CYPHER_BAMBOO_ARTIFACT_PREFIX="cypher-bamboo_${CYPHER_BAMBOO_VERSION_SHORT}_"
CYPHER_BAMBOO_URL_PREFIX="https://github.com/cypher-network/bamboo/releases/download/${CYPHER_BAMBOO_VERSION}/"

CYPHER_BAMBOO_OPT_PATH="/opt/cypher/bamboo/"
CYPHER_BAMBOO_TMP_PATH="/tmp/opt/cypher/bamboo/"


if [ -f /etc/debian_version ]; then
  IS_DEBIAN_BASED=true
else
  IS_DEBIAN_BASED=false
fi

INIT=$(ps --no-headers -o comm 1)


# Check if we are running on a real terminal and find the rows and columns
# If there is no real terminal, we will default to 80x24
if [ -t 0 ] ; then
  screen_size=$(stty size)
else
  screen_size="24 80"
fi
# Set rows variable to contain first number
printf -v rows '%d' "${screen_size%% *}"
# Set columns variable to contain second number
printf -v columns '%d' "${screen_size##* }"


# Divide by two so the dialogs take up half of the screen, which looks nice.
r=$(( rows / 2 ))
c=$(( columns / 2 ))
# Unless the screen is tiny
r=$(( r < 20 ? 20 : r ))
c=$(( c < 70 ? 70 : c ))


# Set these values so the installer can still run in color
COL_NC='\e[0m' # No Color
COL_LIGHT_GREEN='\e[1;32m'
COL_LIGHT_RED='\e[1;31m'
TICK="[${COL_LIGHT_GREEN}✓${COL_NC}]"
CROSS="[${COL_LIGHT_RED}✗${COL_NC}]"
INFO="[i]"
# shellcheck disable=SC2034
DONE="${COL_LIGHT_GREEN} done!${COL_NC}"
OVER="\\r\\033[K"


is_command() {
  # Checks for existence of string passed in as only function argument.
  # Exit value of 0 when exists, 1 if not exists. Value is the result
  # of the `command` shell built-in call.
  local check_command="$1"

  command -v "${check_command}" >/dev/null 2>&1
}


install_info() {
  ARCHIVE="${CYPHER_BAMBOO_ARTIFACT_PREFIX}linux-${ARCHITECTURE_UNIFIED}.tar.gz"
  printf "\n  %b Using installation archive %s\n" "${TICK}" "${ARCHIVE}"
}


download_archive() {
  printf "\n"
  printf "  %b Checking download utility\n" "${INFO}"
  if is_command curl; then
    printf "  %b curl\n" "${TICK}"
    HAS_CURL=true
  else
    printf "  %b curl\n" "${CROSS}"
    HAS_CURL=false
  fi
  
  if [ ! "${HAS_CURL}" = true ]; then
    if is_command wget; then
      printf "  %b wget\n" "${TICK}"
    else
      printf "  %b wget\n" "${CROSS}"
      printf "\n"
      printf "      Could not find a utility to download the archive. Please install either curl or wget.\n\n"
      return 1
    fi
  fi
  
  printf "\n";
  printf "  %b Checking archive %s" "${INFO}" "${ARCHIVE}"
  if [ "${HAS_CURL}" = true ]; then
    if curl --silent --fail "${DOWNLOAD_URL}"; then
      printf " %b  %b Archive %s found\n\n" "${OVER}" "${TICK}" "${ARCHIVE}"
    else
      printf " %b  %b Archive %s cannot be found\n\n" "${OVER}" "${CROSS}" "${ARCHIVE}"
      exit 1
    fi
  else
    if wget -q "${DOWNLOAD_URL}"; then
      printf " %b  %b Archive %s found\n\n" "${OVER}" "${TICK}" "${ARCHIVE}"
    else
      printf " %b  %b Archive %s cannot be found\n\n" "${OVER}" "${CROSS}" "${ARCHIVE}"
      exit 1
    fi
  fi

  printf "  %b Downloading archive %s" "${INFO}" "${ARCHIVE}"

  DOWNLOAD_PATH="/tmp/cypher-bamboo/"
  DOWNLOAD_FILE="${DOWNLOAD_PATH}${ARCHIVE}"
  DOWNLOAD_URL="${CYPHER_BAMBOO_URL_PREFIX}${ARCHIVE}"
  
  if [ "${HAS_CURL}" = true ]; then
    curl -s -L --create-dirs -o "${DOWNLOAD_FILE}" "${DOWNLOAD_URL}"
  else
    mkdir -p "${DOWNLOAD_PATH}" 
    wget -q -O "${DOWNLOAD_FILE}" "${DOWNLOAD_URL}"
  fi

  printf "%b  %b Downloaded archive %s\n" "${OVER}" "${TICK}" "${ARCHIVE}"
}


install_archive() {
  printf "  %b Unpacking archive to %s" "${INFO}" "${CYPHER_BAMBOO_TMP_PATH}"
  mkdir -p "${CYPHER_BAMBOO_TMP_PATH}"
  tar --overwrite -xf "${DOWNLOAD_FILE}" -C "${CYPHER_BAMBOO_TMP_PATH}"
  printf "%b  %b Unpacked archive to %s\n" "${OVER}" "${TICK}" "${CYPHER_BAMBOO_TMP_PATH}"
    
  printf "  %b Installing to %s" "${INFO}" "${CYPHER_BAMBOO_OPT_PATH}"
  sudo mkdir -p "${CYPHER_BAMBOO_OPT_PATH}"
  sudo cp -r "${CYPHER_BAMBOO_TMP_PATH}"* "${CYPHER_BAMBOO_OPT_PATH}"
  sudo chmod 755 -R "${CYPHER_BAMBOO_OPT_PATH}"
  sudo chown -R $USER:$USER "${CYPHER_BAMBOO_OPT_PATH}"
  printf "%b  %b Installed to %s\n" "${OVER}" "${TICK}" "${CYPHER_BAMBOO_OPT_PATH}"   
}


cleanup() {
  printf "\n"
  printf "  %b Cleaning up files" "${INFO}"
  rm -rf "${DOWNLOAD_PATH}"
  sudo rm -rf "${CYPHER_BAMBOO_TMP_PATH}"
  printf "%b  %b Cleaned up files\n" "${OVER}" "${TICK}"
}

finish() {
  printf "\n\n  %b Installation succesful\n\n" "${DONE}"
}


if [ "${IS_UNINSTALL}" = true ]; then
  printf "  %b Uninstalling\n\n" "${INFO}"

  sudo rm -rf "${CYPHER_CYPNODE_OPT_PATH}"
  
  printf "\n\n  %b Uninstall succesful\n\n" "${DONE}"

else
  install_info

  download_archive
  install_archive

  cleanup
  finish
fi
