# Test image of the radioctl bats tests (tests/radioctl/run.sh): bats-core
# with bash 5, plus jq and util-linux flock, which radioctl needs. Pinned:
# no floating tags (deploy-init-plan.md §1).
FROM bats/bats:1.11.1
RUN apk add --no-cache jq util-linux-misc coreutils findutils
