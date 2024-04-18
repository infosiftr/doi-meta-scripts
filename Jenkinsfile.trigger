// one job per arch (for now) that triggers builds for all unbuilt images
properties([
	disableConcurrentBuilds(),
	disableResume(),
	durabilityHint('PERFORMANCE_OPTIMIZED'),
	pipelineTriggers([
		upstream(threshold: 'UNSTABLE', upstreamProjects: 'meta'),
	]),
])

env.BASHBREW_ARCH = env.JOB_NAME.split('/')[-1].minus('trigger-') // "windows-amd64", "arm64v8", etc

def queue = []
def breakEarly = false // thanks Jenkins...

// this includes the number of attempts per failing buildId
// { buildId: { "count": 1, ... }, ... }
def pastFailedJobsJson = '{}'

node {
	stage('Checkout') {
		checkout(scmGit(
			userRemoteConfigs: [[
				url: 'https://github.com/docker-library/meta.git',
				name: 'origin',
			]],
			branches: [[name: '*/subset']], // TODO back to main
			extensions: [
				submodule(
					parentCredentials: true,
					recursiveSubmodules: true,
					trackingSubmodules: true,
				),
				cleanBeforeCheckout(),
				cleanAfterCheckout(),
				[$class: 'RelativeTargetDirectory', relativeTargetDir: 'meta'],
			],
		))
		pastFailedJobsJson = sh(returnStdout: true, script: '''#!/usr/bin/env bash
			set -Eeuo pipefail -x
			./.scripts/trigger.sh -o fetchFailedJson
		''').trim()
	}

	dir('meta') {
		def queueJson = ''
		stage('Queue') {
			withEnv([
				'pastFailedJobsJson=' + pastFailedJobsJson,
			]) {
				// using pastFailedJobsJson, sort the needs_build queue so that failing builds always live at the bottom of the queue
				queueJson = sh(returnStdout: true, script: '''
					./.scripts/trigger.sh -o sortedBuildQueue -b ./builds.json
				''').trim()
			}
		}
		if (queueJson && queueJson != '[]') {
			queue = readJSON(text: queueJson)
			currentBuild.displayName = 'queue size: ' + queue.size() + ' (#' + currentBuild.number + ')'
		} else {
			currentBuild.displayName = 'empty queue (#' + currentBuild.number + ')'
			breakEarly = true
			return
		}

		// for GHA builds, we still need a node (to curl GHA API), so we'll handle those here
		if (env.BASHBREW_ARCH == 'gha') {
			withCredentials([
				string(
					variable: 'GH_TOKEN',
					credentialsId: 'github-access-token-docker-library-bot-meta',
				),
			]) {
				withEnv([
					'queueJson=' + queueJson,
				]) {
					stage('Trigger GHA') {
						//echo(queueJson) // for debugging/data purposes
						sh '''#!/usr/bin/env bash
							set -Eeuo pipefail -x
							curlsToRun="$("./.scripts/trigger.sh" -o processGHA <<<"$queueJson")"
							eval "$curlsToRun"
						'''
					}
				}
			}
			// we're done triggering GHA, so we're completely done with this job
			breakEarly = true
			return
		}
	}
}

if (breakEarly) { return } // thanks Jenkins...

// now that we have our parsed queue, we can release the node we're holding up (since we handle GHA builds above)
def pastFailedJobs = readJSON(text: pastFailedJobsJson)
def newFailedJobs = [:]

for (buildObj in queue) {
	def identifier = buildObj.source.tags[0]
	def json = writeJSON(json: buildObj, returnText: true)
	withEnv([
		'json=' + json,
	]) {
		stage(identifier) {
			echo(json) // for debugging/data purposes

			def res = build(
				job: 'build-' + env.BASHBREW_ARCH,
				parameters: [
					string(name: 'buildId', value: buildObj.buildId),
				],
				propagate: false,
				quietPeriod: 5, // seconds
			)
			// TODO do something useful with "res.result" (especially "res.result != 'SUCCESS'")
			echo(res.result)
			if (res.result != 'SUCCESS') {
				def c = 1
				if (pastFailedJobs[buildObj.buildId]) {
					// TODO more defensive access of .count? (it is created just below, so it should be safe)
					c += pastFailedJobs[buildObj.buildId].count
				}
				// TODO maybe implement some amount of backoff? keep first url/endTime?
				newFailedJobs[buildObj.buildId] = [
					count: c,
					identifier: identifier,
					url: res.absoluteUrl,
					endTime: (res.startTimeInMillis + res.duration) / 1000.0, // convert to seconds
				]

				// "catchError" is the only way to set "stageResult" :(
				catchError(message: 'Build of "' + identifier + '" failed', buildResult: 'UNSTABLE', stageResult: 'FAILURE') { error() }
			}
		}
	}
}

// save newFailedJobs so we can use it next run as pastFailedJobs
node {
	def newFailedJobsJson = writeJSON(json: newFailedJobs, returnText: true)
	withEnv([
		'newFailedJobsJson=' + newFailedJobsJson,
	]) {
		stage('Archive') {
			dir('builds') {
				deleteDir()
				sh '''#!/usr/bin/env bash
					set -Eeuo pipefail -x

					jq <<<"$newFailedJobsJson" '.' | tee pastFailedJobs.json
				'''
				archiveArtifacts(
					artifacts: '*.json',
					fingerprint: true,
					onlyIfSuccessful: true,
				)
			}
		}
	}
}
