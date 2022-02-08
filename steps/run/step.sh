#!/bin/bash

#
# Variables
#

HOME=${HOME:-$(getent passwd "$(id -un)" | cut -d : -f 6)}
WORKDIR="${WORKDIR:-/workspace}"
PROJDIR="${WORKDIR}/project"
PARAMSFILE="${WORKDIR}/params.json"
TARGETSFILE="${WORKDIR}/targets.txt"
OUTPUTFILE="${WORKDIR}/output.json"
INVENTORYFILE="${WORKDIR}/inventory.yaml"

#
# Functions
#

function main() {
	echo "Using Puppet Bolt version: $(bolt --version)"

	mkdir -p "${WORKDIR}"
	ni credentials config -d "${WORKDIR}/creds"

	# Fetch and set up the project directory
	load_project

	# Configure the inventory Bolt will use to run the action
	configure_inventory

	# Set up the params.json and targets.txt files
	prepare_inputs

	# Run the bolt action
	run_bolt
	local bolt_exit_code="$?"

	# Set the output
	ni output set --key output --value "$(cat "${OUTPUTFILE}")" --json
	exit "${bolt_exit_code}"
}

function fail() {
	ni log fatal "FAIL: $@"
	exit 1
}

function log() {
	ni log "${1}" "${2}"
}

function load_project() {
	local proj_type="$(ni get -p '{ .project.type }')"
	local proj_src="$(ni get -p '{ .project.source }')"
	local proj_ver="$(ni get -p '{ .project.version }')"

	# Deploy the project from its source
	case "${proj_type}" in
	tarball)
		log info 'Fetching project tarball using `wget`'
		wget "${proj_src}" -O "${WORKDIR}/project.tar.gz"
		mkdir "${PROJDIR}"
		log info 'Extracting fetched tarball'
		tar -C "${PROJDIR}" -xzf "${WORKDIR}/project.tar.gz"
		;;
	git)
		log info 'Creating SSH config file for `git clone`'
		cat > "${WORKDIR}/git-ssh-config" <<-EOF
			Host *
			    StrictHostKeyChecking no
		EOF
		local sshkey="$(ni get -p '{ .project.connection.sshKey }')"
		if [ ! -z "${sshkey}" ]; then
			log info 'Configuring use of provided SSH connection for `git clone`'
			printf %s "${sshkey}" > "${WORKDIR}/git.ssh.key"
			chmod 0600 "${WORKDIR}/git.ssh.key"
			echo "    IdentityFile ${WORKDIR}/git.ssh.key" >> "${WORKDIR}/git-ssh-config"
		fi
		cat > "${WORKDIR}/git-ssh" <<-EOF
			#!/bin/bash
			ssh -F "${WORKDIR}/git-ssh-config" "\$@"
		EOF
		chmod a+x "${WORKDIR}/git-ssh"
		log info 'Cloning project Git repository'
		GIT_SSH="${WORKDIR}/git-ssh" git clone "${proj_src}" "${PROJDIR}"
		;;
	esac

	# Pull down any modules required by the project
	pushd "${PROJDIR}"
		log info 'Installing project modules'
		bolt module install --project .
	popd
}

function configure_inventory() {
	local inventory="$(ni get | jq -r 'try .inventory // ""')"

	# If an inventory was specified, write it to a workdir inventory file
	# location. If no inventory was specified, set the inventory file variable
	# to the default project location.
	if [ ! -z "${inventory}" ]; then
		INVENTORYFILE="${WORKDIR}/inventory.yaml"
		cat > "${INVENTORYFILE}" <<-EOF
			${inventory}
		EOF
	else
		INVENTORYFILE="${PROJDIR}/inventory.yaml"
	fi
}

function prepare_inputs() {
	local bolt_defaults='/etc/puppetlabs/bolt/bolt-defaults.yaml'
	local username="$(ni get | jq -r 'try .transport.username // "root"')"
	local runas="$(ni get | jq -r 'try .transport."run-as" // "root"')"
	local sshkey="$(ni get -p '{ .transport.connection.sshKey }')"

	cat > "${WORKDIR}/transport.ssh.key" <<-EOF
		${sshkey}
	EOF

	ni get | jq -r 'try .parameters // {}' > "${PARAMSFILE}"
	ni get | jq -r 'try .targets | join("\n") // empty' > "${TARGETSFILE}"

	mkdir -p /etc/puppetlabs/bolt
	touch "${bolt_defaults}"
	cat > "${bolt_defaults}" <<-EOF
		---
		spinner: false
		save-rerun: false
		inventory-config:
		  ssh:
		    user: ${username}
		    private-key: "${WORKDIR}/transport.ssh.key"
		    host-key-check: false
		    tty: false
		    run-as: ${runas}
	EOF
}

function run_bolt() {
	local action="$(ni get -p '{ .type }')"
	local name="$(ni get -p '{ .name }')"

	pushd "${PROJDIR}"
		bolt "${action}" run "${name}" \
		  --project . \
		  --inventoryfile "${INVENTORYFILE}" \
		  --params "@${PARAMSFILE}" \
		  --targets "@${TARGETSFILE}" \
		  --format json \
		  > "${OUTPUTFILE}"
		local exit_code="$?"
	popd

	return "${exit_code}"
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
