#!/usr/bin/env bash
set -Eeuo pipefail

dir="$(dirname "$BASH_SOURCE")"
dir="$(readlink -ve "$dir")"

self="$(basename "$0")"

usage() {
	cat <<EOUSAGE

usage: $self [-l jq-library-path -b builds.json ...] -o operation
   ie: $self -o fetchFailedJson
       $self -b builds.json -o sortedBuildQueue 

This script uses builds.json to setup a build queue.
EOUSAGE
}

# arg handling
opts="$(getopt -o 'b:dhl:o:?' --long 'build:,func:,help,jq-lib:,operation:' -- "$@" || { usage >&2 && false; })"
eval set -- "$opts"

jqLib="$dir"
buildsJsonFile="./builds.json"
operation=''
debug=

while true; do
	flag="$1"
	shift
	case "$flag" in
		-b) buildsJsonFile="$1" && shift ;;
		-d) debug=1 ;;
		--help|-h|'-?') usage && exit 0 ;;
		-l|--jq-lib) jqLib="$1" && shift;;
		-o|--operation|--func) operation="$1" && shift;;
		--) break ;;
		*)
			{
				echo "error: unknown flag: $flag"
				usage
			} >&2
			exit 1
			;;
	esac
done

if [ -z "$operation" ]; then
	{
		echo 'error: no operation specified, please specify one with "-o"'
		usage
	} >&2
	exit 1
fi

# Jenkinsfile.trigger

# requires `JOB_URL` (URL to the active job, provided by jenkins)
#  or attempts to guess it using `BASHBREW_ARCH`
# returns the contents of `pastFailedJobs.json` (or an empty json object if it doesn't exist `{}`)
fetchFailedJson() {
	[ -n "$debug" ] && set -x

	# TODO better JOB_URL handling?
	if [ -z "${JOB_URL:-}" ]; then
		if [ -n "${BASHBREW_ARCH:-}" ]; then
			JOB_URL="https://doi-janky.infosiftr.net/job/wip/job/new/job/trigger-$BASHBREW_ARCH"
		else
			echo >&2 'error: missing JOB_URL (and BASHBREW_ARCH fallback)'
			exit 1
		fi
	fi

	if ! json="$(wget -qO- "$JOB_URL/lastSuccessfulBuild/artifact/pastFailedJobs.json")"; then
		echo >&2 'failed to get pastFailedJobs.json'
		json='{}'
	fi
	jq <<<"$json" '.'
}

# requires "pastFailedJobsJson" to be set (the output of fetchFailedJson)
# requires 'BASHBREW_ARCH" to be set
# returns a json list of items needing build sorted with images that previously failed to build at the end
sortedBuildQueue() {
	[ -n "$debug" ] && set -x
	# using pastFailedJobsJson, sort the needs_build queue so that failing builds always live at the bottom of the queue
	if [ -z "${pastFailedJobsJson:-}" ]; then
		echo >&2 'error: missing pastFailedJobsJson'
		exit 1
	fi

	jq -L"$jqLib" '
		include "meta";
		(env.pastFailedJobsJson | fromjson) as $pastFailedJobs
		| [
			.[]
			| select(
				needs_build
				and (
					.build.arch as $arch
					| if env.BASHBREW_ARCH == "gha" then
						[ "amd64", "i386", "windows-amd64" ]
					else [ env.BASHBREW_ARCH ] end
					| index($arch)
				)
			)
		]
		# the Jenkins job exports a JSON file that includes the number of attempts so far per failing buildId so that this can sort by attempts which means failing builds always live at the bottom of the queue (sorted by the number of times they have failed, so the most failing is always last)
		| sort_by($pastFailedJobs[.buildId].count // 0)
	' "$buildsJsonFile"
}

# input: json array of builds on stdin
# output: curl statments in a string to be evaled
# creates a new line separated list of curls that will trigger builds on GHA
# needs GH_TOKEN to be set when running the curl statements
processGHA() {
	[ -n "$debug" ] && set -x
	# https://docs.github.com/en/free-pro-team@latest/rest/actions/workflows?apiVersion=2022-11-28#create-a-workflow-dispatch-event
	jq -r -L"$jqLib" '
		include "jenkins";
		.[] | [
			@sh "echo " + .source.tags[0],
			@sh "curl -fL
				-X POST
				-H \("Accept: application/vnd.github+json")
				-H \"Authorization: Bearer $GH_TOKEN\"
				-H \("X-GitHub-Api-Version: 2022-11-28")
				https://api.github.com/repos/docker-library/meta/actions/workflows/build.yml/dispatches
				-d \(gha_payload | @json)
			"
			| gsub("[\n\t]+"; " ")
		]
		| join("\n")
	'
}

if [ "$(type -t "$operation")" == 'function' ]; then
	"$operation"
else
	{
		echo "error: unknown operation: $operation"
		usage
	} >&2
	exit 1
fi
