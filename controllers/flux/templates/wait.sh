#!/bin/sh

# This waiting script is run continuously and only updates
# hosts and runs the job (breaking from the while) when 
# update_hosts.sh has been populated. This means the pod usually
# needs to be updated with the config map that has ips!

# Always run flux commands (and the broker) as flux user
asFlux="sudo -u flux"

# Broker Options: important!
# The local-uri setting places the unix domain socket in rundir 
#   if FLUX_URI is not set, tools know where to connect.
#   -Slog-stderr-level= can be set to 7 for larger debug level
#   or exposed as a variable
brokerOptions="-Scron.directory=/etc/flux/system/cron.d \
  -Stbon.fanout=256 \
  -Srundir=/run/flux \
  -Sstatedir=${STATE_DIRECTORY:-/var/lib/flux} \
  -Slocal-uri=local:///run/flux/local \
  -Slog-stderr-level=6 \
  -Slog-stderr-mode=local"

# quorum settings influence how the instance treats missing ranks
#   by default all ranks must be online before work is run, but
#   we want it to be OK to run when a few are down
# These are currently removed because we want the main rank to
# wait for all the others, and then they clean up nicely
#  -Sbroker.quorum=0 \
#  -Sbroker.quorum-timeout=none \

# This should be added to keep running as a service
#  -Sbroker.rc2_none \

# Run diagnostics instead of a command
run_diagnostics() {
    printf "\n🐸 ${asFlux} flux start -o --config /etc/flux/config ${brokerOptions} flux overlay status\n"
    ${asFlux} flux start -o --config /etc/flux/config ${brokerOptions} flux overlay status
    printf "\n🐸 ${asFlux} flux start -o --config /etc/flux/config ${brokerOptions} flux lsattr -v\n"
    ${asFlux} flux start -o --config /etc/flux/config ${brokerOptions} flux lsattr -v
    printf "\n🐸 ${asFlux} flux start -o --config /etc/flux/config ${brokerOptions} flux dmesg\n"
    ${asFlux} flux start -o --config /etc/flux/config ${brokerOptions} flux dmesg
    printf "\n💤 sleep infinity\n"
    sleep infinity
}

# The statedir similarly should exist and have plenty of available space.
# If there are differences in containers / volumes this could eventually be
# exposed as STATEDIR variable
export STATE_DIR=/var/lib/flux
mkdir -p ${STATE_DIR}

# Cron directory
mkdir -p /etc/flux/system/cron.d

# We determine the update_hosts.sh is ready when it has content
count_lines() {
	lines=$(cat /flux_operator/update_hosts.sh | wc -l)
	echo $lines
}

while [ $(count_lines) -lt 2 ];
do
    echo "Host updating script not available yet, waiting..."
    sleep 5s
done             

# Run to discover hosts
/bin/sh /flux_operator/update_hosts.sh

# Show host updates
cat /etc/hosts

# uuid for flux token (auth)
FLUX_TOKEN="%s"

# Main host <name>-0
mainHost="%s"

# The working directory should be set by the CRD or the container
workdir=${PWD}

printf "\n👋 Hello, I'm $(hostname)\n"
printf "The main host is ${mainHost}\n"
printf "The working directory is ${workdir}\n"
ls ${workdir}

# These actions need to happen on all hosts
# Configure resources
mkdir -p /etc/flux/system

# --cores=IDS Assign cores with IDS to each rank in R, so we  assign 1-N to 0
flux R encode --hosts=%s > /etc/flux/system/R
printf "\n📦 Resources\n"
cat /etc/flux/system/R

# Do we want to run diagnostics instead of regular entrypoint?
diagnostics="%t"
printf "\n🐸 Diagnostics: ${diagnostics}\n"

mkdir -p /etc/flux/imp/conf.d/
cat <<EOT >> /etc/flux/imp/conf.d/imp.toml
[exec]
allowed-users = [ "flux", "root" ]
allowed-shells = [ "/usr/libexec/flux/flux-shell" ]	
EOT

printf "\n🦊 Independent Minister of Privilege\n"
cat /etc/flux/imp/conf.d/imp.toml

# Add a flux user (required)
useradd -u 1234 flux || printf "flux user already exists\n"

# Generate curve certificate (only need one shared)
if [ $(hostname) == "${mainHost}" ]; then
    printf "\n✨ Curve certificate being generated by $(hostname)\n"
    flux keygen /mnt/curve/curve.cert
    cat /mnt/curve/curve.cert

    # Each node needs same munge key
    cp /etc/munge/munge.key /mnt/curve/munge.key
else

    # Wait for main node to copy over its key
    while [ ! -f /mnt/curve/munge.key ];
    do
        printf "Shared munge key not available yet, waiting...\n"
        sleep 5s
    done
    while [ ! -f /mnt/curve/curve.cert ];
    do
        printf "Curve certificate not available yet, waiting...\n"
        sleep 5s
    done
    cp /mnt/curve/munge.key /etc/munge/munge.key
fi

# The rundir needs to be created first, and owned by user flux
# Along with the state directory and curve certificate
mkdir -p /run/flux
chown -R 1234 /run/flux ${STATE_DIR} /mnt/curve/curve.cert ${workdir}

# Are we running diagnostics or the start command?
if [ "${diagnostics}" == "true" ]; then
    run_diagnostics
else

    # Start flux with the original entrypoint
    if [ $(hostname) == "${mainHost}" ]; then

        # No command - use default to start server
        echo "Extra arguments are: $@"
        if [ "$@" == "" ]; then

            # Start restful API server
            startServer="uvicorn app.main:app --host=0.0.0.0 --port=5000"
            git clone --depth 1 https://github.com/flux-framework/flux-restful-api /flux-restful-api 
            cd /flux-restful-api

            # Install python requirements, with preference for python3
            python3 -m pip install -r requirements.txt || python -m pip install -r requirements.txt

            # Generate a random flux token
            FLUX_USER=flux 
            FLUX_REQUIRE_AUTH=true
            export FLUX_TOKEN FLUX_USER FLUX_REQUIRE_AUTH

            printf "\n 🔑 Your Credentials! These will allow you to control your MiniCluster with flux-framework/flux-restful-api\n"
            printf "export FLUX_TOKEN=${FLUX_TOKEN}\n"
            printf "export FLUX_USER=${FLUX_USER}\n"

            # -o is an "option" for the broker
            # -S corresponds to a shortened --setattr=ATTR=VAL
            printf "\n🌀${asFlux} flux start -o --config /etc/flux/config ${brokerOptions} ${startServer}\n"
            ${asFlux} -E flux start -o --config /etc/flux/config ${brokerOptions} ${startServer}

        # Case 2: Fall back to provided command
        else
            printf "\n🌀${asFlux} flux start -o --config /etc/flux/config ${brokerOptions} $@\n"
            ${asFlux} -E flux start -o --config /etc/flux/config ${brokerOptions} $@
        fi
    else 
        printf "\n😪 Sleeping to give RESTful server time to start...\n"
        sleep 15

        # Just run start on worker nodes, with some delay to let rank 0 start first
        printf "\n🌀${asFlux} flux start -o --config /etc/flux/config ${brokerOptions}\n"

        # We have the sleep here to give the main rank some time to start first (and not miss the workers)
        ${asFlux} flux start -o --config /etc/flux/config ${brokerOptions}
    fi
fi
