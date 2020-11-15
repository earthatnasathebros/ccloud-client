#!/usr/bin/env bash

# Copyright (c) 2018 Catalyst.net Ltd
# This program is free software: you can redistribute it and/or modify
# it under the terms of the Apache License Version 2.0, January 2004.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# Apache License Version 2.0
#
# You should have received a copy of the Apache License Version 2.0
# along with this program.  If not, see http://www.apache.org/licenses/
#

#------------------------------------------------------------------------------
# Parameters
#-----------------------------------------------------------------------------
INSTALL_DIR="$1"
CONFIG_FILE="$HOME/.config/ccloud-client/config"
CCLOUD_LAUNCHER="ccloud-client"
CCLOUD_INSTALLER="ccloud-client-install.sh"
ALIAS_NAME="ccloud"
NEWPATH=
DOCKERLINK="https://docs.docker.com/engine/install/"

DEBUG=
# colour data for message prompt
GREEN="\e[92m" # for success output
YELLOW="\e[93m" # for debug output
RED="\e[91m" # for error output
NC='\033[0m' # remove colour from output

#------------------------------------------------------------------------------
# Functions
#------------------------------------------------------------------------------
usage() {
  cat <<USAGE_DOC
  Usage: $(basename $0)
  This is a wrapper script to install the ccloud client
USAGE_DOC
  exit 0
}

check_docker_exists(){
  docker -v &> /dev/null
  if [ $? -ne 0 ]; then
    MSG="docker is not installed!"
    echo -e  "${RED}${MSG}${NC} \n" 2>&1
    echo "
      Please check out the following link to install docker: ${DOCKERLINK}

      once installed re-run ${INSTALL_DIR}/${CCLOUD_INSTALLER}
    "
    exit 1
  fi
}

get_config() {
  if [ -e $CONFIG_FILE ];  then
    INSTALL_DIR=$(grep install-dir $CONFIG_FILE|awk -F "=" '{ print $2 }'| sed -e 's/^[[:space:]]//')
    ALIAS=$(grep alias $CONFIG_FILE|awk -F "=" '{ print $2 }'| sed -e 's/^[[:space:]]//')
  else
    # no config file found re-run fetch-installer.sh
    echo "The config file $CONFIG_FILE could not be found, please re-run the installer"
  fi
  if [ ${ALIAS} ]; then
    ALIAS_NAME=${ALIAS}
  fi
}

create_os_launcher(){
  if [ ! -d ${INSTALL_DIR} ]; then
    mkdir ${INSTALL_DIR}
  else
    if [ ${DEBUG} ]; then
      MSG="${INSTALL_DIR} already exists, skipping..."
      echo -e  "${YELLOW}${MSG}${NC}"
    fi
  fi

cat << 'EOF' > ${INSTALL_DIR}/${CCLOUD_LAUNCHER}
#!/usr/bin/env bash

#------------------------------------------------------------------------------
# Parameters
#------------------------------------------------------------------------------

CONFIG_FILE="$HOME/.config/ccloud-client/config"
OPENRCFILE="False"
LOCALENV="False"
MODE="interactive"
FILEPATH='.openrc'
FILEREGEX='*-openrc.sh'

EXTRAARGS=''
DOCKER_TAG=''
DOCKERIMAGE="catalystcloud/ccloud-client_container"

OS_IDENTITY_API_VERSION="3"
OS_AUTH_URL=''

#------------------------------------------------------------------------------
# Functions
#------------------------------------------------------------------------------

# If ALIAS is run with -s as the only parameter will drop the user into a
# bash shell

parse_args(){
  while getopts sv: OPTION; do
    case "$OPTION" in
      s)
        MODE="shell"
        ;;
      v)
        # get the required docker container version if passed
        DOCKER_TAG="$OPTARG"
        ;;
      ?)
        cat <<USAGE_DOC
Usage: $(basename $0) [-s] [-v <version>]
   -s   drops into bash shell rather than interactive openstackclient tool
   -v   the container tag version to update to
USAGE_DOC
        exit 1 ;;
    esac
  done

  if [ "${MODE}" == "shell" ]; then
    EXTRAARGS='--entrypoint=/bin/bash'
  fi
}

handle_interruptions() {
  exit 130
}

# Look for $OS_* environment variables. If not defined, look for openrc files
# under /${HOME}/${FILEPATH}. The precendence is set by this function.

get_credentials() {
  # for the osc container, you need at minimum: OS_AUTH_URL, OS_USERNAME,
  # OS_IDENTITY_API_VERSION, and OS_PASSWORD/OS_TOKEN if not asking for it interactively.

  if [[ ${OS_PROJECT_ID} && ${OS_TOKEN} ]] || [[ ${OS_USERNAME} && ${OS_PASSWORD} && ${OS_PROJECT_ID} ]]; then
    LOCALENV="True"
  # Search for OpenStack openrc files
  elif find "${HOME}/${FILEPATH}" -name "${FILEREGEX}" 2>/dev/null ; then
    OPENRCFILE="True"
  fi
}

create_menu () {
  arrsize=$1
  PS3="Select the ${MENU_PROMPT} you require or type 'q' to quit: "
  select option in "${@:2}"; do
    if [ "$REPLY" == "q" ] || [ "$REPLY" == "Q" ] ; then
      echo "Exiting..."
      break;
    elif [ 1 -le "$REPLY" ] && [ "$REPLY" -le $((arrsize)) ]; then
      echo "You have selected :  $option"
      break;
    else
      echo "Incorrect Input: Select a number 1-$arrsize"
    fi
  done
}

get_config() {
  if [ -e $CONFIG_FILE ];  then
    AUTH_URL=$(grep auth-url $CONFIG_FILE|awk -F "=" '{ print $2 }'| sed -e 's/^[[:space:]]//')
  else
    # no config file found re-run fetch-installer.sh
    echo "The config file $CONFIG_FILE could not be found, please re-run the installer"
  fi
  if [ ${AUTH_URL} ]; then
    OS_AUTH_URL=${AUTH_URL}
  fi
}

run_container(){

  # check if cloud tools docker image exists, if not pull latest. If a tag is
  # provided for a specific image version then pull that version

  if [ -z  ${DOCKER_TAG} ]; then
    IMAGEID=$(docker images --filter "reference=${DOCKERIMAGE}:latest" --format "{{.ID}}")
  else
    IMAGEID=$(docker images --filter "reference=${DOCKERIMAGE}:${DOCEKR_TAG}" --format "{{.ID}}")
  fi

  if [ ! ${IMAGEID} ]; then
    docker pull ${DOCKERIMAGE}:latest
  elif [ ${DOCKER_TAG} ]; then
    docker pull ${DOCKERIMAGE}:${DOCKER_TAG}
  fi

  if [ $? -ne 0 ]; then
    echo "Unable to retrieve ${DOCKERIMAGE}"
    exit 1
  fi

  if [ "${OPENRCFILE}" == "True" ]; then
    # if local openrc file/s found in $HOME/.openrc use them
    docker run -it --rm \
    --security-opt=no-new-privileges \
    --cap-drop SETUID \
    -a stdin -a stdout -a stderr \
    --user=$(id -u) \
    -v /etc/passwd:/etc/passwd:ro \
    -v /etc/group:/etc/group:ro \
    -v ${HOME}:/mnt \
    -w /mnt \
    --env "OPENRCFILE=True" \
    --hostname osclient-container ${EXTRAARGS} ${DOCKERIMAGE} ${*}
  elif [ "${LOCALENV}" == "True" ]; then
    # if current shell has valid OS_* env variables set use them
    docker run -it --rm \
    --security-opt=no-new-privileges \
    --cap-drop SETUID \
    -a stdin -a stdout -a stderr \
    --user=$(id -u) \
    -v /etc/passwd:/etc/passwd:ro \
    -v /etc/group:/etc/group:ro \
    -v ${HOME}:/mnt \
    -w /mnt \
    --env "OS_TOKEN=${OS_TOKEN}" \
    --env "OS_USERNAME=${OS_USERNAME}" \
    --env "OS_PASSWORD=${OS_PASSWORD}" \
    --env "OS_AUTH_URL=${OS_AUTH_URL}" \
    --env "OS_AUTH_TYPE=${OS_AUTH_TYPE}" \
    --env "OS_REGION_NAME=${OS_REGION_NAME}" \
    --env "OS_PROJECT_ID=${OS_PROJECT_ID}" \
    --env "OS_IDENTITY_API_VERSION=${OS_IDENTITY_API_VERSION}" \
    --env "LOCALENV=True" \
    --hostname osclient-container ${EXTRAARGS} ${DOCKERIMAGE} ${*}
  else
    # default to interactive login
    docker run -it --rm \
    --security-opt=no-new-privileges \
    --cap-drop SETUID \
    -a stdin -a stdout -a stderr \
    --user=$(id -u) \
    -v /etc/passwd:/etc/passwd:ro \
    -v /etc/group:/etc/group:ro \
    -v ${HOME}:/mnt \
    -w /mnt \
    --env "OS_AUTH_URL=${OS_AUTH_URL}" \
    --hostname osclient-container ${EXTRAARGS} ${DOCKERIMAGE} ${*}
  fi
}

#------------------------------------------------------------------------------
# Main
#------------------------------------------------------------------------------

# Handle ctrl-c (SIGINT)
trap handle_interruptions INT

parse_args "$@"
get_credentials
get_config

run_container ${*}

EOF

chmod u+x ${INSTALL_DIR}/${CCLOUD_LAUNCHER}
}


create_alias(){
  ALIAS="alias ${ALIAS_NAME}='${INSTALL_DIR}/${CCLOUD_LAUNCHER}'"

  if [ -e ${HOME}/.bashrc ]; then
    if [ ${DEBUG} ]; then
      MSG="updating alias entry in .bashrc"
      echo -e  "${YELLOW}${MSG}${NC}"
    fi
    sed -i "/${ALIAS_NAME}/d" ${HOME}/.bashrc
    # make sure to append so as to not clobber existing alias entries
    echo "${ALIAS}" >> "${HOME}"/.bashrc
  else
    if [ ${DEBUG} ]; then
      MSG="creating alias entry in .bashrc"
      echo -e  "${YELLOW}${MSG}${NC}"
    fi
    echo ${ALIAS} > ${HOME}/.bashrc
  fi
}


update_path(){
  # if ${INSTALL_DIR} not in ${PATH} update path in .bashrc
  if [[ ! ${PATH} =~ ${INSTALL_DIR} ]]; then
    if [ ${DEBUG} ]; then
      MSG="adding ${INSTALL_DIR} to \$PATH"
      echo -e  "${YELLOW}${MSG}${NC}"
    fi
    NEWPATH=${INSTALL_DIR}:${PATH}
  fi

    MSG="
    The alias '${ALIAS}' was added to your .bashrc file.
    "
    echo -e  "${NC}${MSG}"

    MSG="
    Please run
      source ${HOME}/.bashrc
    to make ${ALIAS_NAME} available from the command line.
    "
    echo -e  "${GREEN}${MSG}${NC}"

}

#------------------------------------------------------------------------------
# Main
#------------------------------------------------------------------------------

check_docker_exists
get_config
create_os_launcher
create_alias
update_path
