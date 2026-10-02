#!/usr/bin/env bash

# This file is centrally managed by the altitude-travel/github-policies
# repository and will be overwritten on every policy sync. Do not edit it
# here — propose changes in github-policies instead.

# @name lint
# @brief Checks the whole codebase with Prettier, Biome, ecosystem linters,
#        shfmt, and ShellCheck.

set -euo pipefail

SCRIPT_DIRECTORY="$(dirname "$0")"
readonly SCRIPT_DIRECTORY
ROOT_DIRECTORY="$(dirname "$SCRIPT_DIRECTORY")"
readonly ROOT_DIRECTORY

if [ -s "$SCRIPT_DIRECTORY/common.sh" ]; then
  source "$SCRIPT_DIRECTORY/common.sh"
else
  print_error "The shared helper module is missing: $SCRIPT_DIRECTORY/common.sh"
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
  swiftformat . --lint

  if [ "$(uname)" != "Darwin" ] || ! command_exists swiftlint; then
    print_information "SwiftLint skipped (requires SourceKit, available on macOS only)."
    return 0
  fi

  print_information "Linting Swift with SwiftLint..."
  swiftlint_args=(--strict)

  if [ "${CI:-}" = "true" ]; then
    swiftlint_args+=(--reporter github-actions-logging)
  fi

  swiftlint lint "${swiftlint_args[@]}"
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
  terraform fmt -check -recursive

  print_information "Validating Terraform configuration..."
  terraform init -backend=false -upgrade -input=false >/dev/null
  terraform validate
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
  shfmt -i 2 -s -d "${script_files[@]}"

  print_information "Linting shell scripts with ShellCheck..."
  shellcheck -x -S warning "${script_files[@]}"
}

# Checks Markdown and the file types Biome does not support.
#
# @stdout The [INFO] progress line and Prettier's check output.
#
# @exitcode 0 Always.
function lint_with_prettier {
  print_information "Checking formatting with Prettier..."
  pnpm exec prettier --prose-wrap always --check . '!pnpm-lock.yaml'
}

# Runs Biome's formatter and linter; the GitHub reporter activates under CI.
#
# @stdout The [INFO] progress line and Biome's findings.
#
# @exitcode 0 Always; callers read Biome's own exit through the pipeline.
function lint_with_biome {
  print_information "Checking with Biome..."
  biome_args=()
  if [ "${CI:-}" = "true" ]; then
    biome_args+=(--reporter=default --reporter=github)
  fi

  pnpm exec biome check "${biome_args[@]}" .
}

# Parses the options, validates the toolchain, and runs every check.
#
# @exitcode 0 When all checks pass.
# @exitcode 1 On an invalid option, missing pnpm, or a failed check.
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

  if ! command_exists pnpm; then
    print_error "pnpm is not installed."
    exit 1
  fi

  lint_with_prettier
  lint_with_biome
  lint_swift
  lint_terraform
  lint_shell_scripts

  print_information "Linting completed."
}

main "$@"
exit 0
