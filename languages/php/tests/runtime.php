<?php

require __DIR__ . '/../runtime.php';

$versions = [
    70433 => false,
    80134 => false,
    80235 => false,
    80300 => false,
    80335 => false,
    80336 => true,
    80337 => true,
    80400 => false,
    80426 => false,
    80427 => true,
    80428 => true,
    80500 => false,
    80511 => false,
    80512 => true,
    80513 => true,
    80600 => false,
];

foreach ($versions as $version => $expected) {
    if (php_runtime_is_patched($version) !== $expected) {
        throw new RuntimeException("Incorrect runtime decision for {$version}");
    }
}
echo "PHP runtime security checks passed\n";
