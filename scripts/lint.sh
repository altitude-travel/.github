#!/usr/bin/env bash

# This file is centrally managed by the altitude-travel/github-policies
# repository and will be overwritten on every policy sync. Do not edit it
# here — propose changes in github-policies instead.

# @name lint

# @brief Checks the whole codebase with Prettier, Biome, ecosystem linters,
#        shfmt, and ShellCheck.

set -euo pipefail

SCRIPT_DIRECTORY="$(cd "$(dirname "$0")" && pwd)"
readonly SCRIPT_DIRECTORY
ROOT_DIRECTORY="$(dirname "$SCRIPT_DIRECTORY")"
readonly ROOT_DIRECTORY

if [ -s "$SCRIPT_DIRECTORY/common.sh" ]; then
  source "$SCRIPT_DIRECTORY/common.sh"
else
  printf "[ERROR]: The shared helper module is missing: %s\n" "$SCRIPT_DIRECTORY/common.sh" >&2
  exit 1
fi

# Displays the usage text.
#
# @stdout The usage text.
#
# @exitcode 0 Always.
function print_usage {
  printf "Usage: %s [OPTIONS]\n" "$0"
  printf "\n"
  printf "Checks the whole codebase: Prettier, then Biome, then the\n"
  printf "ecosystem-specific linters when this repository has them\n"
  printf "(SwiftFormat and SwiftLint for Swift, terraform fmt and validate\n"
  printf "for Terraform), then shfmt and ShellCheck for shell scripts.\n"
  printf "\n"
  printf "Options:\n"
  printf "  -h, --help    Show this help message and exit\n"
}

# Checks Swift sources with SwiftFormat --lint and, on macOS, SwiftLint;
# no-op when this repository has no Package.swift.
#
# @stdout The [INFO] progress lines and a skip notice off macOS.
#
# @stderr The installer hint when swiftformat is missing.

# @exitcode 0 When skipped or clean.
# @exitcode 1 When swiftformat is missing or Swift is unclean.
function lint_swift {
  if [ ! -f "$ROOT_DIRECTORY/Package.swift" ]; then
    return 0
  fi

  if ! command_exists swiftformat; then
    print_error "swiftformat is not installed. Install it from https://github.com/nicklockwood/SwiftFormat"
    exit 1
  fi

  print_information "Checking Swift formatting with SwiftFormat..."
  if ! swiftformat . --lint; then
    print_error "SwiftFormat lint check failed."
    exit 1
  fi

  if [ "$(uname)" != "Darwin" ] || ! command_exists swiftlint; then
    print_information "SwiftLint skipped (requires SourceKit, available on macOS only)."
    return 0
  fi

  print_information "Linting Swift with SwiftLint..."
  swiftlint_args=(--strict)

  if [ "${CI:-}" = "true" ]; then
    swiftlint_args+=(--reporter github-actions-logging)
  fi

  if ! swiftlint lint "${swiftlint_args[@]}"; then
    print_error "SwiftLint failed."
    exit 1
  fi
}

# Checks Terraform formatting and validates the configuration; no-op when no
# *.tf files exist.
#
# @stdout The [INFO] progress lines.
#
# @stderr The missing-tool error or the failing check.

# @exitcode 0 When skipped or valid.
# @exitcode 1 When terraform is missing or validation fails.
function lint_terraform {
  if ! find "$ROOT_DIRECTORY" -name "*.tf" -print -quit | grep -q .; then
    return 0
  fi

  if ! command_exists terraform; then
    print_error "terraform is not installed."
    exit 1
  fi

  print_information "Checking Terraform formatting..."
  if ! terraform fmt -check -recursive; then
    print_error "Terraform format check failed."
    exit 1
  fi

  print_information "Validating Terraform configuration..."
  terraform init -backend=false -upgrade -input=false >/dev/null
  if ! terraform validate; then
    print_error "Terraform validation failed."
    exit 1
  fi
}

# Checks shell script formatting with shfmt and lints with ShellCheck across
# the whole tracked tree.
#
# @stdout The [INFO] progress lines.
#
# @stderr The missing-tool error or the shfmt diff.

# @exitcode 0 When no scripts remain or checks pass.
# @exitcode 1 When a tool is missing or a check fails.
function lint_shell_scripts {
  if ! command_exists shfmt; then
    print_error "shfmt is not installed."
    exit 1
  fi

  if ! command_exists shellcheck; then
    print_error "shellcheck is not installed."
    exit 1
  fi

  local script_files
  mapfile -t script_files < <(list_shell_scripts "$ROOT_DIRECTORY")
  if [ "${#script_files[@]}" -eq 0 ]; then
    return 0
  fi

  print_information "Checking shell script formatting with shfmt..."
  if ! shfmt -i 2 -s -d "${script_files[@]}"; then
    print_error "shfmt formatting check failed."
    exit 1
  fi

  print_information "Linting shell scripts with ShellCheck..."
  if ! shellcheck -x --source-path="$HOME" --severity=warning --shell=bash "${script_files[@]}"; then
    print_error "ShellCheck failed."
    exit 1
  fi
}

# Checks the file types Biome does not support (Markdown, YAML, and friends).
#
# @stdout The [INFO] progress line and Prettier's check output.

# @stderr The failure line when the check fails.

# @exitcode 0 When every file is Prettier-clean.
# @exitcode 1 When Prettier reports unformatted files or fails.
function lint_with_prettier {
  print_information "Checking formatting with Prettier..."
  if ! pnpm exec prettier --prose-wrap always --check .; then
    print_error "Prettier formatting check failed."
    exit 1
  fi
}

# Runs Biome's formatter and linter; the GitHub reporter activates under CI.
#
# @stdout The [INFO] progress line and Biome's findings.

# @stderr The failure line when the check fails.

# @exitcode 0 When Biome reports no findings.
# @exitcode 1 When Biome reports findings or fails.
function lint_with_biome {
  print_information "Checking with Biome..."
  local biome_args=()
  if [ "${CI:-}" = "true" ]; then
    biome_args+=(--reporter=default --reporter=github)
  fi

  if ! pnpm exec biome check "${biome_args[@]}" .; then
    print_error "Biome check failed."
    exit 1
  fi
}

# Validates every tool the active lint pipeline will invoke before the first
# check runs.
#
# @stderr The missing-tool error.
#
# @exitcode 0 When every required tool is present.
# @exitcode 1 When a required tool is missing.
function validate_lint_toolchain {
  if ! command_exists pnpm; then
    print_error "pnpm is not installed."
    exit 1
  fi

  if ! pnpm exec prettier --version >/dev/null 2>&1; then
    print_error "prettier is not resolvable. Add it to the devDependencies and install."
    exit 1
  fi

  if ! pnpm exec biome --version >/dev/null 2>&1; then
    print_error "biome is not resolvable. Add it to the devDependencies and install."
    exit 1
  fi

  if [ -f "$ROOT_DIRECTORY/Package.swift" ] && ! command_exists swiftformat; then
    print_error "swiftformat is not installed. Install it from https://github.com/nicklockwood/SwiftFormat"
    exit 1
  fi

  if find "$ROOT_DIRECTORY" -name "*.tf" -print -quit | grep -q . && ! command_exists terraform; then
    print_error "terraform is not installed."
    exit 1
  fi

  if ! command_exists shfmt; then
    print_error "shfmt is not installed."
    exit 1
  fi

  if ! command_exists shellcheck; then
    print_error "shellcheck is not installed."
    exit 1
  fi
}

# Parses the options, validates the toolchain, and runs every check.
#
# @exitcode 0 When all checks pass.
# @exitcode 1 On an invalid option or a failed preflight or check.
# @exitcode 2 When ROOT_DIRECTORY is empty.
function main {
  if [ -z "$ROOT_DIRECTORY" ]; then
    print_error "ROOT_DIRECTORY is not set."
    exit 2
  fi

  while [ $# -gt 0 ]; do
    case "$1" in
    -h | --help)
      print_usage
      exit 0
      ;;
    *)
      print_error "Invalid option: $1"
      print_usage
      exit 1
      ;;
    esac
  done

  cd "$ROOT_DIRECTORY"

  validate_lint_toolchain

  lint_with_prettier
  lint_with_biome
  lint_swift
  lint_terraform
  lint_shell_scripts

  print_information "Linting completed."
}

main "$@"
exit 0
