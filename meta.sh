#!/usr/bin/env bash
set -Eeuo pipefail

dir="$(dirname "$BASH_SOURCE")"
dir="$(readlink -ve "$dir")"

# TODO warn/error if DOCKERHUB_PUBLIC_PROXY is unset

# Jenkinsfile.meta

# Checkout
checkout() {
# github.com:docker-library/meta (scripts are run as submodule of meta)
}

# Update DOI (submodules)
submodules() {
	git submodule update --remote --merge .doi
	git submodule update --remote --merge .scripts
}

# Fetch (pre-fetch build contexts)
bbfetch() {
	bashbrew --library .doi/library fetch $(cat subset.txt) # TODO --all
}

# Sources
sources() {
# we only need to regenerate "sources.json" if ".doi", ".scripts", or "subset.txt" have changed since we last generated it
	needsBuild=
	if [ ! -s commits.json ] || [ ! -s sources.json ]; then
		needsBuild=1
	fi

	doi="$(git -C .doi log -1 --format='format:%H')"
	scripts="$(git -C .scripts log -1 --format='format:%H')"
	subset="$(sha256sum subset.txt | cut -d' ' -f1)"
	export doi scripts subset
	jq -n '{ doi: env.doi, scripts: env.scripts, subset: env.subset }' | tee commits.json
	if [ -z "$needsBuild" ] && ! git diff --exit-code commits.json; then
		needsBuild=1
	fi

	if [ -n "$needsBuild" ]; then
		images="$(cat subset.txt)"
		[ -n "$images" ]
		.scripts/sources.sh $images > sources.json
	fi
}

# Builds
builds() {
	.scripts/builds.sh --cache cache-builds.json sources.json > builds.json
}

# Commit
commit() {
	git add -A .
	if ! git diff --staged --exit-code; then # commit fails if there's nothing to commit
		git commit -m 'Update and regenerate'
	fi
}

# Push
push() {
	git push origin HEAD:subset # TODO back to main
}
