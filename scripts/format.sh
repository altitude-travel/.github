#!/usr/bin/env bash

# This file is centrally managed by the altitude-travel/github-policies
# repository and will be overwritten on every policy sync. Do not edit it
# here — propose changes in github-policies instead.

# @name format
# @brief Formats the whole codebase with Prettier, Biome, ecosystem
#        formatters, and shfmt.

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
  printf "Usage: %s [OPTIONS]
" "$0"
  printf "
"
  printf "Formats the whole codebase: Prettier, then Biome, then the\n"
  printf "ecosystem-specific formatter when this repository has one\n"
  printf "(SwiftFormat for Swift, terraform fmt for Terraform), then shfmt\n"
  printf "for shell scripts.\n"
  printf "\n"
  printf "Options:\n"
  printf "  -h, --help    Show this help message and exit\n"
}

# Formats Markdown and the file types Biome does not support.
#
# @stdout The [INFO] progress line.
#
# @exitcode 0 Always.
function format_with_prettier {
  print_information "Formatting with Prettier..."
  pnpm exec prettier --prose-wrap always --write . '!pnpm-lock.yaml'
}

# Fixes formatting and applies safe lint fixes, the final formatter.
#
# @stdout The [INFO] progress line.
#
# @exitcode 0 Always.
function format_with_biome {
  print_information "Checking and fixing with Biome..."
  pnpm exec biome check --write .
}

# Formats Swift sources when this repository has a Package.swift; no-op
# otherwise.
#
# @stdout The [INFO] progress line when it runs.
#
# @stderr The installer hint when swiftformat is missing.
# @exitcode 0 When skipped or complete.
# @exitcode 1 When swiftformat is missing.
function format_swift {
  if [ ! -f "$ROOT_DIRECTORY/Package.swift" ]; then
    return 0
  fi

  if ! command_exists swiftformat; then
    print_error "swiftformat is not installed. Install it from https://github.com/nicklockwood/SwiftFormat"
    exit 1
  fi

  print_information "Formatting Swift files with SwiftFormat..."
  swiftformat .
}

# Formats Terraform files when *.tf files exist; no-op otherwise.
#
# @stdout The [INFO] progress line when it runs.
#
# @stderr The missing-tool error.
# @exitcode 0 When skipped or complete.
# @exitcode 1 When terraform is missing.
function format_terraform {
  if ! find "$ROOT_DIRECTORY" -name "*.tf" -print -quit | grep -q .; then
    return 0
  fi

  if ! command_exists terraform; then
    print_error "terraform is not installed."
    exit 1
  fi

  print_information "Formatting Terraform files..."
  terraform fmt -recursive
}

# Formats shell scripts with shfmt across the whole tracked tree.
#
# @stdout The [INFO] progress line when scripts exist.
#
# @stderr The missing-tool error.
# @exitcode 0 When no scripts remain or formatting completes.
# @exitcode 1 When shfmt is missing or a file fails to format.
function format_shell_scripts {
  if ! command_exists shfmt; then
    print_error "shfmt is not installed."
    exit 1
  fi

  local script_files
  mapfile -t script_files < <(list_shell_scripts "$ROOT_DIRECTORY")
  if [ "${#script_files[@]}" -eq 0 ]; then
    return 0
  fi

  print_information "Formatting shell scripts with shfmt..."
  shfmt -i 2 -w -s "${script_files[@]}"
}

# Parses the options, validates the toolchain, and runs every formatter.
#
# @exitcode 0 When formatting completes.
# @exitcode 1 On an invalid option, missing pnpm, or a formatter failure.
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

  format_with_prettier
  format_with_biome
  format_swift
  format_terraform
  format_shell_scripts

  print_information "Formatting completed."
}

main "$@"
exit 0
