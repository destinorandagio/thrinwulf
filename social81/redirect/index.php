<?php
declare(strict_types=1);

// SOCIAL81+ proprietary redirect/tracking endpoint.
// Deploy this directory under a branded URL such as https://go.81plus.net/

$defaultDestination = 'https://corsi.elearningsicurezza.com/pid/2377/';
$allowedHosts = ['corsi.elearningsicurezza.com'];

function clean(string $value, int $max = 100): string {
    $value = preg_replace('/[^a-zA-Z0-9_.-]/', '_', $value) ?? '';
    return substr($value, 0, $max);
}

$source   = clean((string)($_GET['s'] ?? 'social81'));
$medium   = clean((string)($_GET['m'] ?? 'social'));
$campaign = clean((string)($_GET['c'] ?? 'free_courses'));
$content  = clean((string)($_GET['p'] ?? 'generic'));
$target   = (string)($_GET['to'] ?? $defaultDestination);

$parts = parse_url($target);
if (!$parts || !isset($parts['scheme'], $parts['host']) || !in_array(strtolower($parts['scheme']), ['http','https'], true) || !in_array(strtolower($parts['host']), $allowedHosts, true)) {
    $target = $defaultDestination;
}

$separator = str_contains($target, '?') ? '&' : '?';
$tracked = $target . $separator . http_build_query([
    'utm_source' => $source,
    'utm_medium' => $medium,
    'utm_campaign' => $campaign,
    'utm_content' => $content,
], '', '&', PHP_QUERY_RFC3986);

$event = [
    'ts' => gmdate('c'),
    'source' => $source,
    'medium' => $medium,
    'campaign' => $campaign,
    'content' => $content,
    // Privacy-first: no raw IP, email, phone, wallet or user identifier is stored.
    'ua_hash' => substr(hash('sha256', (string)($_SERVER['HTTP_USER_AGENT'] ?? '')), 0, 16),
    'referer_host' => (string)(parse_url((string)($_SERVER['HTTP_REFERER'] ?? ''), PHP_URL_HOST) ?? ''),
];

$dataDir = __DIR__ . '/data';
if (!is_dir($dataDir)) { @mkdir($dataDir, 0755, true); }
$logFile = $dataDir . '/clicks-' . gmdate('Y-m') . '.jsonl';
@file_put_contents($logFile, json_encode($event, JSON_UNESCAPED_SLASHES) . PHP_EOL, FILE_APPEND | LOCK_EX);

header('Cache-Control: no-store, private');
header('Referrer-Policy: strict-origin-when-cross-origin');
header('Location: ' . $tracked, true, 302);
exit;
