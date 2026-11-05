#!/bin/sh
# Point the pg-repack Container Apps job at the new image and give it a long
# termination grace period, so a stop (SIGTERM) can finish the rollback and
# repack_drop before SIGKILL. This does NOT start an execution: a person
# starts each run (`az containerapp job start`).
#
#   RG=<resource group> JOB=<job name> IMAGE=<acr>/ops/pg-repack:1.5.3-throttle.1 ./job-update.sh
set -eu
: "${RG:?}" "${JOB:?}" "${IMAGE:?}"
az containerapp job update -g "$RG" -n "$JOB" --image "$IMAGE"
# terminationGracePeriodSeconds is not a CLI flag; patch the template via ARM.
id=$(az containerapp job show -g "$RG" -n "$JOB" --query id -o tsv)
az rest --method patch --url "https://management.azure.com${id}?api-version=2024-03-01" \
  --body '{"properties":{"template":{"terminationGracePeriodSeconds":600}}}'
az containerapp job show -g "$RG" -n "$JOB" \
  --query "{image: properties.template.containers[0].image, grace: properties.template.terminationGracePeriodSeconds}"
