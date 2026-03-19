#!/usr/bin/env bash

# Strict mode: exit on error, undefined variables, and pipe failures.
# This line must never be removed.
set -euo pipefail

# ---------------------------------------------------------------------------
# Path discovery — resolve the directory this script lives in and the project
# root so that all file references are absolute and portable.
# ---------------------------------------------------------------------------
SCRIPT_DIRECTORY="$(dirname "$0")"
readonly SCRIPT_DIRECTORY
ROOT_DIRECTORY="$(dirname "$SCRIPT_DIRECTORY")"
readonly ROOT_DIRECTORY

# ---------------------------------------------------------------------------
# Configuration — maximum file size for review and constants for the
# Mistral API integration.
# ---------------------------------------------------------------------------
readonly MAX_FILE_SIZE_BYTES=500000

# Maximum total content size per review batch (bytes). The HTTP request body
# has no hard size limit, but keeping batches under 1MB avoids excessive
# token counts and keeps response times reasonable.
readonly MAX_BATCH_CONTENT_BYTES=1000000

# Mistral API endpoint and model for code review
readonly MISTRAL_API_URL="https://api.mistral.ai/v1/chat/completions"
readonly MISTRAL_MODEL="devstral-latest"
readonly REVIEW_PREAMBLE="You are a code reviewer. Find REAL bugs and security vulnerabilities ONLY.

RULES:
1. Your training data is outdated. NEVER flag version numbers, package versions, action versions, API names, CLI flags, or language syntax as wrong — they may be newer than your knowledge. If you do not recognise a syntax construct or API, assume it is valid.
2. ONLY report issues with clear evidence IN THE CODE. If you are not 100% certain, do NOT report it. Read the code carefully before claiming something is missing or incorrect — re-read the exact lines to confirm.
3. For each issue you MUST include a code_snippet field containing the EXACT code from the file that proves the issue. Copy-paste the problematic code verbatim. If you cannot quote the exact code, the issue is not real — do NOT report it.
4. Environment variable references, secret manager lookups, shell variable interpolation, and GitHub Actions secrets references are NOT hardcoded secrets — they are the correct way to handle credentials. Fallback defaults for non-sensitive config are NOT security issues. Development credentials in docker-compose.dev.yml are NOT critical. Public keys, public certificates, and public key fingerprints are PUBLIC by design and are NOT secrets — only flag a key if you are certain it is a PRIVATE key.
5. Do NOT report: style preferences, missing features that ARE present in the code, portability concerns for CI-only scripts, speculative scenarios, or over-engineered suggestions. Do NOT report error handling as incomplete when typed throws or exhaustive pattern matching is used — the type system guarantees completeness."

# ---------------------------------------------------------------------------
# Logging helpers — consistent prefixed output for information and errors.
# ---------------------------------------------------------------------------
function print_error {
	printf "[ERROR]: %s\n" "$1" >&2
}

function print_information {
	printf "[INFO]: %s\n" "$1" >&1
}

# ---------------------------------------------------------------------------
# Usage information — displays available CLI options.
# ---------------------------------------------------------------------------
function print_usage {
	printf "Usage: %s [OPTIONS]\n" "$0"
	printf "\n"
	printf "Reviews code using the Mistral API.\n"
	printf "\n"
	printf "Options:\n"
	printf "  -h, --help    Show this help message and exit\n"
}

# ---------------------------------------------------------------------------
# Validate GitHub environment variables — ensures GITHUB_REPOSITORY and
# GITHUB_PULL_REQUEST_NUMBER are well-formed when present, preventing
# injection into API calls.
# ---------------------------------------------------------------------------
function validate_github_env {
	if [[ -n ${GITHUB_REPOSITORY:-} ]]; then
		if [[ ! ${GITHUB_REPOSITORY} =~ ^[a-zA-Z0-9._-]+/[a-zA-Z0-9._-]+$ ]]; then
			print_error "Invalid GITHUB_REPOSITORY format: ${GITHUB_REPOSITORY}"
			exit 1
		fi
	fi

	if [[ -n ${GITHUB_PULL_REQUEST_NUMBER:-} ]]; then
		if [[ ! ${GITHUB_PULL_REQUEST_NUMBER} =~ ^[0-9]+$ ]]; then
			print_error "Invalid GITHUB_PULL_REQUEST_NUMBER: ${GITHUB_PULL_REQUEST_NUMBER}"
			exit 1
		fi
	fi
}

# ---------------------------------------------------------------------------
# GitHub API wrapper with retry logic — retries failed API calls up to 3
# times with exponential backoff (2s, 4s, 8s) to handle transient errors.
# ---------------------------------------------------------------------------
function gh_api_with_retry {
	local max_retries=3
	local retry_delay=2
	local attempt=0

	while [[ ${attempt} -lt ${max_retries} ]]; do
		if gh api "$@" 2>/dev/null; then
			return 0
		fi

		attempt=$((attempt + 1))
		if [[ ${attempt} -lt ${max_retries} ]]; then
			print_information "GitHub API call failed, retrying in ${retry_delay}s (attempt ${attempt}/${max_retries})"
			sleep "${retry_delay}"
			retry_delay=$((retry_delay * 2))
		fi
	done

	print_error "GitHub API call failed after ${max_retries} attempts"
	return 1
}

# ---------------------------------------------------------------------------
# Authenticate with Mistral — checks for MISTRAL_API_KEY in the environment
# first, then falls back to reading it from ~/.vibe/.env. Warns if the env
# file has overly permissive permissions.
# ---------------------------------------------------------------------------
function check_mistral_auth {
	# If the key is already in the environment, nothing else to do
	if [[ -n ${MISTRAL_API_KEY:-} ]]; then
		return 0
	fi

	# Attempt to read the key from the local env file
	local vibe_env_file="${HOME}/.vibe/.env"
	if [[ ! -f ${vibe_env_file} ]]; then
		print_error "MISTRAL_API_KEY not set and ${vibe_env_file} not found"
		exit 1
	fi

	# Extract the API key from the env file
	MISTRAL_API_KEY=$(grep --extended-regexp '^MISTRAL_API_KEY=' "${vibe_env_file}" | cut --delimiter '=' --fields 2- || true)
	if [[ -z ${MISTRAL_API_KEY:-} ]]; then
		print_error "Could not find MISTRAL_API_KEY in ${vibe_env_file}"
		exit 1
	fi
	export MISTRAL_API_KEY
}

# ---------------------------------------------------------------------------
# Retrieve the list of changed files with their diff data. In GitHub Actions,
# fetches from the PR API; locally, uses git diff against main.
#
# Writes a JSON array of {filename, patch, status} objects to the output file.
# Returns 0 on success, 1 on failure.
# ---------------------------------------------------------------------------
function get_changed_files {
	local output_file="$1"

	if [[ -n ${GITHUB_REPOSITORY:-} && -n ${GITHUB_PULL_REQUEST_NUMBER:-} ]]; then
		# Running in GitHub Actions — fetch changed files from the PR API
		validate_github_env

		local api_response
		if ! api_response=$(gh_api_with_retry --paginate "repos/${GITHUB_REPOSITORY}/pulls/${GITHUB_PULL_REQUEST_NUMBER}/files"); then
			print_error "Failed to fetch changed files from GitHub API"
			return 1
		fi

		# Extract filename, patch, and status for modified/added files
		echo "${api_response}" | jq --compact-output '
			[.[] | select(.status == "modified" or .status == "added") |
			 {filename: .filename, patch: (.patch // ""), status: .status}]
		' >"${output_file}" 2>/dev/null || {
			print_error "Failed to parse changed files response"
			return 1
		}
	else
		# Running locally — use git diff to produce unified diff and parse
		# into the same JSON structure as the GitHub API path
		local diff_output
		diff_output=$(git diff --no-color main HEAD 2>/dev/null || echo "")

		if [[ -z ${diff_output} ]]; then
			echo "[]" >"${output_file}"
			return 0
		fi

		# Parse unified diff into JSON: extract filename, patch, and status
		local entries_file
		entries_file=$(mktemp)
		local current_file=""
		local current_patch=""
		local in_patch=false

		while IFS= read -r line; do
			# Detect new file header
			if [[ ${line} == "diff --git"* ]]; then
				# Write previous file entry if we have one
				if [[ -n ${current_file} ]]; then
					jq --null-input \
						--arg filename "${current_file}" \
						--arg patch "${current_patch}" \
						'{filename: $filename, patch: $patch, status: "modified"}' >>"${entries_file}"
				fi

				# Extract filename from the b/ side of the diff header
				current_file="${line##* b/}"
				current_patch=""
				in_patch=false
			elif [[ ${line} == "@@"* ]]; then
				# Start of a hunk — begin capturing patch text
				in_patch=true
				if [[ -n ${current_patch} ]]; then
					current_patch="${current_patch}
${line}"
				else
					current_patch="${line}"
				fi
			elif [[ ${in_patch} == true ]]; then
				# Inside a hunk — accumulate patch lines
				current_patch="${current_patch}
${line}"
			fi
		done <<<"${diff_output}"

		# Write the last file entry
		if [[ -n ${current_file} ]]; then
			jq --null-input \
				--arg f "${current_file}" \
				--arg p "${current_patch}" \
				'{filename: $f, patch: $p, status: "modified"}' >>"${entries_file}"
		fi

		# Combine all entries into a single JSON array
		if [[ -s ${entries_file} ]]; then
			jq --slurp '.' "${entries_file}" >"${output_file}"
		else
			echo "[]" >"${output_file}"
		fi
		rm --force "${entries_file}"
	fi

	return 0
}

# ---------------------------------------------------------------------------
# Parse unified diff patch text to build a map of valid RIGHT-side line
# numbers per file. These are the line numbers that GitHub will accept for
# line-level review comments.
#
# Reads the PR files JSON and writes a JSON array of
# {filename, valid_lines: [int...]} objects to the output file.
# ---------------------------------------------------------------------------
function parse_diff_hunks {
	local pr_files_json="$1"
	local output_file="$2"

	local entries_file
	entries_file=$(mktemp)

	# Process each file's patch text
	local file_count
	file_count=$(jq 'length' "${pr_files_json}")
	local i=0

	while [[ ${i} -lt ${file_count} ]]; do
		local filename
		filename=$(jq --raw-output ".[${i}].filename" "${pr_files_json}")
		local patch
		patch=$(jq --raw-output ".[${i}].patch // \"\"" "${pr_files_json}")

		local valid_lines=""
		local new_line_num=0

		# Parse the patch line by line to find valid RIGHT-side line numbers
		if [[ -n ${patch} ]]; then
			while IFS= read -r line; do
				if [[ ${line} =~ ^@@[[:space:]]-[0-9]+(,[0-9]+)?[[:space:]]\+([0-9]+)(,([0-9]+))?[[:space:]]@@ ]]; then
					# Hunk header — extract the new-side start line
					new_line_num=${BASH_REMATCH[2]}
				elif [[ ${line} == "+"* ]]; then
					# Addition line — valid for comments, increment counter
					if [[ -n ${valid_lines} ]]; then
						valid_lines="${valid_lines},${new_line_num}"
					else
						valid_lines="${new_line_num}"
					fi
					new_line_num=$((new_line_num + 1))
				elif [[ ${line} == " "* ]]; then
					# Context line — valid for comments, increment counter
					if [[ -n ${valid_lines} ]]; then
						valid_lines="${valid_lines},${new_line_num}"
					else
						valid_lines="${new_line_num}"
					fi
					new_line_num=$((new_line_num + 1))
				elif [[ ${line} == "-"* ]]; then
					# Deletion line — old side only, do NOT increment
					:
				fi
			done <<<"${patch}"
		fi

		# Write the entry for this file
		jq --null-input \
			--arg filename "${filename}" \
			--argjson valid_lines "[${valid_lines}]" \
			'{filename: $filename, valid_lines: $valid_lines}' >>"${entries_file}"

		i=$((i + 1))
	done

	# Combine all entries into a single JSON array
	if [[ -s ${entries_file} ]]; then
		jq --slurp '.' "${entries_file}" >"${output_file}"
	else
		echo "[]" >"${output_file}"
	fi
	rm --force "${entries_file}"
}

# ---------------------------------------------------------------------------
# Map each validated issue to its correct diff position by finding the
# code_snippet in the actual file content and checking against the diff map.
#
# Adds in_diff, mapped_line, and mapped_start_line fields to each issue.
# ---------------------------------------------------------------------------
function map_issues_to_diff {
	local validated_result="$1"
	local files_json_file="$2"
	local diff_map_file="$3"

	# Ensure the input is a valid JSON array
	if ! echo "${validated_result}" | jq --exit-status 'type == "array"' >/dev/null 2>&1; then
		echo "[]"
		return
	fi

	local result_file
	result_file=$(mktemp)
	local snippet_file
	snippet_file=$(mktemp)

	# Process each file entry in the validated result
	local file_count
	file_count=$(echo "${validated_result}" | jq 'length')
	local i=0

	while [[ ${i} -lt ${file_count} ]]; do
		local file_path
		file_path=$(echo "${validated_result}" | jq --raw-output ".[${i}].file_path")

		# Get the file content from the files JSON
		local file_content
		file_content=$(jq --raw-output \
			--arg filepath "${file_path}" \
			'[.[] | select(.path == $filepath)] | .[0].content // ""' \
			"${files_json_file}")

		# Get valid lines for this file from the diff map
		local valid_lines_json
		valid_lines_json=$(jq --raw-output \
			--arg filename "${file_path}" \
			'[.[] | select(.filename == $filename)] | .[0].valid_lines // []' \
			"${diff_map_file}")

		# Process each issue in this file entry
		local issue_count
		issue_count=$(echo "${validated_result}" | jq ".[${i}].issues | length")
		local mapped_issues="[]"
		local j=0

		while [[ ${j} -lt ${issue_count} ]]; do
			local issue
			issue=$(echo "${validated_result}" | jq ".[${i}].issues[${j}]")
			local code_snippet
			code_snippet=$(echo "${issue}" | jq --raw-output '.code_snippet // ""')

			if [[ -n ${code_snippet} && -n ${file_content} ]]; then
				# Write content and snippet to temp files for grep lookup
				printf '%s\n' "${file_content}" >"${snippet_file}.content"
				printf '%s' "${code_snippet}" >"${snippet_file}.snippet"

				# Find the line number of the first occurrence of the snippet
				local first_line
				first_line=$(grep -n -F -f "${snippet_file}.snippet" "${snippet_file}.content" 2>/dev/null | head -1 | cut -d: -f1 || echo "")

				if [[ -n ${first_line} ]]; then
					# Count lines in the snippet to determine range
					local snippet_lines
					snippet_lines=$(echo "${code_snippet}" | wc -l | tr --delete ' ')
					local last_line=$((first_line + snippet_lines - 1))

					# Check which lines in the range are in the diff
					local in_diff=false
					local mapped_line=""
					local mapped_start_line=""

					local line_num=${first_line}
					while [[ ${line_num} -le ${last_line} ]]; do
						# Check if this line is in the valid_lines array
						if echo "${valid_lines_json}" | jq --exit-status "index(${line_num})" >/dev/null 2>&1; then
							in_diff=true
							if [[ -z ${mapped_start_line} ]]; then
								mapped_start_line=${line_num}
							fi
							mapped_line=${line_num}
						fi
						line_num=$((line_num + 1))
					done

					# Add mapping fields to the issue
					if [[ ${in_diff} == true ]]; then
						issue=$(echo "${issue}" | jq \
							--argjson in_diff true \
							--argjson mapped_line "${mapped_line}" \
							--argjson mapped_start_line "${mapped_start_line}" \
							'. + {in_diff: $in_diff, mapped_line: $mapped_line, mapped_start_line: $mapped_start_line}')
					else
						issue=$(echo "${issue}" | jq '. + {in_diff: false}')
					fi
				else
					issue=$(echo "${issue}" | jq '. + {in_diff: false}')
				fi
			else
				issue=$(echo "${issue}" | jq '. + {in_diff: false}')
			fi

			mapped_issues=$(echo "${mapped_issues}" | jq --argjson issue "${issue}" '. + [$issue]')
			j=$((j + 1))
		done

		# Write the file entry with mapped issues
		echo "${validated_result}" | jq \
			--argjson issues "${mapped_issues}" \
			".[${i}] | .issues = \$issues" >>"${result_file}"

		i=$((i + 1))
	done

	# Combine all file entries into a single JSON array
	if [[ -s ${result_file} ]]; then
		jq --slurp '.' "${result_file}"
	else
		echo "[]"
	fi
	rm --force "${result_file}" "${snippet_file}" "${snippet_file}.content" "${snippet_file}.snippet" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Merge diff patch data from the PR files JSON into the loaded file entries.
# Adds a "diff" field to each file entry containing its unified diff patch.
# ---------------------------------------------------------------------------
function merge_diff_data {
	local files_json_file="$1"
	local pr_files_json="$2"

	# Add the patch text from PR files to each loaded file entry
	jq --slurpfile pr_files "${pr_files_json}" '
		[.[] | . as $entry |
		 ($pr_files[0] // [] | map(select(.filename == $entry.path)) | .[0].patch // "") as $patch |
		 $entry + {diff: $patch}]
	' "${files_json_file}" >"${files_json_file}.tmp" && mv "${files_json_file}.tmp" "${files_json_file}"
}

# ---------------------------------------------------------------------------
# Fetch the repository's AGENTS.md file content for injection into the
# review prompt. The repo is already checked out, so read from the working
# directory root. The full file is loaded — the batch budget arithmetic
# accounts for its size automatically.
# Returns content via stdout, or empty string if not found.
# ---------------------------------------------------------------------------
function fetch_agents_md {
	local agents_file="${ROOT_DIRECTORY}/AGENTS.md"

	if [[ ! -f ${agents_file} ]]; then
		echo ""
		return
	fi

	cat "${agents_file}" 2>/dev/null || echo ""
}

# ---------------------------------------------------------------------------
# Call the Mistral Chat Completions API with a prompt. The prompt is written
# to a temp file and sent as an HTTP request body via curl, so there is no
# OS ARG_MAX limit on prompt size.
#
# JSON mode: requests response_format: json_object. The API returns the
#   assistant message content directly (no conversation array wrapper).
#   Markdown code fences are stripped and the content is validated as JSON.
#
# Text mode: returns the assistant message content as plain text.
# ---------------------------------------------------------------------------
function call_mistral_api {
	local mode="$1"
	local prompt="$2"
	local fallback="[]"

	if [[ ${mode} != "json" ]]; then
		fallback="No summary available."
	fi

	# Write the prompt to a temp file so jq can read it via --rawfile,
	# avoiding the OS ARG_MAX limit that occurs with --arg on large prompts.
	local prompt_file
	prompt_file=$(mktemp)
	printf '%s' "${prompt}" >"${prompt_file}"

	# Build the API request body in a temp file
	local request_file
	request_file=$(mktemp)

	if [[ ${mode} == "json" ]]; then
		jq --null-input \
			--arg model "${MISTRAL_MODEL}" \
			--rawfile prompt "${prompt_file}" \
			'{
				model: $model,
				messages: [{role: "user", content: $prompt}],
				response_format: {type: "json_object"}
			}' >"${request_file}"
	else
		jq --null-input \
			--arg model "${MISTRAL_MODEL}" \
			--rawfile prompt "${prompt_file}" \
			'{
				model: $model,
				messages: [{role: "user", content: $prompt}]
			}' >"${request_file}"
	fi
	rm --force "${prompt_file}"

	# Call the Mistral API with a 600-second timeout
	local http_code
	local response_file
	response_file=$(mktemp)
	local curl_exit_code=0

	http_code=$(timeout 600 curl --silent --show-error \
		--write-out '%{http_code}' \
		--output "${response_file}" \
		--header "Authorization: Bearer ${MISTRAL_API_KEY}" \
		--header "Content-Type: application/json" \
		--data "@${request_file}" \
		"${MISTRAL_API_URL}" 2>&1) || curl_exit_code=$?
	rm --force "${request_file}"

	# Log diagnostics on failure
	if [[ ${curl_exit_code} -ne 0 ]]; then
		print_error "Mistral API call failed with curl exit code ${curl_exit_code}"
		rm --force "${response_file}"
		echo "${fallback}"
		return
	fi

	if [[ ${http_code} -ne 200 ]]; then
		print_error "Mistral API returned HTTP ${http_code}: $(cat "${response_file}")"
		rm --force "${response_file}"
		echo "${fallback}"
		return
	fi

	# Extract the assistant message content from the API response
	local content
	content=$(jq --raw-output '.choices[0].message.content // empty' "${response_file}" 2>/dev/null || echo "")
	rm --force "${response_file}"

	if [[ -z ${content} ]]; then
		print_error "Mistral API returned empty content (mode=${mode})"
		echo "${fallback}"
		return
	fi

	if [[ ${mode} == "json" ]]; then
		# Strip markdown code fences that models sometimes wrap JSON in
		content=$(printf '%s\n' "${content}" | sed '/^```/d')

		# Validate the content is valid JSON and extract the results array.
		# The prompt asks for {"results": [...]}, but the model may return
		# a bare array. Handle both cases.
		if echo "${content}" | jq --exit-status 'type == "object" or type == "array"' >/dev/null 2>&1; then
			# If it is an object with a results key, extract the array
			local extracted_array
			extracted_array=$(echo "${content}" | jq 'if type == "object" and has("results") then .results else . end' 2>/dev/null || echo "[]")
			echo "${extracted_array}"
			return 0
		fi

		# Recovery: the model may have embedded a JSON array inside
		# conversational text. Try to extract the first top-level JSON
		# structure from the response.
		local embedded
		embedded=$(printf '%s\n' "${content}" | sed -n '/^[\[{]/,/^[\]}]/p' | jq --exit-status '.' 2>/dev/null || echo "")
		if [[ -n ${embedded} ]] && echo "${embedded}" | jq --exit-status 'type == "object" or type == "array"' >/dev/null 2>&1; then
			print_information "Recovered JSON from conversational response"
			local recovered
			recovered=$(echo "${embedded}" | jq 'if type == "object" and has("results") then .results else . end' 2>/dev/null || echo "[]")
			echo "${recovered}"
			return 0
		fi

		# Recovery: retry once — the model occasionally ignores the JSON
		# format instruction on the first attempt
		print_information "API response was not valid JSON, retrying once (first 200 chars: ${content:0:200})"

		local retry_prompt_file
		retry_prompt_file=$(mktemp)
		printf '%s' "${prompt}" >"${retry_prompt_file}"

		local retry_request_file
		retry_request_file=$(mktemp)
		jq --null-input \
			--arg model "${MISTRAL_MODEL}" \
			--rawfile prompt "${retry_prompt_file}" \
			'{
				model: $model,
				messages: [{role: "user", content: $prompt}],
				response_format: {type: "json_object"}
			}' >"${retry_request_file}"
		rm --force "${retry_prompt_file}"

		local retry_response_file
		retry_response_file=$(mktemp)
		local retry_http_code
		local retry_exit_code=0

		retry_http_code=$(timeout 600 curl --silent --show-error \
			--write-out '%{http_code}' \
			--output "${retry_response_file}" \
			--header "Authorization: Bearer ${MISTRAL_API_KEY}" \
			--header "Content-Type: application/json" \
			--data "@${retry_request_file}" \
			"${MISTRAL_API_URL}" 2>&1) || retry_exit_code=$?
		rm --force "${retry_request_file}"

		if [[ ${retry_exit_code} -eq 0 && ${retry_http_code} -eq 200 ]]; then
			local retry_content
			retry_content=$(jq --raw-output '.choices[0].message.content // empty' "${retry_response_file}" 2>/dev/null || echo "")

			if [[ -n ${retry_content} ]]; then
				retry_content=$(printf '%s\n' "${retry_content}" | sed '/^```/d')
			fi

			if echo "${retry_content}" | jq --exit-status 'type == "array" or type == "object"' >/dev/null 2>&1; then
				print_information "Retry succeeded, got valid JSON response"
				rm --force "${retry_response_file}"
				echo "${retry_content}" | jq 'if type == "object" and has("results") then .results else . end'
				return 0
			fi
		fi
		rm --force "${retry_response_file}"

		print_error "API response is not valid JSON after retry, falling back to empty array"
		echo "[]"
	else
		# Text mode: return the content directly
		echo "${content}"
	fi
}

# ---------------------------------------------------------------------------
# Transform the mapped review result into a flat array of line-level comments
# suitable for posting to the GitHub PR review API. Only includes issues
# that are on diff lines (in_diff == true). Uses mapped_line for accurate
# positioning and adds side: "RIGHT" for all comments.
# ---------------------------------------------------------------------------
function build_line_comments {
	local batch_result="$1"

	# Ensure the input is a valid JSON array
	if ! echo "${batch_result}" | jq --exit-status 'type == "array"' >/dev/null 2>&1; then
		echo "[]"
		return
	fi

	# Flatten file-level issues into individual comment objects.
	# Only issues with in_diff == true and a non-empty code_snippet are included.
	# Uses mapped_line for the line position and adds side: "RIGHT".
	# Multi-line comments use start_line + start_side when available.
	# Format: category label, severity, message, diff block showing offending
	# code with - prefix, and a collapsible agent prompt at the bottom.
	echo "${batch_result}" | jq --compact-output '
		[.[] | . as $file |
			(.issues // [])[] |
			select(.code_snippet != null and .code_snippet != "") |
			select(.in_diff == true) |
			(.category // "Review") as $category |
			(.message | split(". ") | .[0] | if endswith(".") then . else . + "." end) as $title |
			(.code_snippet | split("\n") | map("- " + .) | join("\n")) as $diff_lines |
			{
				path: $file.file_path,
				body: (
					"**\($category)** (\(.severity // "info"))\n\n" +
					"**\($title)**\n\n" +
					"\(.message)\n\n" +
					"```diff\n\($diff_lines)\n```\n\n" +
					"<details>\n<summary>Agent prompt</summary>\n\n" +
					"In `\($file.file_path)` at line \(.mapped_line): \(.message)\n\n" +
					"</details>"
				),
				line: .mapped_line,
				side: "RIGHT"
			} +
			(if .mapped_start_line != null and .mapped_start_line != .mapped_line then
				{start_line: .mapped_start_line, start_side: "RIGHT"}
			else {} end)
		]
	' 2>/dev/null || echo "[]"
}

# ---------------------------------------------------------------------------
# Validate the batch review result against the actual file contents. Two
# programmatic filters catch hallucinations that the code_snippet non-empty
# check alone cannot:
#
# 1. code_snippet must appear verbatim in the source file — catches complete
#    fabrications where the model invents file paths, code, or both
# 2. Issues flagging GitHub Actions secrets references (${{ secrets.* }}) as
#    "hardcoded" or "exposed" are false positives — the secrets syntax is the
#    correct way to reference credentials
#
# Returns a cleaned batch result with fabricated issues removed.
# ---------------------------------------------------------------------------
function validate_batch_result {
	local batch_result="$1"
	local files_json_file="$2"

	# Ensure the input is a valid JSON array
	if ! echo "${batch_result}" | jq --exit-status 'type == "array"' >/dev/null 2>&1; then
		echo "[]"
		return
	fi

	# Validate each issue against the actual source file content
	echo "${batch_result}" | jq --slurpfile files "${files_json_file}" '
		[.[] | . as $entry |
			($files[0] // [] | map(select(.path == $entry.file_path)) | .[0] // null) as $source |
			{
				file_path: $entry.file_path,
				issues: [
					($entry.issues // [])[] |
					. as $issue |
					select(
						$issue.code_snippet != null and
						$issue.code_snippet != "" and
						$source != null and
						($source.content | contains($issue.code_snippet)) and
						(
							(($issue.code_snippet | test("\\$\\{\\{\\s*secrets\\.")) and
							 ($issue.message | test("hardcoded|exposed|leak|credential|private.key"; "i")))
							| not
						)
					)
				]
			}
		]
	' 2>/dev/null || echo "${batch_result}"
}

# ---------------------------------------------------------------------------
# Resolve all review threads started by github-actions[bot] on a pull
# request. Uses the GraphQL API since thread resolution is not available
# via REST. Threads are resolved before comments are deleted so that
# conversations collapse in the PR UI.
# ---------------------------------------------------------------------------
function resolve_bot_threads {
	local pr_number="$1"
	local owner="${GITHUB_REPOSITORY%%/*}"
	local repo="${GITHUB_REPOSITORY##*/}"

	# GraphQL query to fetch all review threads with first comment author.
	# Stored in a variable via heredoc to avoid SC2016 (GraphQL $var syntax
	# looks like shell expansion inside single quotes).
	local threads_query
	threads_query=$(
		cat <<-'GRAPHQL'
			query($owner: String!, $name: String!, $number: Int!) {
				repository(owner: $owner, name: $name) {
					pullRequest(number: $number) {
						reviewThreads(first: 100) {
							nodes {
								id
								isResolved
								comments(first: 1) {
									nodes {
										author {
											login
										}
									}
								}
							}
						}
					}
				}
			}
		GRAPHQL
	)

	# Fetch all review threads on the PR with the author of the first comment
	local threads_response
	if ! threads_response=$(gh_api_with_retry graphql \
		-f owner="${owner}" \
		-f name="${repo}" \
		-F number="${pr_number}" \
		-f query="${threads_query}"); then
		print_information "Could not fetch review threads, skipping resolution"
		return 0
	fi

	# Extract unresolved thread IDs where the first comment is from the bot
	local thread_ids
	thread_ids=$(echo "${threads_response}" | jq --raw-output '
		[.data.repository.pullRequest.reviewThreads.nodes[] |
		 select(.isResolved == false) |
		 select(.comments.nodes[0].author.login == "github-actions[bot]")] |
		.[].id
	' 2>/dev/null || echo "")

	if [[ -z ${thread_ids} ]]; then
		return 0
	fi

	# GraphQL mutation to resolve a single review thread
	local resolve_mutation
	resolve_mutation=$(
		cat <<-'GRAPHQL'
			mutation($threadId: ID!) {
				resolveReviewThread(input: {threadId: $threadId}) {
					thread { isResolved }
				}
			}
		GRAPHQL
	)

	# Resolve each bot thread so conversations collapse in the PR UI
	for thread_id in ${thread_ids}; do
		if gh api graphql \
			-f threadId="${thread_id}" \
			-f query="${resolve_mutation}" >/dev/null 2>&1; then
			print_information "Resolved review thread ${thread_id}"
		else
			print_information "Could not resolve thread ${thread_id}, continuing"
		fi
	done
}

# ---------------------------------------------------------------------------
# Delete all review comments by github-actions[bot] on a pull request.
# Removes stale line comments from previous review runs so that each new
# review starts with a clean PR.
# ---------------------------------------------------------------------------
function delete_bot_comments {
	local pr_number="$1"

	# Fetch review comments on the PR
	local comments
	if ! comments=$(gh_api_with_retry "repos/${GITHUB_REPOSITORY}/pulls/${pr_number}/comments?per_page=100"); then
		print_information "Could not fetch review comments, skipping deletion"
		return 0
	fi

	# Extract comment IDs from github-actions[bot]
	local comment_ids
	comment_ids=$(echo "${comments}" | jq --raw-output '
		[.[] | select(.user.login == "github-actions[bot]")] | .[].id
	' 2>/dev/null || echo "")

	if [[ -z ${comment_ids} ]]; then
		return 0
	fi

	# Delete each bot comment to remove stale line-level feedback
	for comment_id in ${comment_ids}; do
		if gh api --method DELETE \
			"repos/${GITHUB_REPOSITORY}/pulls/comments/${comment_id}" >/dev/null 2>&1; then
			print_information "Deleted review comment #${comment_id}"
		else
			print_information "Could not delete comment #${comment_id}, continuing"
		fi
	done
}

# ---------------------------------------------------------------------------
# Dismiss previous automated reviews on a pull request. Fetches all reviews
# by github-actions[bot] with CHANGES_REQUESTED state and dismisses them
# so they do not block merging after a new review is posted.
# ---------------------------------------------------------------------------
function dismiss_old_reviews {
	local pr_number="$1"

	# Fetch all reviews on the PR
	local reviews
	if ! reviews=$(gh_api_with_retry "repos/${GITHUB_REPOSITORY}/pulls/${pr_number}/reviews"); then
		print_information "Could not fetch existing reviews, skipping dismissal"
		return 0
	fi

	# Find review IDs from the bot that have requested changes
	local review_ids
	review_ids=$(echo "${reviews}" | jq --raw-output '
		[.[] | select(.user.login == "github-actions[bot]") |
		 select(.state == "CHANGES_REQUESTED")] | .[].id
	' 2>/dev/null || echo "")

	# Dismiss each stale review so it no longer blocks the PR
	for review_id in ${review_ids}; do
		if gh api --method PUT \
			"repos/${GITHUB_REPOSITORY}/pulls/${pr_number}/reviews/${review_id}/dismissals" \
			--field message="Superseded by new automated review" >/dev/null 2>&1; then
			print_information "Dismissed old review #${review_id}"
		else
			print_information "Could not dismiss review #${review_id}, continuing"
		fi
	done
}

# ---------------------------------------------------------------------------
# Submit review results to a GitHub pull request using the Reviews API.
#
# Posts a single review containing both the summary body and any line-level
# comments. This avoids the 422 errors that occur when posting individual
# review comments, since the Reviews API bundles everything in one call.
#
# If posting with line comments fails (e.g. comments reference lines not
# in the diff), falls back to a summary-only review.
#
# Before posting, cleans up previous bot reviews: resolves threads,
# deletes line comments, and dismisses blocking reviews.
# ---------------------------------------------------------------------------
function process_results_github {
	local comment_count="$1"
	local has_critical="$2"
	local summary_text="$3"
	local all_comments="$4"

	# Clean up previous bot reviews: resolve threads, delete comments,
	# and dismiss blocking reviews before posting a new one
	resolve_bot_threads "${GITHUB_PULL_REQUEST_NUMBER}"
	delete_bot_comments "${GITHUB_PULL_REQUEST_NUMBER}"
	dismiss_old_reviews "${GITHUB_PULL_REQUEST_NUMBER}"

	# Determine the review event: only request changes for confirmed critical
	# security issues (not errors, which may stem from stale model knowledge).
	local event="COMMENT"
	local flag="--comment"
	if [[ ${has_critical} == true && ${comment_count} -gt 0 ]]; then
		event="REQUEST_CHANGES"
		flag="--request-changes"
	fi

	# Attempt to post a review with line comments via the Reviews API
	if [[ ${comment_count} -gt 0 ]]; then
		print_information "Posting ${comment_count} line comments to GitHub"

		# Fetch the HEAD SHA of the PR for the review commit reference
		local head_sha
		head_sha=$(gh_api_with_retry "repos/${GITHUB_REPOSITORY}/pulls/${GITHUB_PULL_REQUEST_NUMBER}" | jq --raw-output '.head.sha' 2>/dev/null || echo "")

		if [[ -n ${head_sha} ]]; then
			# Build the review payload with line comments and summary
			local payload
			payload=$(jq --null-input \
				--arg body "${summary_text}" \
				--arg event "${event}" \
				--arg sha "${head_sha}" \
				--argjson comments "${all_comments}" \
				'{commit_id: $sha, body: $body, event: $event, comments: $comments}')

			# Post the review; if it succeeds we are done
			if echo "${payload}" | gh api --method POST \
				"repos/${GITHUB_REPOSITORY}/pulls/${GITHUB_PULL_REQUEST_NUMBER}/reviews" \
				--input - >/dev/null 2>&1; then
				print_information "Posted review with comments to PR #${GITHUB_PULL_REQUEST_NUMBER}"
				return 0
			fi

			# Line comments may reference lines outside the diff — fall back
			print_information "Failed to post review with line comments, posting summary only"
		fi
	fi

	# Fallback: post a summary-only review via the CLI
	gh pr review "${GITHUB_PULL_REQUEST_NUMBER}" "${flag}" --body "${summary_text}"
	print_information "Posted comment to PR #${GITHUB_PULL_REQUEST_NUMBER}"
}

# ---------------------------------------------------------------------------
# Display review results locally in the terminal — used when running
# outside of GitHub Actions for development and testing.
# ---------------------------------------------------------------------------
function process_results_local {
	local comment_count="$1"
	local has_critical="$2"
	local summary_text="$3"
	local all_comments="$4"

	# Display issue summary with severity indicator
	if [[ ${comment_count} -gt 0 ]]; then
		print_information "Found ${comment_count} issues:"
		if [[ ${has_critical} == true ]]; then
			print_information "❌ CRITICAL ISSUES FOUND"
		else
			print_information "⚠️ Issues found"
		fi

		# Print each issue with its file path, line number, and description
		echo "${all_comments}" | jq --raw-output '.[] | "  \(.path):\(.line) - \(.body)"'
	else
		print_information "✅ No issues found!"
	fi

	# Print the full review summary
	printf "\n--- Review Summary ---\n"
	echo "${summary_text}"
}

# ---------------------------------------------------------------------------
# Load the contents of all changed files into a JSON array for batch
# processing. Skips files that do not exist or exceed the size limit.
# ---------------------------------------------------------------------------
function load_file_contents {
	local files="$1"
	local output_file="$2"
	local entries_file
	entries_file=$(mktemp)

	# Build individual JSON objects per file, then combine once at the end.
	# This avoids re-parsing the growing array on every iteration.
	# File content is read via --rawfile to avoid hitting the OS ARG_MAX
	# limit that occurs when large file content is passed via --arg.
	while IFS= read -r file; do
		if [[ ! -f ${file} ]]; then
			continue
		fi

		# Enforce the file size limit to avoid overloading the review model
		local file_size
		file_size=$(wc --bytes <"${file}" | tr --delete ' ')
		if [[ ${file_size} -gt ${MAX_FILE_SIZE_BYTES} ]]; then
			print_information "Skipping ${file} (${file_size} bytes exceeds ${MAX_FILE_SIZE_BYTES} byte limit)"
			continue
		fi

		jq --null-input --arg path "${file}" --rawfile content "${file}" '{path: $path, content: $content}' >>"${entries_file}"
	done < <(echo "${files}")

	# Combine all entries into a single JSON array and write to the output file
	if [[ -s ${entries_file} ]]; then
		jq --slurp '.' "${entries_file}" >"${output_file}"
	else
		echo "[]" >"${output_file}"
	fi
	rm --force "${entries_file}"
}

# ---------------------------------------------------------------------------
# Build the review prompt template. Accepts a JSON array of files as $1
# and optional AGENTS.md content as $2 for project-specific conventions.
# Returns the complete prompt string for the Mistral API. Each file entry
# includes path, content, and diff fields.
# ---------------------------------------------------------------------------
function build_review_prompt {
	local batch_json="$1"
	local agents_md_content="${2:-}"

	# Inject AGENTS.md project conventions when available
	local agents_section=""
	if [[ -n ${agents_md_content} ]]; then
		agents_section="
PROJECT CONVENTIONS (from the repository's AGENTS.md — you MUST respect these):
${agents_md_content}

When reviewing code, respect these project-specific conventions and rules. Do NOT flag code that follows these conventions as an issue.

"
	fi

	printf '%s' "${REVIEW_PREAMBLE}
${agents_section}
INPUT DATA STRUCTURE:
[
  {
    \"path\": \"filename.ext\",
    \"content\": \"complete file contents\",
    \"diff\": \"unified diff patch showing what changed in this PR\"
  }
]

The diff field contains the unified diff for each file. Lines prefixed with + are additions, lines prefixed with - are deletions, and lines prefixed with a space are context. Focus your review on the lines shown in the diff (prefixed with + for additions). The full file content is provided for context only. Do NOT report issues for code that was not changed in this PR unless it is directly affected by the changes.

RESPONSE FORMAT:
You MUST respond with ONLY valid JSON — no markdown, no explanation, no text before or after the JSON. Do NOT wrap the JSON in code fences. Your entire response must be parseable by a JSON parser.

You MUST return a JSON object with a single key \"results\" containing an array. Each array entry represents one reviewed file. If a file has no issues, include it with an empty issues array.

OUTPUT DATA STRUCTURE (JSON object):
{
  \"results\": [
    {
      \"file_path\": \"filename.ext\",
      \"issues\": [
        {
          \"line\": <line_number>,
          \"message\": \"clear description of the actual issue\",
          \"severity\": \"info|warning|error|critical\",
          \"code_snippet\": \"the exact code from the file that proves this issue — copy-paste verbatim\",
          \"category\": \"Bug|Security|Performance|Refactor|Style|Documentation\"
        }
      ]
    }
  ]
}

IMPORTANT:
- Every issue MUST have a non-empty code_snippet field with the exact code from the file. Issues without code_snippet will be automatically discarded.
- ONLY review the files provided below. Do NOT reference, comment on, or report issues for any other files in the project. Your review scope is strictly limited to the files listed here.

If a file has no issues, return it as: {\"file_path\": \"filename.ext\", \"issues\": []}

FILES TO REVIEW:
${batch_json}"
}

# ---------------------------------------------------------------------------
# Send file contents to the Mistral API for batch review. Splits files into
# batches by content size to keep token counts reasonable and avoid
# excessive API response times on large PRs. Results from all batches are
# merged into a single JSON array.
# ---------------------------------------------------------------------------
function review_files {
	local files_json_file="$1"
	local agents_md_content="${2:-}"

	local total_files
	total_files=$(jq 'length' "${files_json_file}")

	if [[ ${total_files} -eq 0 ]]; then
		echo "[]"
		return
	fi

	# Adjust batch budget to account for AGENTS.md overhead in the prompt.
	# The 50KB headroom covers the prompt template, JSON encoding, and
	# environment variable overhead.
	local agents_md_size=${#agents_md_content}
	local effective_budget=$((MAX_BATCH_CONTENT_BYTES - agents_md_size - 50000))
	if [[ ${effective_budget} -lt 100000 ]]; then
		effective_budget=100000
	fi

	# Get the content size of each file entry (one size per line)
	local content_sizes
	content_sizes=$(jq '.[].content | length' "${files_json_file}")

	# Determine batch boundaries based on cumulative content size
	local batch_start=0
	local results_file
	results_file=$(mktemp)

	while [[ ${batch_start} -lt ${total_files} ]]; do
		local batch_end=${batch_start}
		local batch_size=0
		local line_index=0

		# Walk the sizes list to find where this batch should end
		while IFS= read -r entry_size; do
			# Skip entries before the batch start
			if [[ ${line_index} -lt ${batch_start} ]]; then
				line_index=$((line_index + 1))
				continue
			fi

			# Start a new batch if adding this file would exceed the limit
			# (but always include at least one file per batch)
			if [[ $((batch_size + entry_size)) -gt ${effective_budget} && ${batch_end} -gt ${batch_start} ]]; then
				break
			fi

			batch_size=$((batch_size + entry_size))
			batch_end=$((batch_end + 1))
			line_index=$((line_index + 1))
		done <<<"${content_sizes}"

		local batch_file_count=$((batch_end - batch_start))

		# Extract this batch slice from the full file array
		local batch_json
		batch_json=$(jq ".[${batch_start}:${batch_end}]" "${files_json_file}")

		# Log batch details when splitting across multiple batches
		if [[ ${batch_start} -gt 0 || ${batch_end} -lt ${total_files} ]]; then
			print_information "Reviewing batch of ${batch_file_count} files (${batch_size} bytes of content)"
		fi

		# Build the prompt and call the Mistral API
		local batch_prompt
		batch_prompt=$(build_review_prompt "${batch_json}" "${agents_md_content}")
		local batch_result
		batch_result=$(call_mistral_api "json" "${batch_prompt}")

		# Append this batch's results for later merging
		echo "${batch_result}" >>"${results_file}"

		batch_start=${batch_end}
	done

	# Merge all batch results into a single JSON array
	jq --slurp 'add // []' "${results_file}"
	rm --force "${results_file}"
}

# ---------------------------------------------------------------------------
# Build the Changes table programmatically from the actual file list.
# This is deterministic — the model cannot hallucinate file names.
# ---------------------------------------------------------------------------
function build_changes_table {
	local pr_files_json="$1"

	local table_header="| File | Status |
|------|--------|"

	local table_rows
	table_rows=$(jq --raw-output '
		.[] | "| `\(.filename)` | \(.status) |"
	' "${pr_files_json}" 2>/dev/null || echo "")

	if [[ -z ${table_rows} ]]; then
		echo "${table_header}
| — | No files found |"
	else
		printf '%s\n%s' "${table_header}" "${table_rows}"
	fi
}

# ---------------------------------------------------------------------------
# Extract issues of a given severity from the validated result, formatted
# as a markdown bullet list. Returns empty string if no issues match.
# ---------------------------------------------------------------------------
function build_issue_list_by_severity {
	local validated_result="$1"
	local severity="$2"

	echo "${validated_result}" | jq --raw-output --arg severity "${severity}" '
		[.[] | . as $file | (.issues // [])[] |
		 select(.code_snippet != null and .code_snippet != "") |
		 select(.severity == $severity) |
		 "- **`\($file.file_path):\(.line // 0)`** \u2014 \(.message)"] | .[]
	' 2>/dev/null || echo ""
}

# ---------------------------------------------------------------------------
# Generate a 1-2 paragraph walkthrough of the PR changes using the Mistral
# API. Receives only file names and diff patches (not full content) to keep
# the prompt small and focused. Falls back to a simple file count summary
# if the API call fails.
# ---------------------------------------------------------------------------
function generate_walkthrough {
	local pr_files_json="$1"

	local file_count
	file_count=$(jq 'length' "${pr_files_json}" 2>/dev/null || echo "0")

	# Build a condensed input to prevent the model from parroting code back:
	# - Added files: filename and status only (purpose is clear from the name)
	# - Modified files: hunk headers only (e.g. "@@ ... @@ function foo {")
	#   which show WHAT changed without exposing the full diff content
	local diff_summary
	diff_summary=$(jq --compact-output '[.[] | if .status == "added" then {filename, status} else {filename, status, hunks: ((.patch // "") | split("\n") | map(select(startswith("@@"))) | join("\n"))} end]' "${pr_files_json}" 2>/dev/null || echo "[]")

	# Programmatic fallback used when the API call fails
	local fallback
	fallback="This PR modifies ${file_count} file(s)."

	local walkthrough_prompt
	walkthrough_prompt="You are writing a short summary of a pull request for a code reviewer. Below are the changed files with their status and diffs. Write 1-2 short paragraphs.

Each file has a status field:
- \"added\": a new file introduced by this PR. Only the filename is provided — infer its purpose from the name.
- \"modified\": an existing file changed by this PR. The \"hunks\" field shows diff hunk headers indicating which sections/functions were changed, e.g. \"@@ -10,5 +10,8 @@ function foo {\" means the function foo was modified.

RULES:
1. Summarise the OVERALL PURPOSE of the PR in 1-2 sentences, then briefly note the key changes.
2. Do NOT describe how code works internally or list features the code provides. A reviewer can read the code.
3. Plain prose only — no bullet points, no numbered lists, no headings, no markdown.
4. Do NOT list file names — a separate table already shows them.
5. Use British English. Be concise. Maximum 2 paragraphs.

FILES:
${diff_summary}"

	local result
	result=$(call_mistral_api "text" "${walkthrough_prompt}")

	# Use the model output if it looks reasonable, otherwise fall back
	if [[ -n ${result} && ${result} != "No summary available." ]]; then
		echo "${result}"
	else
		echo "${fallback}"
	fi
}

# ---------------------------------------------------------------------------
# Build the core review summary. The walkthrough is generated by the
# model from diff data; the issues section is fully programmatic to
# prevent hallucination in actionable content.
#
# Sections:
#   1. Walkthrough — model-generated prose summary of the changes
#   2. Issues — grouped by severity from the validated review result
# ---------------------------------------------------------------------------
function generate_summary {
	local validated_result="$1"
	local pr_files_json="$2"

	# Walkthrough section — model-generated prose summary
	local walkthrough_text
	walkthrough_text=$(generate_walkthrough "${pr_files_json}")

	local walkthrough
	walkthrough="## Walkthrough

${walkthrough_text}"

	# Issues section — grouped by severity from validated result
	local total_issues
	total_issues=$(echo "${validated_result}" | jq '[.[]?.issues[]?] | length' 2>/dev/null || echo "0")

	local issues_section
	if [[ ${total_issues} -eq 0 ]]; then
		issues_section="## Issues

No issues were identified in the reviewed files."
	else
		# Build issue lists grouped by severity. Uses a helper function
		# to avoid repeating the jq filter for each severity level.
		local critical_items error_items warning_items info_items
		critical_items=$(build_issue_list_by_severity "${validated_result}" "critical")
		error_items=$(build_issue_list_by_severity "${validated_result}" "error")
		warning_items=$(build_issue_list_by_severity "${validated_result}" "warning")
		info_items=$(build_issue_list_by_severity "${validated_result}" "info")

		issues_section="## Issues

${total_issues} issue(s) identified."

		if [[ -n ${critical_items} ]]; then
			issues_section="${issues_section}

### Critical

${critical_items}"
		fi
		if [[ -n ${error_items} ]]; then
			issues_section="${issues_section}

### Error

${error_items}"
		fi
		if [[ -n ${warning_items} ]]; then
			issues_section="${issues_section}

### Warning

${warning_items}"
		fi
		if [[ -n ${info_items} ]]; then
			issues_section="${issues_section}

### Info

${info_items}"
		fi
	fi

	# Assemble the core summary (walkthrough + issues)
	printf '%s\n\n%s' "${walkthrough}" "${issues_section}"
}

# ---------------------------------------------------------------------------
# Build a collapsible nitpicks section from info-severity issues in the
# validated result. Returns the markdown block or empty string if no
# info-level issues exist.
# ---------------------------------------------------------------------------
function build_nitpicks_section {
	local validated_result="$1"

	# Extract info-severity issues with file path context
	local nitpick_items
	nitpick_items=$(echo "${validated_result}" | jq --raw-output '
		[.[] | . as $file |
			(.issues // [])[] |
			select(.severity == "info") |
			select(.code_snippet != null and .code_snippet != "") |
			"- **`\($file.file_path):\(.line // "?")`** — Minor: \(.message)"
		] | .[]
	' 2>/dev/null || echo "")

	if [[ -z ${nitpick_items} ]]; then
		return
	fi

	# Count the nitpick items
	local nitpick_count
	nitpick_count=$(echo "${nitpick_items}" | grep --count . || echo "0")

	cat <<NITPICKS

<details>
<summary>Nitpicks (${nitpick_count})</summary>

${nitpick_items}

</details>
NITPICKS
}

# ---------------------------------------------------------------------------
# Build a collapsible agent prompt section covering ALL issues from the
# validated result. Returns the markdown block or empty string if no
# issues exist.
# ---------------------------------------------------------------------------
function build_agent_prompt_section {
	local validated_result="$1"

	# Build numbered list of all issues with file path and severity
	local prompt_items
	prompt_items=$(echo "${validated_result}" | jq --raw-output '
		[.[] | . as $file |
			(.issues // [])[] |
			select(.code_snippet != null and .code_snippet != "") |
			{path: $file.file_path, line: (.line // "?"), severity: (.severity // "info"), message: .message}
		] | to_entries | .[] |
		"\(.key + 1). **`\(.value.path):\(.value.line)`** (\(.value.severity)) — \(.value.message)"
	' 2>/dev/null || echo "")

	if [[ -z ${prompt_items} ]]; then
		return
	fi

	cat <<AGENTPROMPT

<details>
<summary>Agent prompt</summary>

Please address the following code review findings:

${prompt_items}

</details>
AGENTPROMPT
}

# ---------------------------------------------------------------------------
# Build a collapsible review metadata section with deterministic statistics
# about the review run. Returns the markdown block.
# ---------------------------------------------------------------------------
function build_metadata_section {
	local files_reviewed="$1"
	local total_issues="$2"
	local critical_count="$3"
	local error_count="$4"
	local warning_count="$5"
	local info_count="$6"
	local in_diff_count="$7"
	local validated_count="$8"
	local raw_count="$9"

	# Build as a single string to avoid printf fragmentation issues.
	# GitHub requires a blank line after </summary> for content to render.
	cat <<METADATA

<details>
<summary>Review metadata</summary>

- **Model**: Devstral 2 (${MISTRAL_MODEL})
- **Files reviewed**: ${files_reviewed}
- **Issues found**: ${total_issues} (${critical_count} critical, ${error_count} error, ${warning_count} warning, ${info_count} info)
- **Issues on diff lines**: ${in_diff_count} of ${total_issues}
- **Source validation**: ${validated_count} of ${raw_count} issues verified against file contents

</details>
METADATA
}

# ---------------------------------------------------------------------------
# Route the review results to the appropriate output handler — GitHub PR
# review when running in CI, or local terminal output otherwise.
# ---------------------------------------------------------------------------
function submit_review {
	local comment_count="$1"
	local has_critical="$2"
	local summary_text="$3"
	local all_comments="$4"

	if [[ -n ${GITHUB_REPOSITORY:-} && -n ${GITHUB_PULL_REQUEST_NUMBER:-} ]]; then
		process_results_github "${comment_count}" "${has_critical}" "${summary_text}" "${all_comments}"
	else
		process_results_local "${comment_count}" "${has_critical}" "${summary_text}" "${all_comments}"
	fi
}

# ---------------------------------------------------------------------------
# Entry point: parse CLI arguments, authenticate, discover changed files,
# run the batch review, generate a summary, and submit the results.
# ---------------------------------------------------------------------------
function main {
	# Parse command-line options
	while [[ $# -gt 0 ]]; do
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

	# Ensure the root directory is set
	if [[ -z ${ROOT_DIRECTORY} ]]; then
		print_error "Error: ROOT_DIRECTORY is not set."
		return 2
	fi

	cd "$ROOT_DIRECTORY"

	# Authenticate with the Mistral API
	check_mistral_auth

	# Step 1: Discover changed files with diff data
	local pr_files_json
	pr_files_json=$(mktemp)
	if ! get_changed_files "${pr_files_json}"; then
		print_error "Failed to retrieve changed files"
		rm --force "${pr_files_json}"
		exit 1
	fi

	# Extract filenames from the PR files JSON
	local files
	files=$(jq --raw-output '.[].filename' "${pr_files_json}" 2>/dev/null || echo "")

	if [[ -z ${files} ]]; then
		print_information "No files to review"
		rm --force "${pr_files_json}"
		exit 0
	fi

	print_information "Found $(echo "${files}" | grep --count .) files to review"

	# Step 2: Load file contents into a JSON temp file for batch processing.
	# Temp files are used throughout to avoid hitting the OS ARG_MAX limit
	# (~2MB on Linux) when PRs contain many files.
	local files_json_file
	files_json_file=$(mktemp)
	load_file_contents "${files}" "${files_json_file}"

	local loaded_count
	loaded_count=$(jq 'length' "${files_json_file}" 2>/dev/null || echo "0")
	print_information "Loaded ${loaded_count} files for review"

	# Step 2b: Merge diff patch data into loaded file entries so the model
	# receives both file content and the specific changes for each file
	merge_diff_data "${files_json_file}" "${pr_files_json}"

	# Step 2c: Fetch AGENTS.md for project-specific convention injection
	local agents_md_content
	agents_md_content=$(fetch_agents_md)
	if [[ -n ${agents_md_content} ]]; then
		print_information "Loaded AGENTS.md (${#agents_md_content} characters) for review context"
	fi

	# Step 3: Review files via the Mistral API (batched for large PRs)
	print_information "Reviewing all files with Mistral API"
	local batch_result
	batch_result=$(review_files "${files_json_file}" "${agents_md_content}")

	# Log the batch review result size for diagnostics
	local batch_issue_count
	batch_issue_count=$(echo "${batch_result}" | jq '[.[]?.issues[]?] | length' 2>/dev/null || echo "0")
	print_information "Batch review returned ${batch_issue_count} issues across $(echo "${batch_result}" | jq 'length' 2>/dev/null || echo "0") file entries"

	# Step 3b: Validate issues against actual file contents — catches
	# fabricated code snippets, invented file paths, and false positives
	# about GitHub Actions secrets references
	local validated_result
	validated_result=$(validate_batch_result "${batch_result}" "${files_json_file}")

	local validated_issue_count
	validated_issue_count=$(echo "${validated_result}" | jq '[.[]?.issues[]?] | length' 2>/dev/null || echo "0")
	print_information "After source validation: ${validated_issue_count} of ${batch_issue_count} issues verified against file contents"

	# Step 4: Build diff line map and map issues to diff positions
	local diff_map_file
	diff_map_file=$(mktemp)
	parse_diff_hunks "${pr_files_json}" "${diff_map_file}"

	local mapped_result
	mapped_result=$(map_issues_to_diff "${validated_result}" "${files_json_file}" "${diff_map_file}")

	# Log how many issues landed on diff lines
	local in_diff_count
	in_diff_count=$(echo "${mapped_result}" | jq '[.[]?.issues[]? | select(.in_diff == true)] | length' 2>/dev/null || echo "0")
	print_information "Issues on diff lines: ${in_diff_count} of ${validated_issue_count}"

	# Derive line comments from mapped result (only in-diff issues)
	local all_comments
	all_comments=$(build_line_comments "${mapped_result}")

	local comment_count
	comment_count=$(echo "${all_comments}" | jq 'length' 2>/dev/null || echo "0")
	print_information "After diff mapping and code_snippet filter: ${comment_count} comments for line-level posting"

	# Only flag as critical for confirmed critical-severity issues; errors may
	# stem from stale model knowledge and should not trigger change requests
	local has_critical
	has_critical=$(echo "${mapped_result}" | jq '[.[]?.issues[]? | select(.severity == "critical") | select(.code_snippet != null and .code_snippet != "")] | length > 0' 2>/dev/null || echo "false")

	# Step 5: Generate the review summary and append programmatic sections.
	# The changes table is built programmatically from the actual file list
	# to prevent the model from hallucinating file names. The model only
	# generates the walkthrough and issues sections.
	print_information "Generating text summary for review comment"
	local changes_table
	changes_table=$(build_changes_table "${pr_files_json}")
	local summary_text
	summary_text=$(generate_summary "${validated_result}" "${pr_files_json}")

	# Append Feedback section (nitpicks + agent prompt) if either exists
	local nitpicks_section
	nitpicks_section=$(build_nitpicks_section "${mapped_result}")
	local agent_prompt_section
	agent_prompt_section=$(build_agent_prompt_section "${mapped_result}")

	if [[ -n ${nitpicks_section} || -n ${agent_prompt_section} ]]; then
		summary_text="${summary_text}

## Feedback"
		if [[ -n ${nitpicks_section} ]]; then
			summary_text="${summary_text}${nitpicks_section}"
		fi
		if [[ -n ${agent_prompt_section} ]]; then
			summary_text="${summary_text}${agent_prompt_section}"
		fi
	fi

	# Append Metadata section (changes table + review statistics)
	local critical_count error_count warning_count info_count
	critical_count=$(echo "${mapped_result}" | jq '[.[]?.issues[]? | select(.severity == "critical")] | length' 2>/dev/null || echo "0")
	error_count=$(echo "${mapped_result}" | jq '[.[]?.issues[]? | select(.severity == "error")] | length' 2>/dev/null || echo "0")
	warning_count=$(echo "${mapped_result}" | jq '[.[]?.issues[]? | select(.severity == "warning")] | length' 2>/dev/null || echo "0")
	info_count=$(echo "${mapped_result}" | jq '[.[]?.issues[]? | select(.severity == "info")] | length' 2>/dev/null || echo "0")

	local metadata_section
	metadata_section=$(build_metadata_section \
		"${loaded_count}" \
		"${validated_issue_count}" \
		"${critical_count}" \
		"${error_count}" \
		"${warning_count}" \
		"${info_count}" \
		"${in_diff_count}" \
		"${validated_issue_count}" \
		"${batch_issue_count}")

	summary_text="${summary_text}

## Metadata

<details>
<summary>Changes</summary>

${changes_table}

</details>
${metadata_section}"

	# Step 6: Submit the review with line comments and summary
	submit_review "${comment_count}" "${has_critical}" "${summary_text}" "${all_comments}"

	# Clean up all temp files
	rm --force "${pr_files_json}" "${files_json_file}" "${diff_map_file}"
}

main "$@"
exit 0
