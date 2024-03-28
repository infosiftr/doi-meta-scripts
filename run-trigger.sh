#!/usr/bin/env bash
set -Eeuo pipefail

# example script to run the Jenkins trigger pipeline locally

dir="$(dirname "$BASH_SOURCE")"
dir="$(readlink -ve "$dir")"

: ${BASHBREW_ARCH:=arm64v8}
export BASHBREW_ARCH

pastFailedJobsJson="$("$dir/trigger.sh" -o fetchFailedJson "$@")"
export pastFailedJobsJson
queueJson="$("$dir/trigger.sh" -o sortedBuildQueue "$@")"

if [ "$BASHBREW_ARCH" = "gha" ]; then
	thingsToEval="$("$dir/trigger.sh" -o processGHA "$@" <<<"$queueJson")"
	if [ -z "${GH_TOKEN:-}" ]; then
		echo "$thingsToEval"
	else
		echo 'eval' "$thingsToEval"
	fi
else
	# TODO do non-gha things, like "triggering" builds or maybe just build them? or provide output that the "build.sh" pipline can take
	true
#	for item in "$( jq <<<"$queueJson" '.[] | @json' )"; do
#		jq <<<"$item" '. | fromjson | .source.tags[0]'
#	done
fi
