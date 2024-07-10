#!/bin/bash

source .check.lib.sh
check kubectl jq helm awk

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m' # No Color

function versioncheck() {
    local app=$1
    local chart=$2
    local repoURL=$3
    local version=$4

    # Add the repository if it is not already added
    helm repo add temp-repo "$repoURL" > /dev/null 2>&1
    helm repo update > /dev/null 2>&1

    # Get the latest version of the chart
    local latestInfo
    latestInfo=$(helm search repo temp-repo/"$chart" | awk 'NR==2 {print $1, $2}')
    local latestVersion=$(echo "$latestInfo" | awk '{print $2}')

    # Remove the temporary repository
    helm repo remove temp-repo > /dev/null 2>&1

    if [[ "$latestVersion" != "$version" ]]; then
        echo -e "${RED}Outdated${NC}: $app ($repoURL $chart): ${RED}$version${NC} [$latestVersion]"
    else
        echo -e "${GREEN}OK${NC}: $app ($repoURL $chart): ${GREEN}$version${NC}"
    fi
}

export -f versioncheck

kubectl get -n argocd applications.argoproj.io -o json | \
    jq '.items.[] ' |
    jq '{name: .metadata.name, source: ([.spec.source] + .spec.sources).[] | {chart: .chart, repoURL: .repoURL, version: .targetRevision } }' |
    jq 'select(.source.chart != null)' |
    jq -r '"\(.name) \(.source.chart) \(.source.repoURL) \(.source.version)"' |

    while read -r app chart repoURL version; do
        versioncheck "$app" "$chart" "$repoURL" "$version"
    done