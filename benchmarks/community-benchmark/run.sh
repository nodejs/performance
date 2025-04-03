#!/bin/bash
function assertShaLike() {
    local shaVarName="${1}"
    local sha="${!1}"
    if [ -z "${sha}" ] || ! echo "${sha}" | grep -qE '^[0-9a-fA-F]+$'; then
        echo "${shaVarName} (${sha}) does not look like a commit SHA"
        exit
    fi
}

function assertMatchesPullRequest() {
    local shaVarName="${1}"
    local sha="${!1}"
    local pr_id="${!2}"
    if [[ ! "$(git ls-remote origin refs/pull/${pr_id}/head)" =~ ^${sha}.*refs/pull/${pr_id}/head$ ]]; then
        echo "${shaVarName} (${sha}) does not match HEAD for pull request ${pr_id}"
        exit
    fi
}

function mandatory() {
    if [ -z "${!1}" ]; then
        echo "${1} not set"
        usage
        exit
    fi
}

function optional() {
    if [ -z "${!1}" ]; then
        echo -n "${1} not set (ok)"
        if [ -n "${2}" ]; then
            echo -n ", default is: ${2}"
            export ${1}="${2}"
        fi
        echo ""
    fi
}
function usage(){
echo "Usage:"

echo "This script has two use cases:"
echo "Use case 1: We want to test the impact of a PR on a branch."
echo "To run this, declare:"
echo "The script expects the following variables to be set:"
echo "CATEGORY = a category of tests to run - folders in benchmark/"
echo "BRANCH = the branch the test should be based off. e.g. master"
echo "PULL_ID = the pull request that contains changes to test"
echo "TARGET = the SHA of the commit HEAD that contains changes to test"
echo "-------------------------------------------------------------"
echo "Use case 2: We want to compare two branches, tags or commits."
echo "To run this, declare:"
echo "CATEGORY = a category of tests to run - folders in benchmark/"
echo "BASE = the branch/tag/commit the test should be based off. e.g. master"
echo "TARGET = the branch/tag/commit to compare against base"
echo "-------------------------------------------------------------"
echo "The following are optional across both use cases"
echo "RUNS = defaults to empty"
echo "FILTER = defaults to empty"
echo "MACHINE_THREADS - used for building node. Defaults to all threads on machine"
echo "CPUSET - used for pinning to specific CPU cores. Default to 0-11 (performance cores)"
}

if [ -z $PULL_ID ]; then
#PULL_ID isn't declared. Therefore we are probably in use case #2
	export USE_CASE=2
	mandatory BASE
	mandatory TARGET
else
	export USE_CASE=1
	mandatory BRANCH
	mandatory PULL_ID
	mandatory TARGET
	assertShaLike TARGET
fi
mandatory CATEGORY
optional RUNS 
optional FILTER
optional CPUSET "0-11"
getMACHINE_THREADS=`cat /proc/cpuinfo |grep processor|tail -n1|awk {'print $3'}`
let getMACHINE_THREADS=getMACHINE_THREADS+1 #getting threads this way is 0 based. Add one
optional MACHINE_THREADS $getMACHINE_THREADS
rm -rf node
git clone --depth=1 https://github.com/nodejs/node.git
cd node
case $USE_CASE in
1)
	# Validate TARGET and pull request HEAD are consistent
	assertMatchesPullRequest TARGET PULL_ID
	git checkout $BRANCH
	;;
2)
	git checkout $BASE
	;;
esac

# build master
# select the appropriate compiler
curl -sLO https://raw.githubusercontent.com/nodejs/build/master/jenkins/scripts/select-compiler.sh
. ./select-compiler.sh
./configure  > ../node-master-build.log
make -j${MACHINE_THREADS}  >> ../node-master-build.log
mv out/Release/node ./node-master

# build pr
case $USE_CASE in
1)
        curl -L "https://github.com/nodejs/node/compare/$(git rev-parse HEAD)...${TARGET}.patch"|git apply -3
	;;
2)
	git checkout $TARGET
	;;
esac
# select the appropriate compiler
. ./select-compiler.sh
./configure > ../node-pr-build.log
make -j${MACHINE_THREADS} >> ../node-pr-build.log
mv out/Release/node ./node-pr
if [ -n "$FILTER" ]; then
	FILTER="--filter ${FILTER}"
fi
if [ -n "$RUNS" ]; then
	RUNS="--runs ${RUNS}"
fi
if [ -n "$CPUSET" ]; then
  CPUSET="--set CPUSET=${CPUSET}"
fi
# run benchmark
fileName=output`date +%d%m%y-%H%M%S`.csv
echo "Output will be saved to $fileName"
pwd

# Run on performance cores
./node-master benchmark/compare.js $CPUSET --old ./node-master --new ./node-pr $FILTER $RUNS -- $CATEGORY | tee $fileName

cat $fileName | Rscript benchmark/compare.R
mv $fileName $startDir
