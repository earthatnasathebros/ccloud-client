#!/usr/bin/env bash

DISABLE_PROMPTS=""
INSTALL_DIR=""
TOOLS_DIR="ccloud_client"
CONFIG_DIR="$HOME/.config/ccloud-client/"
CONFIG_FILE="config"
CREDENTIALS_FILE="credentials"
SCRIPTNAME="ccloud-client-install.sh"
SCRIPT_URL="https://raw.githubusercontent.com/chelios/ccloud-client/master/ccloud-client-install.sh"

usage() {
  COMMAND=${0##*/}

  echo "
$COMMAND [ --disable-prompts ] [ --install-dir DIRECTORY ] [ --alias ALIAS_NAME ] [ --url AUTH_URL]

Installs the pre-built Catalyst Cloud Openstack command line tools container by downloading the setup script
($SCRIPTNAME) into a directory of your choosing, and then runs this script to
create an alias to allow easy launching of the tools container.

-d, --disable-prompts
  Disables prompts. Prompts are always disabled when there is no controlling
  tty. Alternatively export CLOUDSDK_CORE_DISABLE_PROMPTS=1 before running
  the script.

-i, --install-dir=DIRECTORY
  Sets the installation root directory to DIRECTORY. The launcher script will be
  installed in DIRECTORY/$TOOLS_DIR. The default location is \$HOME.

-a, --alias
  The alias name to use for running openstack command via the containerised tools

-u, --url
  The authentication URL of the OpenStack Cloud that you wish to connect to.

" >&2

  exit 2
}

parseArgs() {
  # options may be followed by one colon to indicate they have a required argument
  if ! options=$(getopt -o di:u:a: -l disable-prompt,install-dir:,alias:,url: -- "$@")
  then
    # something went wrong, getopt will put out an error message for us
    usage
    exit 1
  fi

  set -- $options

  while [ $# -gt 0 ]; do
    case $1 in
      -d|--disable-prompts) DISABLE_PROMPTS=1 ;;
      # for options with required arguments, an additional shift is required
      -i|--install-dir) eval INSTALL_DIR="$2" ; shift;;
      -u|--url ) URL="$2"; shift;;
      -a|--alias ) ALIAS="$2"; shift;;
      (--) shift; break;;
      (-*) echo "$0: error - unrecognized option $1" 1>&2; usage;;
      (*) break;;
    esac
    shift
  done
}

promptWithDefault() {
  # $1 - the question being asked
  # $2 - the default answer
  # $3 - the variable to assign response to
  set -o noglob
  if [ -z $DISABLE_PROMPTS ]; then
    read -p "$1 [default=$2] " response
    if [ -z $response ]; then
      eval $3="$2"
    else
      eval $3="$response"
    fi
  else
    # INSTALL_DIR not explicitly set by user and prompts dsiabled
    # so use default
    eval $3="$2"
  fi
  set +o noglob
}

promptYN() {
  # $1 - the question being asked
  # $2 - the default answer
  # $3 - the variable to assign response to
  read -p "$1 [default=$2] " response
  if [ -z $response ]; then
    # no response use default
    eval $3="$2"
  else
    eval $3="$response"
  fi
}

checkTTY() {
  if [ ! -t 1 ]; then
    # not a terminal so disable prompts
    DISABLE_PROMPTS=1
  fi
}

fetchScript() {
  url=$1
  filename=$2

  if [ -x "$(which wget)" ] ; then
      wget -q $url -O $filename
  elif [ -x "$(which curl)" ]; then
      curl -o $filename -sfL $url
  else
      echo "Could not find curl or wget, please install one of them to continue." >&2
  fi
}

writeConfig() {
    # write out config details
    if [ ! -e ${CONFIG_DIR} ]; then
      mkdir -p ${CONFIG_DIR}
      # create empty files
      :> ${CONFIG_DIR}${CONFIG_FILE}
      :> ${CONFIG_DIR}${CREDENTIALS_FILE}
    fi

    sed -i '/${INSTALL_DIR}/d' $CONFIG_DIR/$CONFIG_FILE
    echo "install-dir = $INSTALL_DIR/$TOOLS_DIR" > $CONFIG_DIR/$CONFIG_FILE

    if [ ${ALIAS} ]; then
      sed -i '/${ALIAS}/d' $CONFIG_DIR/$CONFIG_FILE
      printf "alias = %s\n" ${ALIAS} >> $CONFIG_DIR/$CONFIG_FILE
    fi
    if [ ${URL} ]; then
      sed -i '/${URL}/d' $CONFIG_DIR/$CONFIG_FILE
      if ! echo "$URL" | grep -q "$VERSION"; then
        URL+=$VERSION
      fi
      printf "auth-url = %s\n" ${URL} >> $CONFIG_DIR/$CONFIG_FILE
    fi
    # strip single quotes from variables
    sed -i "s/'//g" $CONFIG_DIR/$CONFIG_FILE
}

install() {
  if [ -z $INSTALL_DIR ]; then
    echo "
This will install the launcher scripts in a subdirectory called $TOOLS_DIR
in the installation directory selected below,

"

    promptWithDefault "select the installation directory" "$HOME" INSTALL_DIR
  fi
  DESTDIR=${INSTALL_DIR}/${TOOLS_DIR}
  if [ -e $DESTDIR ]; then
    echo "$DESTDIR already exists!"
    promptmsg="Would you like to remove the old directory? If you say no it will be over-written."
    while true; do
      promptYN "$promptmsg" n removedir
      if [ $removedir == 'n' -o $removedir == 'N' ]; then
        break
      elif [ $removedir == 'y' -o $removedir == 'Y' ]; then
        rm -rf "$DESTDIR"
        if [ ! -e "$DESTDIR" ]; then
          break
        fi
        echo "Failed to remove $DESTDIR." >&2
        $promptmsg=""
      fi
    done
  fi
  mkdir -p "$DESTDIR" || return

  # copy script to local
  fetchScript $SCRIPT_URL $DESTDIR/$SCRIPTNAME
  chmod u+x $DESTDIR/$SCRIPTNAME || return

  # output required settings to config file, to be consumed by installer
  writeConfig

  # run the launcher setup script
  echo "Running launcher setup script..."
  echo "$DESTDIR/$SCRIPTNAME"
  $DESTDIR/$SCRIPTNAME ${INSTALL_DIR}/${TOOLS_DIR}|| return
}

#----------------------------
# Main
#----------------------------
parseArgs "$@"
checkTTY
install

