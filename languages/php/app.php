#!/usr/bin/env php
<?php
// proxymock CNCF demo app (PHP). Exposes a small HTTP API on :8080 and fulfills each
// request by calling the CNCF downstream API. PHP's curl extension is libcurl: it
// honors HTTP(S)_PROXY, but — like the C++ demo — does not read SSL_CERT_FILE on
// its own, so we set CURLOPT_CAINFO. CURLOPT_PROXY is also set from the env so a
// PHP build that disabled libcurl's env proxy still records. Run: php app.php
$DOWNSTREAM = getenv('DOWNSTREAM_URL') ?: 'https://demo-api.trafficreplay.com';
$PORT = intval(getenv('PORT') ?: '8080');

$VALID_TOKENS = [];
$ORDERS = [];

function fetch(string $path): array
{
    global $DOWNSTREAM;
    $ch = curl_init($DOWNSTREAM . $path);
    curl_setopt_array($ch, [
        CURLOPT_RETURNTRANSFER => true,
        CURLOPT_FOLLOWLOCATION => true,
        CURLOPT_TIMEOUT => 10,
    ]);
    // Speedscale's PHP language reference sets CURLOPT_PROXY explicitly. Do that
    // from the env proxymock injects so both env-aware and env-blind builds work.
    $proxy = getenv('HTTPS_PROXY') ?: getenv('https_proxy')
        ?: getenv('HTTP_PROXY') ?: getenv('http_proxy')
        ?: getenv('ALL_PROXY') ?: getenv('all_proxy');
    if ($proxy) {
        curl_setopt($ch, CURLOPT_PROXY, $proxy);
    }
    $noproxy = getenv('NO_PROXY') ?: getenv('no_proxy');
    if ($noproxy) {
        curl_setopt($ch, CURLOPT_NOPROXY, $noproxy);
    }
    // libcurl (unlike the curl CLI) uses a compiled-in CA bundle and ignores
    // SSL_CERT_FILE. Point CAINFO at it so proxymock's TLS interception verifies.
    $ca = getenv('SSL_CERT_FILE');
    if ($ca) {
        curl_setopt($ch, CURLOPT_CAINFO, $ca);
    }
    $body = curl_exec($ch);
    if ($body === false) {
        $err = curl_error($ch);
        curl_close($ch);
        return [502, json_encode(['error' => $err], JSON_UNESCAPED_SLASHES)];
    }
    $code = (int) curl_getinfo($ch, CURLINFO_RESPONSE_CODE);
    curl_close($ch);
    return [$code, $body];
}

function send($conn, int $code, $body): void
{
    if (!is_string($body)) {
        $body = json_encode($body, JSON_UNESCAPED_SLASHES);
    }
    $status = [
        200 => '200 OK',
        201 => '201 Created',
        400 => '400 Bad Request',
        401 => '401 Unauthorized',
        404 => '404 Not Found',
    ][$code] ?? '502 Bad Gateway';
    fwrite(
        $conn,
        "HTTP/1.1 {$status}\r\nContent-Type: application/json\r\nContent-Length: "
        . strlen($body) . "\r\nConnection: close\r\n\r\n{$body}"
    );
    fclose($conn);
}

function authed(?string $header): bool
{
    global $VALID_TOKENS;
    if ($header === null || !str_starts_with($header, 'Bearer ')) {
        return false;
    }
    return isset($VALID_TOKENS[substr($header, 7)]);
}

$server = @stream_socket_server("tcp://0.0.0.0:{$PORT}", $errno, $errstr);
if ($server === false) {
    fwrite(STDERR, "php demo failed to listen on :{$PORT}: {$errstr}\n");
    exit(1);
}
echo "php demo on :{$PORT} (downstream={$DOWNSTREAM})\n";

while ($conn = @stream_socket_accept($server, -1)) {
    $requestLine = fgets($conn);
    $path = $requestLine ? (explode(' ', trim($requestLine))[1] ?? '/') : '/';
    $method = $requestLine ? (explode(' ', trim($requestLine))[0] ?? 'GET') : 'GET';
    $authHeader = null;
    $contentLength = 0;
    while (($line = fgets($conn)) !== false && $line !== "\r\n" && $line !== "\n") {
        if (preg_match('/\AAuthorization:\s*(.*?)\r?\n\z/i', $line, $m)) {
            $authHeader = $m[1];
        } elseif (preg_match('/\AContent-Length:\s*(\d+)\r?\n\z/i', $line, $m)) {
            $contentLength = (int) $m[1];
        }
    }
    $reqBody = $contentLength > 0 ? stream_get_contents($conn, $contentLength) : '';

    try {
        if ($path === '/') {
            send($conn, 200, [
                'service' => 'proxymock-cncf-demo',
                'lang' => 'php',
                'downstream' => $DOWNSTREAM,
            ]);
        } elseif ($path === '/api/projects') {
            send($conn, ...fetch('/v1/projects'));
        } elseif (str_starts_with($path, '/api/projects/')) {
            send($conn, ...fetch('/v1/project/' . substr($path, strlen('/api/projects/'))));
        } elseif ($path === '/api/categories') {
            send($conn, ...fetch('/v1/categories'));
        } elseif ($path === '/api/stats') {
            [, $raw] = fetch('/v1/projects');
            $projects = json_decode($raw, true) ?: [];
            $byMaturity = [];
            foreach ($projects as $proj) {
                $m = $proj['maturity'] ?? '';
                $byMaturity[$m] = ($byMaturity[$m] ?? 0) + 1;
            }
            send($conn, 200, ['total' => count($projects), 'by_maturity' => $byMaturity]);
        } elseif ($method === 'POST' && $path === '/oauth/token') {
            $token = bin2hex(random_bytes(32));
            $VALID_TOKENS[$token] = true;
            send($conn, 200, [
                'access_token' => $token,
                'token_type' => 'Bearer',
                'expires_in' => 3600,
            ]);
        } elseif ($method === 'POST' && $path === '/api/orders') {
            if (!authed($authHeader)) {
                send($conn, 401, ['error' => 'missing or invalid bearer token']);
                continue;
            }
            $req = $reqBody === '' ? [] : (json_decode($reqBody, true) ?: []);
            $project = $req['project'] ?? '';
            if ($project === '') {
                send($conn, 400, ['error' => 'project is required']);
                continue;
            }
            [$dcode] = fetch('/v1/project/' . $project);
            if ($dcode !== 200) {
                send($conn, 404, ['error' => 'unknown project', 'project' => $project]);
                continue;
            }
            $order = [
                'order_id' => 'order-' . bin2hex(random_bytes(8)),
                'project' => $project,
                'status' => 'created',
                'created' => gmdate('Y-m-d\TH:i:s\Z'),
            ];
            $ORDERS[$order['order_id']] = $order;
            send($conn, 201, $order);
        } elseif ($method === 'GET' && str_starts_with($path, '/api/orders/')) {
            $id = substr($path, strlen('/api/orders/'));
            if (!authed($authHeader)) {
                send($conn, 401, ['error' => 'missing or invalid bearer token']);
            } elseif (!isset($ORDERS[$id])) {
                send($conn, 404, ['error' => 'order not found', 'order_id' => $id]);
            } else {
                send($conn, 200, $ORDERS[$id]);
            }
        } else {
            send($conn, 404, ['error' => 'not found']);
        }
    } catch (Throwable $e) {
        send($conn, 502, ['error' => $e->getMessage()]);
    }
}
