#!/bin/bash

access_op=${1:-==}
access_mode=${2:-deny}

local_ips=($(hostname --all-ip-addresses))
for ip in "${local_ips[@]}"; do
    [[ -z $ip ]] && continue

    echo "
    \$HTTP[\"remoteip\"] ${access_op} \"${ip}\" {
        url.access-${access_mode} = (\"\")
    }
    "
done
