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
	load-project

	# Configure the inventory Bolt will use to run the action
	configure-inventory

	# Set up the params.json and targets.txt files
	prepare-inputs

	# TODO: provide and handle additional bolt configuration options input
	#       parameter

	# Run the bolt action
	execute-action
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

function load-project() {
	log info '### Loading project...'
	local proj_type="$(ni get -p '{ .project.type }')"
	local proj_src="$(ni get -p '{ .project.source }')"
	local proj_ver="$(ni get -p '{ .project.version }')"

	# Deploy the project from its source
	case "${proj_type}" in
	tarball)
		log info '#### project type: tarball...'
		log info 'Fetching project tarball using `wget`'
		wget "${proj_src}" -O "${WORKDIR}/project.tar.gz"
		mkdir "${PROJDIR}"
		log info 'Extracting fetched tarball'
		tar -C "${PROJDIR}" -xzf "${WORKDIR}/project.tar.gz"
		;;
	git)
		log info '#### project type: git...'
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
		log info '### Installing project modules...'
		bolt module install --project .
	popd
}

function configure-inventory() {
	local inventory="$(ni get | jq -r 'try .inventory // ""')"

	# If an inventory was specified, write it to a workdir inventory file
	# location. If no inventory was specified, set the inventory file variable
	# to the default project location.
	if [ ! -z "${inventory}" ]; then
		log info '### Configuring inventory...'
		INVENTORYFILE="${WORKDIR}/inventory.yaml"
		cat > "${INVENTORYFILE}" <<-EOF
			${inventory}
		EOF
	else
		INVENTORYFILE="${PROJDIR}/inventory.yaml"
		log info "### No inventory specified; using project:inventory.yaml..."
	fi
}

function prepare-inputs() {
	local bolt_defaults='/etc/puppetlabs/bolt/bolt-defaults.yaml'
	local username="$(ni get | jq -r 'try .transport.username // "root"')"
	local runas="$(ni get | jq -r 'try .transport."run-as" // "root"')"
	local sshkey="$(ni get -p '{ .transport.connection.sshKey }')"

	log info '### Configuring default transport...'
	cat > "${WORKDIR}/transport.ssh.key" <<-EOF
		${sshkey}
	EOF

	log info '### Preparing parameters input file...'
	ni get | jq -r 'try .parameters // {}' > "${PARAMSFILE}"

	log info '### Preparing targets input file...'
	ni get | jq -r 'try .targets | join("\n") // empty' > "${TARGETSFILE}"

	log info '### Preparing bolt-defaults.yaml file...'
	mkdir -p /etc/puppetlabs/bolt
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

function execute-action() {
	local action="$(ni get -p '{ .type }')"
	local name="$(ni get -p '{ .name }')"

	case "${action}" in
		task)
			bolt-run task "${name}"
			;;
		plan)
			bolt-run plan "${name}"
			;;
		apply)
			bolt-apply policy "${name}"
			;;
	esac
}

function bolt-run() {
	local action="${1}"
	local name="${2}"

	log info '### Running bolt...'
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

function bolt-apply() {
	# The UX of this function is intended to mimic `bolt policy apply`. We can't
	# actually use that command yet because it's not mature, but keeping around
	# the variables that make the UX match.
	local _1="${1}"
	local name="${2}"

	cat > "${WORKDIR}/apply.pp" <<-EOF
		class { '${name}':
			* => loadjson('${PARAMSFILE}'),
		}
	EOF

	pushd "${PROJDIR}"
		# Needed for loadjson() function
		bolt module add puppetlabs/stdlib
		bolt apply "${WORKDIR}/apply.pp" \
		  --project . \
		  --inventoryfile "${INVENTORYFILE}" \
		  --targets "@${TARGETSFILE}" \
		  --format json \
		  > "${OUTPUTFILE}"
		local exit_code="$?"
	popd

	return "${exit_code}"
}

main
exit 0
