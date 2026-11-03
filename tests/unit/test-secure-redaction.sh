#!/bin/bash
# tests/unit/test-secure-redaction.sh
# Tests for sanitize_secrets (PEM, postgresql://, rediss://) and guard_output anomaly cap
# Kannaktopus issue #171

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$SCRIPT_DIR/../helpers/test-framework.sh"
source "$PROJECT_ROOT/scripts/lib/secure.sh"

test_suite "Secure: redaction gaps and anomaly cap"

test_pem_multiline_redacted() {
    test_case "sanitize_secrets redacts multi-line PEM private key"
    local pem out
    pem=$'before\n-----BEGIN RSA PRIVATE KEY-----\nMIIBOgIBAAJBAKj34GkxFhD90vcNLYLInFEX6Ppy1tPf9Cnzj4p4WGeKLs1Pt8Qu\n-----END RSA PRIVATE KEY-----\nafter'
    out=$(sanitize_secrets "$pem") || out=""
    assert_not_contains "$out" "MIIBOgIBAAJB" "PEM body leaked" || return 0
    assert_contains "$out" "[REDACTED-PRIVATE-KEY]" "marker missing" || return 0
    assert_contains "$out" "after" "text after key lost" || return 0
    test_pass
}

test_postgresql_rediss_redacted() {
    test_case "sanitize_secrets redacts postgresql:// and rediss:// strings"
    local out
    out=$(sanitize_secrets "postgresql://u:pw@h/db rediss://:pw@h") || out=""
    assert_not_contains "$out" "pw" "password leaked: $out" || return 0
    test_pass
}

test_guard_output_caps_anomalies() {
    test_case "guard_output caps anomaly lines for huge matching output"
    local d content out
    d=$(mktemp -d)
    content=$(for i in $(seq 1 5000); do echo "FAIL test case number $i"; done)
    out=$(OCTOPUS_TMP_DIR="$d" guard_output "$content" "t") || out=""
    rm -rf "$d"
    if [[ ${#out} -lt 60000 && ${#out} -gt 0 ]]; then
        assert_contains "$out" "more matching lines dropped" "drop count missing" || return 0
        test_pass
    else
        test_fail "output too large: ${#out}"
    fi
}

test_pem_multiline_redacted
test_postgresql_rediss_redacted
test_guard_output_caps_anomalies

test_summary
