<?php

require_once __DIR__ . '/util.php';

$apcu_enabled = function_exists( 'apcu_enabled' ) && apcu_enabled();
$opcache_enabled = (bool)ini_get( 'opcache.enable' );


function handle_cache_delete( string $cache_type, array $keys ) : array {
    global $apcu_enabled, $opcache_enabled;

    if (!$keys) {
        return array();
    }

    if ($cache_type === 'apcu' && $apcu_enabled) {
        $result = apcu_delete( $keys );
    } elseif ($cache_type === 'opcache' && $opcache_enabled) {
        $result = array();
        foreach ($keys as $key) {
            $result[$key] = opcache_invalidate( $key, true );
        }
    } else {
        throw new HTTPException( 'Invalid cache type: ' . $cache_type, HTTPStatusCode::BadRequest );
    }

    return $result;
}

function handle_cache_flush( ?string $cache_type ) : array {
    global $apcu_enabled, $opcache_enabled;

    if (empty( $cache_type )) {
        $cache_type = 'all';
    } else if ($cache_type !== 'apcu' && $cache_type !== 'opcache' && $cache_type !== 'all') {
        throw new HTTPException( 'Invalid cache type: ' . $cache_type, HTTPStatusCode::BadRequest );
    }

    $result = array();
    if (($cache_type === 'apcu' || $cache_type === 'all') && $apcu_enabled) {
        $result['apcu'] = apcu_clear_cache();
    }

    if (($cache_type === 'opcache' || $cache_type === 'all') && $opcache_enabled) {
        $result['opcache'] = opcache_reset();
    }

    return $result;
}

function handle_cache_get( ?string $cache_type ) : array {
    global $apcu_enabled, $opcache_enabled;

    if (empty( $cache_type )) {
        $cache_type = 'all';
    } else if ($cache_type !== 'apcu' && $cache_type !== 'opcache' && $cache_type !== 'all') {
        throw new HTTPException( 'Invalid cache type: ' . $cache_type, HTTPStatusCode::BadRequest );
    }

    $result = array();
    if (($cache_type === 'apcu' || $cache_type === 'all') && $apcu_enabled) {
        $info = apcu_cache_info();
        unset( $info['cache_list'] );
        unset( $info['slot_distribution'] );
        unset( $info['deleted_list'] );

        $it = new APCUIterator( null, APC_ITER_ALL, 100, APC_LIST_ACTIVE );
        $info['items'] = array();
        foreach ($it as $data) {
            if ($data['type'] !== 'user')
                    continue;

            $key   = $data['key'];
            $value = $data['value'];

            $info['items'][$key] = array(
                'ttl'           => $data['ttl'],
                'num_hits'      => $data['num_hits'],
                'mtime'         => $data['mtime'],
                'creation_time' => $data['creation_time'],
                'access_time'   => $data['access_time'],
                'mem_size'      => $data['mem_size'],
                'ref_count'     => $data['ref_count'],
            );
            if (is_null( $value ) || is_bool( $value ) || is_numeric( $value )) {
                $info['items'][$key]['value'] = $value;
            } elseif (is_string( $value )) {
                if (preg_match( '/[^\x20-\x7E]/', $value)) {
                    $info['items'][$key]['value_b64'] = base64_encode( $value );
                } else {
                    $info['items'][$key]['value'] = $value;
                }
            }
        }

        $result['apcu'] = $info;
    }

    if (($cache_type === 'opcache' || $cache_type === 'all') && $opcache_enabled) {
        $result['opcache'] = opcache_get_status( true );
    }

    return $result;
}

function handler( mixed $data ) : mixed {
    require_authentication();

    $cache_type = empty( $_GET['type'] ) ? null : $_GET['type'];
    $action = empty( $_GET['action'] ) ? null : $_GET['action'];

    switch ($_SERVER['REQUEST_METHOD']) {
        case 'POST':
            switch ($action) {
                case 'flush':
                    $result = handle_cache_flush( $cache_type );
                    break;
                default:
                    throw new HTTPException( 'Invalid action: ' . $action, HTTPStatusCode::NotFound );
            }
            break;

        case 'DELETE':
            $keys = $data['keys'] ?? array();
            if (!is_array( $keys )) {
                throw new HTTPException( 'Invalid keys: not array', HTTPStatusCode::BadRequest );
            }
            $result = handle_cache_delete( $cache_type, $keys );
            break;

        case 'GET':
            $result = handle_cache_get( $cache_type );
            break;

        default:
            throw new HTTPException( 'Invalid request method: ' . $_SERVER['REQUEST_METHOD'], HTTPStatusCode::MethodNotAllowed );
    }

    return $result;
}

api_entrypoint();
