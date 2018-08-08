#!/bin/bash
# Copyright (c) 2018 University of Illinois Board of Trustees
# All rights reserved.
#
# Developed by: 		Technology Services
#                      	University of Illinois at Urbana-Champaign
#                       https://techservices.illinois.edu/
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# with the Software without restriction, including without limitation the
# rights to use, copy, modify, merge, publish, distribute, sublicense, and/or
# sell copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
#	* Redistributions of source code must retain the above copyright notice,
#	  this list of conditions and the following disclaimers.
#	* Redistributions in binary form must reproduce the above copyright notice,
#	  this list of conditions and the following disclaimers in the
#	  documentation and/or other materials provided with the distribution.
#	* Neither the names of Technology Services, University of Illinois at
#	  Urbana-Champaign, nor the names of its contributors may be used to
#	  endorse or promote products derived from this Software without specific
#	  prior written permission.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# CONTRIBUTORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS WITH
# THE SOFTWARE.
set -e

echoerr () { echo "$@" 1>&2; }

aws_metadata() {
    set +e
    while [[ "$(jq -r '.MetadataFileStatus' < "$ECS_CONTAINER_METADATA_FILE")" != "READY" ]]; do
        echo "Waiting for metadata file to be ready"
        sleep 1
    done
    set -e

    ecs_cluster="$(jq -r '.Cluster' < "$ECS_CONTAINER_METADATA_FILE")"
    ecs_taskarn="$(jq -r '.TaskARN' < "$ECS_CONTAINER_METADATA_FILE")"
    ecs_taskid="${ecs_taskarn##*:task/}"
    ecs_containername="$(jq -r '.ContainerName' < "$ECS_CONTAINER_METADATA_FILE")"
    ecs_containerid="${ecs_containername}/${ecs_taskid}"
}

php_process() {
    local logstream_seqtoken='' logstream="$(
        aws logs describe-log-streams \
            --log-group-name "$PHP_AWS_METRICS_LOGGROUP_NAME" \
            --log-stream-name-prefix "$PHP_AWS_METRICS_LOGSTREAM_NAME" \
            --max-items 1 \
            --query "logStreams[?logStreamName == '$PHP_AWS_METRICS_LOGSTREAM_NAME'] | [0]"
        )"
    if [[ -n $logstream && $logstream != "null" ]]; then
        logstream_seqtoken="$(jq -r '.uploadSequenceToken' <<< "$logstream")"
    else
        aws logs create-log-stream --log-group-name "$PHP_AWS_METRICS_LOGGROUP_NAME" --log-stream-name "$PHP_AWS_METRICS_LOGSTREAM_NAME"
    fi

    declare -A prev_counters
    local msgfile="$(mktemp /tmp/pie-aws-metrics.msg.XXXXXX)"
    local evtfile="$(mktemp /tmp/pie-aws-metrics.evt.XXXXXX)"

    local log_result t status_url status_json
    local _event _values _url
    while : ; do
        while IFS='' read -r status_url || [[ -n $status_url ]]; do
            [[ -z $status_url ]] && continue
            if [[ ${prev_counters["$status_url"]} != "initialized" ]]; then
                prev_counters["$status_url accepted conn"]=0
                prev_counters["$status_url max children reached"]=0
                prev_counters["$status_url slow requests"]=0
                prev_counters["$status_url"]="initialized"
            fi

            t="$(date '+%s')000"
            status_json="$(curl --fail --max-time 10 --silent "http://${PHP_AWS_AGENT_HOST}${status_url}?json" || true)"
            if [[ -n $status_json ]]; then
                jq -c \
                    --arg u "$status_url" \
                    --argjson t $t \
                    --argjson prev_ac ${prev_counters["$status_url accepted conn"]} \
                    --argjson prev_cr ${prev_counters["$status_url max children reached"]} \
                    --argjson prev_sr ${prev_counters["$status_url slow requests"]} \
                    '(. +
                    {
                        "status url": $u,
                        "delta accepted conn": ((."accepted conn" // 0) - $prev_ac),
                        "delta max children reached": ((."max children reached" // 0) - $prev_cr),
                        "delta slow requests": ((."slow requests" // 0) - $prev_sr)
                    }) as $in
                    | { timestamp: $t, message: $in|tojson }' <<< "$status_json"
            fi
        done < "$PIE_PHPPOOLS_STATUSURLS_FILE" > "$msgfile"

        jq -n --slurpfile m "$msgfile" '$m' > "$evtfile"

        set +e
        if [[ -n $logstream_seqtoken && $logstream_seqtoken != "null" ]]; then
            log_result="$(aws logs put-log-events \
                --log-group-name "$PHP_AWS_METRICS_LOGGROUP_NAME" \
                --log-stream-name "$PHP_AWS_METRICS_LOGSTREAM_NAME" \
                --log-events "file://$evtfile" \
                --sequence-token "$logstream_seqtoken"
            )"
        else
            log_result="$(aws logs put-log-events \
                --log-group-name "$PHP_AWS_METRICS_LOGGROUP_NAME" \
                --log-stream-name "$PHP_AWS_METRICS_LOGSTREAM_NAME" \
                --log-events "file://$evtfile"
            )"
        fi
        set -e
        if [[ $? -eq 0 ]]; then
            # Can't set variables in a loop as part of a pipe; do it here
            while IFS='' read -r _event || [[ -n $_event ]]; do
                [[ -z $_event ]] && continue
                _values=($(jq -r '.message|fromjson as $m
                    |
                    $m."status url",
                    ($m."accepted conn" // 0),
                    ($m."max children reached" // 0),
                    ($m."slow requests" // 0)
                ' <<< "$_event"))
                _url="${_values[0]}"
                prev_counters["$_url accepted conn"]=${_values[1]}
                prev_counters["$_url max children reached"]=${_values[2]}
                prev_counters["$_url slow requests"]=${_values[3]}
            done < "$msgfile"
            logstream_seqtoken="$(jq -r '.nextSequenceToken' <<< "$log_result")"
        else
            # Something went wrong. Get the sequence token again
            echoerr "Failed putting log event"
            logstream_seqtoken="$(
                aws logs describe-log-streams \
                    --log-group-name "$PHP_AWS_METRICS_LOGGROUP_NAME" \
                    --log-stream-name-prefix "$PHP_AWS_METRICS_LOGSTREAM_NAME" \
                    --max-items 1 \
                    --query "logStreams[?logStreamName == '$PHP_AWS_METRICS_LOGSTREAM_NAME'] | [0].uploadSequenceToken"
                )"
        fi

        sleep $PHP_AWS_METRICS_RATE
    done

    rm -f -- "$msgfile" "$evtfile"
}

echo "PHP_AWS_AGENT_HOST: ${PHP_AWS_AGENT_HOST:=localhost:8008}"
echo "PHP_AWS_METRICS_RATE: ${PHP_AWS_METRICS_RATE:=300}"
echo "PHP_AWS_METRICS_LOGGROUP_NAME: ${PHP_AWS_METRICS_LOGGROUP_NAME:=$1}"
echo "PHP_AWS_METRICS_LOGSTREAM_NAME: ${PHP_AWS_METRICS_LOGSTREAM_NAME:=$2}"
echo "PIE_PHPPOOLS_STATUSURLS_FILE: ${PIE_PHPPOOLS_STATUSURLS_FILE}"

if [[ -z $PHP_AWS_METRICS_LOGGROUP_NAME ]]; then
    echoerr "You must specify a log group name."
    exit 1
fi
if [[ -z $PIE_PHPPOOLS_STATUSURLS_FILE ]]; then
    echoerr "You must specify PIE_PHPPOOLS_STATUSURLS_FILE."
    exit 1
fi

if [[ -z $PHP_AWS_METRICS_LOGSTREAM_NAME ]]; then
    if [[ -z $ECS_CONTAINER_METADATA_FILE ]]; then
        PHP_AWS_METRICS_LOGSTREAM_NAME="$(hostname)"
    else
        aws_metadata
        PHP_AWS_METRICS_LOGSTREAM_NAME="$ecs_containerid"
    fi
fi

php_process
