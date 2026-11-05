#!/bin/sh
# Point the pg-repack Container Apps job at a new image. This does NOT start
# an execution: a person starts each run (`az containerapp job start`).
#
#   RG=homestead-wus3 JOB=pg-repack-prod IMAGE=edgedive.azurecr.io/ops/pg-repack:1.5.3-throttle.1 ./job-update.sh
#
# Grace period: the Container Apps *job* template has no
# terminationGracePeriodSeconds (checked against API versions 2024-03-01
# through 2025-07-01; only container apps have it), so a stop gets the
# platform default (30s). The client's abort cleanup is bounded to fit that:
# see "Stopping a run" in README.md.
set -eu
: "${RG:?}" "${JOB:?}" "${IMAGE:?}"
az containerapp job update -g "$RG" -n "$JOB" --image "$IMAGE" \
  --query "{image: properties.template.containers[0].image}" -o json
