<?php
declare(strict_types=1);

// Protect this endpoint in production (Basic Auth, reverse proxy auth, or admin session).
header('Content-Type: application/json; charset=utf-8');
header('Cache-Control: no-store');

$dataDir = __DIR__ . '/data';
$totals = ['clicks' => 0, 'campaigns' => [], 'sources' => [], 'posts' => []];

foreach (glob($dataDir . '/clicks-*.jsonl') ?: [] as $file) {
    $fh = @fopen($file, 'rb');
    if (!$fh) continue;
    while (($line = fgets($fh)) !== false) {
        $e = json_decode($line, true);
        if (!is_array($e)) continue;
        $totals['clicks']++;
        foreach ([['campaigns','campaign'], ['sources','source'], ['posts','content']] as [$bucket,$key]) {
            $v = (string)($e[$key] ?? 'unknown');
            $totals[$bucket][$v] = ($totals[$bucket][$v] ?? 0) + 1;
        }
    }
    fclose($fh);
}

foreach (['campaigns','sources','posts'] as $bucket) arsort($totals[$bucket]);
echo json_encode($totals, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES);
