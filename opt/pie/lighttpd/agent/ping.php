<?php

define('AGENT_HOST', $_SERVER['PHP_AWS_AGENT_HOST'] ?? 'localhost:8009');
define('PINGURLS_FILE', $_SERVER['PIE_PHPPOOLS_PINGURLS_FILE'] ?? '/run/php-fpm.d/ping-urls.txt');
define('PINGURLS_TIMEOUT', intval($_SERVER['PIE_PHPPOOLS_PINGURLS_TIMEOUT'] ?? '25'));

function ping_pools() {
    $data = file(PINGURLS_FILE);
    if ($data === false) {
        throw new Exception("Error reading ping URLs file: " . PINGURLS_FILE);
    }
    $pools = [];
    foreach ($data as $line) {
        $line = trim($line);
        if (str_starts_with($line, '#') || empty($line)) {
            continue;
        }
        $line_data = explode(' ', $line, 2);
        if (!$line_data) {
            continue;
        }
        if (!str_starts_with($line_data[1], '/')) {
            $line_data[1] = '/' . $line_data[1];
        }

        $pools[] = [
            'name'      => $line_data[0],
            'ping_url'  => $line_data[1],
        ];
    }

    $results = [];
    $has_errors = false;
    $m_handle = curl_multi_init();
    try {
        $total_handles = 0;
        foreach ($pools as $pool_idx => $pool) {
            $c_handle = curl_init("http://" . AGENT_HOST . $pool['ping_url']);
            if (!curl_setopt_array($c_handle, [
                CURLOPT_RETURNTRANSFER  => 1,
                CURLOPT_TIMEOUT         => PINGURLS_TIMEOUT,
                CURLOPT_PRIVATE         => $pool_idx,
            ])) {
                throw new Exception("Error setting curl options: {$pool['name']}");
            }

            curl_multi_add_handle($m_handle, $c_handle);
            $total_handles++;
        }

        if (!$total_handles) {
            return;
        }

        while ($total_handles > 0) {
            $running_count = null;
            do {
                $res = curl_multi_exec($m_handle, $running_count);
            } while ($res === CURLM_CALL_MULTI_PERFORM);
            if ($res !== CURLM_OK) {
                throw new Exception("Error executing curl multi: " . curl_multi_strerror($res));
            }

            if ($running_count < $total_handles) {
                while (false !== ($m_info = curl_multi_info_read($m_handle))) {
                    if ($m_info['msg'] !== CURLMSG_DONE) {
                        continue;
                    }

                    $c_handle = $m_info['handle'];
                    $c_info = curl_getinfo($c_handle);
                    $pool_idx = curl_getinfo($c_handle, CURLINFO_PRIVATE);
                    $pool = $pools[$pool_idx];

                    $results[$pool_idx] = [
                        'name'  => $pool['name'],
                        'url'   => $pool['ping_url'],
                        'time'  => sprintf('%.2fms', $c_info['total_time'] * 1000),
                        'error' => false,
                    ];

                    if ($m_info['result'] !== CURLE_OK) {
                        $c_error = curl_error($c_handle);

                        $results[$pool_idx]['error'] = "cURL error: {$c_error}";
                        $has_errors = true;
                    } else {
                        $c_content = curl_multi_getcontent($c_handle);

                        if ($c_info['http_code'] < 200 || $c_info['http_code'] >= 300) {
                            $results[$pool_idx]['error'] = "HTTP response: status={$c_info['http_code']}";
                            $has_errors = true;
                        } elseif (trim($c_content) !== 'pong') {
                            $results[$pool_idx]['error'] = "Invalid content: " . substr($c_content, 0, 100);
                            $has_errors = true;
                        }
                    }

                    curl_multi_remove_handle($m_handle, $c_handle);
                    $total_handles--;
                }
            } else {
                curl_multi_select($m_handle, 1);
            }
        }
    } finally {
        curl_multi_close($m_handle);
    }

    return [$has_errors, $results];
}

header("Cache-Control: no-store, no-cache, must-revalidate, max-age=0", true);
header("Cache-Control: post-check=0, pre-check=0", false);
header("Pragma: no-cache", true);

try {
    [$has_errors, $results] = ping_pools();

    if ($has_errors) {
        http_response_code(500);
        header("Content-Type: application/json");
        echo json_encode($results);
    } else {
        foreach ($results as $result_idx => $result) {
            header("X-Ping{$result_idx}: {$result['name']} {$result['url']} {$result['time']}");
        }
        header("Content-Type: text/plain");
        echo "pong";
    }
} catch (Exception $err) {
    http_response_code(500);
    header("Content-Type: text/plain");
    echo $err->getMessage();
}
