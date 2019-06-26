#!/usr/bin/env python3
import boto3
from collections import defaultdict
import json
import logging
import os
import re
import requests
import socket
import time

logger = logging.getLogger(__name__)

logs_clnt = boto3.client('logs')

ECS_TASKID_RE = re.compile(r'^.+:task/(?:(?P<cluster>[a-zA-Z0-9-]+)/)?(?P<id>.+)$')

AGENT_HOST = os.environ.get('PHP_AWS_AGENT_HOST', 'localhost:8008')
ECS_CONTAINER_METADATA_FILE = os.environ.get('ECS_CONTAINER_METADATA_FILE', None)
METRICS_LOGGROUP_NAME = os.environ['PHP_AWS_METRICS_LOGGROUP_NAME']
METRICS_LOGSTREAM_NAME = os.environ.get('PHP_AWS_METRICS_LOGSTREAM_NAME', None)
METRICS_RATE = int(os.environ.get('PHP_AWS_METRICS_RATE', '300'))
POOLS_STATUSURLS_FILE = os.environ['PIE_PHPPOOLS_STATUSURLS_FILE']

class PHPPool(object):
    """ Gathers and tracks the status of a PHP pool. """
    def __init__(self, name, status_urlpath):
        self._name = name
        self._start_time = 0
        self._status_urlpath = status_urlpath

    def __str__(self):
        return self._name

    @property
    def name(self):
        return self._name

    def fetch_status(self):
        url = 'http://{0}{1}?json'.format(AGENT_HOST, self._status_urlpath)
        r = requests.get(url, timeout=10)
        r.raise_for_status()

        result = r.json()
        if result.get('start time', 0) != self._start_time:
            # PHP was restarted; clear our previous values
            self._status_prev = defaultdict(lambda: 0)
            self._start_time = result['start time']

        self._status_curr = defaultdict(lambda: 0)
        for key in ('accepted conn', 'max children reached', 'slow requests'):
            self._status_curr[key] = result.get(key, 0)
            result['delta ' + key] = self._status_curr[key] - self._status_prev[key]

        return result

    def update_status(self):
        if not self._status_curr:
            raise ValueError('current status values are invalid')
        self._status_prev = self._status_curr
        self._status_curr = defaultdict(lambda: 0)


def get_ecs_metadata():
    """
    Gets the ECS metadata for the container. This requires the
    ECS_CONTAINER_METADATA_FILE environment variable be defined or
    an exception will be thrown.
    """
    if not ECS_CONTAINER_METADATA_FILE:
        raise ValueError('No ECS_CONTAINER_METADATA_FILE')

    metadata_ready = False
    metadata = None
    while not metadata_ready:
        try:
            with open(ECS_CONTAINER_METADATA_FILE, 'r') as f:
                metadata = json.load(f)
        except Exception:
            logger.exception('Unable to open and parse %(file)', {
                'file': ECS_CONTAINER_METADATA_FILE,
            })
        else:
            metadata_ready = metadata.get('MetadataFileStatus', '') == 'READY'

        if not metadata_ready:
            logger.info('Waiting for ECS metadata')
            time.sleep(1)

    result = {
        'cluster':          metadata.get('Cluster', ''),
        'taskArn':          metadata.get('TaskARN', ''),
        'containerName':    metadata.get('ContainerName', ''),
    }
    m = ECS_TASKID_RE.match(result['taskArn'])
    if m:
        result['taskId'] = m.group('id')
    if result['containerName'] and result.get('taskId', None):
        result['containerId'] = '{0}/{1}'.format(result['containerName'], result['taskId'])

    return result


def get_logstream_seqtoken(logstream_name):
    while True:
        try:
            response = logs_clnt.describe_log_streams(
                logGroupName=METRICS_LOGGROUP_NAME,
                logStreamNamePrefix=logstream_name,
                orderBy='LogStreamName',
            )

            # Try to find out logstream in the returned values
            for logstream in response.get('logStreams', []):
                if logstream.get('logStreamName') == logstream_name:
                    return logstream.get('uploadSequenceToken', None)

            # We didn't find our logstream. Create it instead
            logs_clnt.create_log_stream(
                logGroupName=METRICS_LOGGROUP_NAME,
                logStreamName=logstream_name,
            )
            return None
        except Exception:
            logger.exception('Unable to get the sequence token for %(group)s:%(stream)s; will sleep and retry', {
                'group': METRICS_LOGGROUP_NAME,
                'stream': logstream_name,
            })

        time.sleep(10)


def process(pools, logstream_name, logstream_seqtoken):
    curr_pools = set()
    with open(POOLS_STATUSURLS_FILE, 'r') as f:
        for line in f:
            pool_name, pool_status_urlpath = line.strip().split()
            curr_pools.add(pool_name)
            if not pool_name in pools:
                logger.info('Adding pool %(name)s: %(statusurl)s', {
                    'name': pool_name,
                    'statusurl': pool_status_urlpath,
                })
                pools[pool_name] = PHPPool(pool_name, pool_status_urlpath)
    for pool_name in list(pools.keys()):
        if not pool_name in curr_pools:
            logger.info('Removing pool %(name)s', {
                'name': pool_name,
            })
            del pools[pool_name]

    events = {}
    for pool in pools.values():
        try:
            logger.debug('Fetching status for %(name)s', {
                'name': pool,
            })
            pool_status = pool.fetch_status()
            events[pool.name] = {
                'timestamp': int(time.time()) * 1000,
                'message': json.dumps(pool_status),
            }
        except Exception:
            logger.exception('Unable to fetch the status for %(pool)s', {
                'pool': pool,
            })

    if not events:
        logger.warn('No events built')
        return logstream_seqtoken

    args = {
        'logGroupName':     METRICS_LOGGROUP_NAME,
        'logStreamName':    logstream_name,
        'logEvents':        list(events.values()),
    }
    if logstream_seqtoken:
        args['sequenceToken'] = logstream_seqtoken

    try:
        logger.debug('Sending events to %(group)s:%(stream)s', {
            'group': args['logGroupName'],
            'stream': args['logStreamName'],
        })
        response = logs_clnt.put_log_events(**args)
    except Exception:
        logger.exception('Unable to put log events')
        raise
    else:
        logstream_seqtoken = response.get('nextSequenceToken', None)
        for pool in pools.values():
            pool.update_status()

    return logstream_seqtoken

def run():
    logstream_name = METRICS_LOGSTREAM_NAME
    if not logstream_name:
        if ECS_CONTAINER_METADATA_FILE:
            ecs_metadata = get_ecs_metadata()
            logstream_name = '{cluster}/{containerId}'.format(**ecs_metadata)
        else:
            logstream_name = socket.gethostname()

    logstream_seqtoken = get_logstream_seqtoken(logstream_name)
    pools = {}

    while True:
        try:
            logstream_seqtoken = process(pools, logstream_name, logstream_seqtoken)
        except Exception:
            logger.exception('Unable to process status metrics')
            logstream_seqtoken = get_logstream_seqtoken(logstream_name)

        time.sleep(METRICS_RATE)

if __name__ == '__main__':
    logging.basicConfig()
    run()
