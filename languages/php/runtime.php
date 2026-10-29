<?php

function php_runtime_is_patched(int $version): bool
{
    $minimums = [803 => 80336, 804 => 80427, 805 => 80512];
    $branch = intdiv($version, 100);
    return isset($minimums[$branch]) && $version >= $minimums[$branch];
}

if (!php_runtime_is_patched(PHP_VERSION_ID)) {
    fwrite(STDERR, "Use patched PHP 8.3.36+, 8.4.27+, or 8.5.12+ within those release branches.\n");
    exit(1);
}
