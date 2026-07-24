#!/usr/bin/env bash

set -Eeuo pipefail

TESTS_RUN=0
TESTS_FAILED=0

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  return 1
}

assert_eq() {
  local expected="$1"
  local actual="$2"
  local message="$3"
  [[ "$actual" == "$expected" ]] ||
    fail "$message (expected=$expected actual=$actual)"
}

assert_success() {
  "$@" || fail "expected success: $*"
}

assert_failure() {
  if ("$@"); then
    fail "expected failure: $*"
  fi
}

run_test() {
  local name="$1"
  local function_name="$2"
  TESTS_RUN=$((TESTS_RUN + 1))
  if ("$function_name"); then
    printf 'PASS: %s\n' "$name"
  else
    TESTS_FAILED=$((TESTS_FAILED + 1))
  fi
}

finish_tests() {
  printf '%s tests, %s failures\n' "$TESTS_RUN" "$TESTS_FAILED"
  ((TESTS_FAILED == 0))
}
