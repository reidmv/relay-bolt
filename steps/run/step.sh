#!/bin/bash

#
# Commands
#

BOLT="${BOLT:-bolt}"
JQ="${JQ:-jq}"
NI="${NI:-ni}"

#
# Variables
#

WORKDIR="${WORKDIR:-/workspace}"
PROJDIR="${WORKDIR}/project"
PARAMSFILE="${WORKDIR}/params.json"
TARGETSFILE="${WORKDIR}/targets.txt"
OUTPUTFILE="${WORKDIR}/output.json"

#
# Functions
#

function main() {
  echo "Using Puppet Bolt version: $($BOLT --version)"

  ni credentials config -d "${WORKDIR}/creds"

  # Fetch and set up the project directory
  load_project

  # Configure the inventory Bolt will use to run the action
  configure_inventory

  # Set up the params.json and targets.txt files
  prepare_inputs

  # Run the bolt action
  run_bolt

  # Set the output
  ni output set --key output --value "$(cat "${OUTPUTFILE}")" --json
}

usage() {
  echo "usage: $@" >&2
  exit 1
}

function load_project() {
  local proj_type="$(ni get -p '{ .project.type }')"
  local proj_src="$(ni get -p '{ .project.source }')"
  local proj_ver="$(ni get -p '{ .project.version }')"

  # Deploy the project from its source
  case "${proj_type}" in
  git)
    git clone "${proj_src}" "${PROJDIR}"
    ;;
  tarball)
    wget "${proj_src}" -O "${WORKDIR}/project.tar.gz"
    mkdir "${PROJDIR}"
    tar -C "${PROJDIR}" -xzf "${WORKDIR}/project.tar.gz"
    ;;
  '')
    ni log fatal "spec: missing required parameter, 'project.type'"
    ;;
  *)
    ni log fatal "spec: specify 'project.type' as one of 'git' or 'tarball'; recieved '${project_type}'"
  esac

  # Pull down any modules required by the project
  pushd "${PROJDIR}"
  bolt module install --project .
  popd
}

function configure_inventory() {
  echo "configure_inventory: not implemented"
}

function prepare_inputs() {
  local bolt_defaults='/etc/puppetlabs/bolt/bolt-defaults.yaml'
  ni get | 'try .parameters // {}' > "${PARAMSFILE}"
  ni get | 'try .targets | join("\n") // empty' > "${TARGETSFILE}"

  mkdir -p /etc/puppetlabs/bolt
  touch "${bolt_defaults}"
  echo '---' > "${bolt_defaults}"
}

function run_bolt() {
  local action="$(ni get -p '{ .type }')"
  local name="$(ni get -p '{ .name }')"

  pushd "${PROJDIR}"

  bolt "${action}" run "${name}" \
    --project . \
    --params "@${PARAMSFILE}" \
    --targets "@${TARGETSFILE}" \
    --format json \
    > "${OUTPUTFILE}"

  popd
}

main
exit 0

#
# OLD STUFF
#


BOLT_DEFAULTS='{}'
declare -a BOLT_ARGS

BOLT_TYPE="$( $NI get -p '{ .type }' )"
case "${BOLT_TYPE}" in
task|plan)
  ;;
'')
  usage 'spec: specify `type`, one of "task" or "plan", the type of Bolt run to perform'
  ;;
*)
  ni log fatal "unsupported type \"${BOLT_TYPE}\"; cannot run this"
  ;;
esac

BOLT_NAME="$( $NI get -p '{ .name }' )"
[ -z "${BOLT_NAME}" ] && usage "spec: specify \`name\`, the name of the Bolt ${BOLT_TYPE} to run"

# Boltdir configuration
GIT=$(ni get -p {.git})
if [ -n "${GIT}" ]; then
  ni git clone
  NAME=$(ni get -p {.git.name})
  PROJECT_DIR="$( $NI get -p '{ .projectDir }' )"
  BOLTDIR="/workspace/${NAME}/${PROJECT_DIR}"
  BOLT_ARGS+=( "--project=${BOLTDIR}" )
fi

INSTALL_MODULES="$( $NI get -p '{ .installModules }' )"
if [[ "${INSTALL_MODULES}" == "true" ]]; then
    $BOLT module install "${BOLT_ARGS[@]}"
fi

MODULE_PATH="$( $NI get | $JQ -r 'try .modulePaths | join(":")' )"
[ -n "${MODULE_PATH}" ] && BOLT_ARGS+=( "--modulepath=${MODULE_PATH}" )

# Do not pollute our project directory with rerun info that we can't use.
BOLT_ARGS+=( --no-save-rerun )

# Running in non-interactive mode, so do not request a TTY.
BOLT_ARGS+=( --no-tty )

declare -a NI_OUTPUT_ARGS
FORMAT="$( $NI get -p '{ .format }' )"
if [ -n "${FORMAT}" ]; then
  BOLT_ARGS+=( "--format=${FORMAT}" )
else
  BOLT_ARGS+=( "--format=json" )
  NI_OUTPUT_ARGS+=( "--json" )
fi

# Parameter configuration
PARAMS="$( $NI get | jq 'try .parameters // empty' )"
[ -n "${PARAMS}" ] && BOLT_ARGS+=( "--params=${PARAMS}" )

# Transport configuration
TRANSPORT_TYPE="$( $NI get -p '{ .transport.type }' )"
[ -n "${TRANSPORT_TYPE}" ] && BOLT_ARGS+=( "--transport=${TRANSPORT_TYPE}" )

TRANSPORT_USER="$( $NI get -p '{ .transport.user }' )"
[ -n "${TRANSPORT_USER}" ] && BOLT_ARGS+=( "--user=${TRANSPORT_USER}" )

TRANSPORT_PASSWORD="$( $NI get -p '{ .transport.password }' )"
[ -n "${TRANSPORT_PASSWORD}" ] && BOLT_ARGS+=( "--password=${TRANSPORT_PASSWORD}" )

TRANSPORT_RUN_AS="$( $NI get -p '{ .transport.run_as }' )"
[ -n "${TRANSPORT_RUN_AS}" ] && BOLT_ARGS+=( "--run-as=${TRANSPORT_RUN_AS}" )

case "${TRANSPORT_TYPE}" in
ssh)
  TRANSPORT_PRIVATE_KEY="$( $NI get -p '{ .transport.privateKey }' )"
  if [ -n "${TRANSPORT_PRIVATE_KEY}" ]; then
    if [[ "${TRANSPORT_PRIVATE_KEY}" != /* ]]; then
      TRANSPORT_PRIVATE_KEY="${WORKDIR}/creds/${TRANSPORT_PRIVATE_KEY}"
    fi

    BOLT_ARGS+=( "--private-key=${TRANSPORT_PRIVATE_KEY}" )
  fi

  TRANSPORT_VERIFY_HOST="$( $NI get -p '{ .transport.verifyHost }' )"
  [[ "${TRANSPORT_VERIFY_HOST}" == "false" ]] && BOLT_ARGS+=( --no-host-key-check )

  TRANSPORT_PROXY_JUMP="$( $NI get -p '{ .transport.proxyJump }' )"
  [ -n "${TRANSPORT_PROXY_JUMP}" ] && BOLT_DEFAULTS="$( $JQ --arg value "${TRANSPORT_PROXY_JUMP}" '."inventory-config".ssh.proxyjump = $value' <<<"${BOLT_DEFAULTS}" )"
  ;;
winrm)
  TRANSPORT_USE_SSL="$( $NI get -p '{ .transport.useSSL }' )"
  [[ "${TRANSPORT_USE_SSL}" == "false" ]] && BOLT_ARGS+=( --no-ssl )

  TRANSPORT_VERIFY_HOST="$( $NI get -p '{ .transport.verifyHost }' )"
  [[ "${TRANSPORT_VERIFY_HOST}" == "false" ]] && BOLT_ARGS+=( --no-ssl-verify )
  ;;
'')
  ;;
*)
  ni log fatal "unsupported transport \"${TRANSPORT_TYPE}\" (if this transport is supported by Bolt, try adding it to your bolt.yaml file)"
  ;;
esac

# Target configuration
TARGETS="$( $NI get | $JQ -r 'try .targets | if type == "string" then . else join(",") end' )"
[ -n "${TARGETS}" ] && BOLT_ARGS+=( "--targets=${TARGETS}" )

echo "Running command: $BOLT ${BOLT_TYPE} run ${BOLT_NAME} ${BOLT_ARGS[@]}"

# Set up defaults.
mkdir -p /etc/puppetlabs/bolt
cat >/etc/puppetlabs/bolt/bolt-defaults.yaml <<<"${BOLT_DEFAULTS}"

# Run Bolt!
BOLT_OUTPUT=$($BOLT "${BOLT_TYPE}" run "${BOLT_NAME}" "${BOLT_ARGS[@]}")

# Make the step fail if the Bolt command returns non-zero exit code
if [[ $? -ne 0 ]]; then
    echo "$BOLT_OUTPUT"
    exit 1
fi

$NI output set --key output --value "$BOLT_OUTPUT" "${NI_OUTPUT_ARGS[@]}"
