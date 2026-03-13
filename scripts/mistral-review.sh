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
# Configuration — maximum file size for review and the system prompt that
# instructs the Vibe CLI how to analyse code.
# ---------------------------------------------------------------------------
readonly MAX_FILE_SIZE_BYTES=500000

# Maximum total content size per Vibe CLI batch (bytes). Each batch prompt
# must fit within the OS ARG_MAX limit (~2MB on Linux). We use 1MB as the
# threshold to leave headroom for the prompt template, environment variables,
# and JSON encoding overhead.
readonly MAX_BATCH_CONTENT_BYTES=1000000
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
	printf "Reviews code using Mistral Vibe CLI.\n"
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

	# Attempt to read the key from the Vibe CLI env file
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
# Retrieve the list of changed files to review. In GitHub Actions, fetches
# the file list from the PR API; locally, uses git diff against main.
# ---------------------------------------------------------------------------
function get_changed_files {
	if [[ -n ${GITHUB_REPOSITORY:-} && -n ${GITHUB_PULL_REQUEST_NUMBER:-} ]]; then
		# Running in GitHub Actions — fetch changed files from the PR API
		validate_github_env

		local api_response
		if ! api_response=$(gh_api_with_retry --paginate "repos/${GITHUB_REPOSITORY}/pulls/${GITHUB_PULL_REQUEST_NUMBER}/files"); then
			print_error "Failed to fetch changed files from GitHub API"
			return 1
		fi

		# Filter to only modified or added files
		echo "${api_response}" | jq --raw-output '
			.[] | select(.status == "modified" or .status == "added") | .filename
		' 2>/dev/null || {
			print_error "Failed to parse changed files response"
			return 1
		}
	else
		# Running locally — use git diff to find changes since main
		git diff --name-only main HEAD 2>/dev/null || echo ""
	fi
}

# ---------------------------------------------------------------------------
# Invoke the Vibe CLI with a prompt and optional output mode. Applies a
# 600-second timeout and falls back to a safe default on failure.
#
# JSON mode (--output json): vibe returns a conversation array of
#   {role, content} objects. The last assistant message is extracted,
#   markdown code fences are stripped, and the content is validated as JSON.
#
# Text mode (default): vibe returns plain text directly.
# ---------------------------------------------------------------------------
function invoke_vibe {
	local mode="$1"
	local prompt="$2"
	local args=()
	local fallback="[]"

	# When requesting JSON output, add the --output flag
	if [[ ${mode} == "json" ]]; then
		args+=(--output json)
	else
		fallback="No summary available."
	fi

	# Execute the Vibe CLI with a 600-second timeout.
	# Callers must ensure the prompt fits within the OS ARG_MAX limit
	# (~2MB on Linux) — the review_files function handles this via batching.
	# Stderr is captured separately for diagnostics rather than discarded.
	local result
	local vibe_stderr
	local vibe_exit_code=0
	vibe_stderr=$(mktemp)
	result=$(timeout 600 vibe --prompt "${prompt}" "${args[@]}" 2>"${vibe_stderr}") || vibe_exit_code=$?

	# Log diagnostics when vibe fails or returns empty output.
	# These messages must go to stderr (>&2) because this function is called
	# inside command substitutions, where stdout is captured into a variable.
	if [[ ${vibe_exit_code} -ne 0 ]]; then
		print_error "Vibe CLI exited with code ${vibe_exit_code} (mode=${mode})"
		if [[ -s ${vibe_stderr} ]]; then
			print_error "Vibe CLI stderr: $(cat "${vibe_stderr}")"
		fi
		if [[ -n ${result} ]]; then
			print_error "Vibe CLI stdout: ${result}"
		fi
		result="${fallback}"
	elif [[ -z ${result} ]]; then
		print_error "Vibe CLI returned empty output (mode=${mode})"
		result="${fallback}"
	fi
	rm --force "${vibe_stderr}"

	if [[ ${mode} == "json" ]]; then
		# JSON mode: extract the last assistant message from the conversation array
		local extracted
		extracted=$(echo "${result}" | jq --raw-output '
			[.[] | select(.role == "assistant")] | last | .content // empty
		' 2>/dev/null || echo "")

		if [[ -z ${extracted} ]]; then
			print_error "Failed to extract assistant message from Vibe response"
		fi

		# Strip markdown code fences that models often wrap JSON responses in
		if [[ -n ${extracted} ]]; then
			extracted=$(printf '%s\n' "${extracted}" | sed '/^```/d')
		fi

		# Validate the extracted content is valid JSON
		if echo "${extracted}" | jq --exit-status 'type == "array" or type == "object"' >/dev/null 2>&1; then
			echo "${extracted}"
			return 0
		fi

		# Recovery: the model may have embedded a JSON array inside conversational
		# text. Try to extract the first top-level JSON array from the response.
		if [[ -n ${extracted} ]]; then
			local embedded
			embedded=$(printf '%s\n' "${extracted}" | sed -n '/^\[/,/^\]/p' | jq --exit-status '.' 2>/dev/null || echo "")
			if [[ -n ${embedded} ]] && echo "${embedded}" | jq --exit-status 'type == "array"' >/dev/null 2>&1; then
				print_information "Recovered JSON array from conversational response"
				echo "${embedded}"
				return 0
			fi
		fi

		# Recovery: retry once — the model occasionally ignores the JSON format
		# instruction on the first attempt but usually complies on a second try.
		print_information "Vibe response was not valid JSON, retrying once (first 200 chars: ${extracted:0:200})"
		local retry_result
		local retry_stderr
		local retry_exit_code=0
		retry_stderr=$(mktemp)
		retry_result=$(timeout 600 vibe --prompt "${prompt}" "${args[@]}" 2>"${retry_stderr}") || retry_exit_code=$?
		rm --force "${retry_stderr}"

		if [[ ${retry_exit_code} -eq 0 && -n ${retry_result} ]]; then
			local retry_extracted
			retry_extracted=$(echo "${retry_result}" | jq --raw-output '
				[.[] | select(.role == "assistant")] | last | .content // empty
			' 2>/dev/null || echo "")

			if [[ -n ${retry_extracted} ]]; then
				retry_extracted=$(printf '%s\n' "${retry_extracted}" | sed '/^```/d')
			fi

			if echo "${retry_extracted}" | jq --exit-status 'type == "array" or type == "object"' >/dev/null 2>&1; then
				print_information "Retry succeeded, got valid JSON response"
				echo "${retry_extracted}"
				return 0
			fi
		fi

		print_error "Vibe response is not valid JSON after retry, falling back to empty array"
		echo "[]"
	else
		# Text mode: vibe returns plain text directly; guard against empty output
		if [[ -n ${result} ]]; then
			echo "${result}"
		else
			echo "${fallback}"
		fi
	fi
}

# ---------------------------------------------------------------------------
# Transform the batch review result into a flat array of line-level comments
# suitable for posting to the GitHub PR review API.
# ---------------------------------------------------------------------------
function build_line_comments {
	local batch_result="$1"

	# Ensure the input is a valid JSON array
	if ! echo "${batch_result}" | jq --exit-status 'type == "array"' >/dev/null 2>&1; then
		echo "[]"
		return
	fi

	# Flatten file-level issues into individual comment objects.
	# Issues without a code_snippet are discarded — the model must prove each
	# issue by quoting the exact offending code from the file.
	echo "${batch_result}" | jq --compact-output '
		[.[] | . as $file |
			(.issues // [])[] |
			select(.code_snippet != null and .code_snippet != "") |
			{
				path: $file.file_path,
				body: ("**\(.severity // "info")**: \(.message)\n\n```\n\(.code_snippet)\n```"),
				line: (.line // 1)
			}
		]
	' 2>/dev/null || echo "[]"
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
# Before posting, dismisses any previous bot reviews so stale change
# requests do not block the PR.
# ---------------------------------------------------------------------------
function process_results_github {
	local comment_count="$1"
	local has_critical="$2"
	local summary_text="$3"
	local all_comments="$4"

	# Dismiss previous bot reviews before posting a new one
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

		jq --null-input --arg p "${file}" --rawfile c "${file}" '{path: $p, content: $c}' >>"${entries_file}"
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
# and returns the complete prompt string for the Vibe CLI.
# ---------------------------------------------------------------------------
function build_review_prompt {
	local batch_json="$1"

	printf '%s' "${REVIEW_PREAMBLE}

INPUT DATA STRUCTURE:
[
  {
    \"path\": \"filename.ext\",
    \"content\": \"complete file contents\"
  }
]

RESPONSE FORMAT:
You MUST respond with ONLY a valid JSON array — no markdown, no explanation, no text before or after the JSON. Do NOT wrap the JSON in code fences. Your entire response must be parseable by a JSON parser.

You MUST return one entry per reviewed file. If a file has no issues, include it with an empty issues array.

OUTPUT DATA STRUCTURE (JSON array):
[
  {
    \"file_path\": \"filename.ext\",
    \"issues\": [
      {
        \"line\": <line_number>,
        \"message\": \"clear description of the actual issue\",
        \"severity\": \"info|warning|error|critical\",
        \"code_snippet\": \"the exact code from the file that proves this issue — copy-paste verbatim\"
      }
    ]
  }
]

IMPORTANT:
- Every issue MUST have a non-empty code_snippet field with the exact code from the file. Issues without code_snippet will be automatically discarded.
- ONLY review the files provided below. Do NOT reference, comment on, or report issues for any other files in the project. Your review scope is strictly limited to the files listed here.

If a file has no issues, return it as: {\"file_path\": \"filename.ext\", \"issues\": []}

FILES TO REVIEW:
${batch_json}"
}

# ---------------------------------------------------------------------------
# Send file contents to the Vibe CLI for batch review. Splits files into
# batches that fit within the OS ARG_MAX limit (~2MB on Linux) to prevent
# "Argument list too long" errors on large PRs. Results from all batches
# are merged into a single JSON array.
# ---------------------------------------------------------------------------
function review_files {
	local files_json_file="$1"

	local total_files
	total_files=$(jq 'length' "${files_json_file}")

	if [[ ${total_files} -eq 0 ]]; then
		echo "[]"
		return
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
			if [[ $((batch_size + entry_size)) -gt ${MAX_BATCH_CONTENT_BYTES} && ${batch_end} -gt ${batch_start} ]]; then
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

		# Build the prompt and invoke the Vibe CLI
		local batch_prompt
		batch_prompt=$(build_review_prompt "${batch_json}")
		local batch_result
		batch_result=$(invoke_vibe "json" "${batch_prompt}")

		# Append this batch's results for later merging
		echo "${batch_result}" >>"${results_file}"

		batch_start=${batch_end}
	done

	# Merge all batch results into a single JSON array
	jq --slurp 'add // []' "${results_file}"
	rm --force "${results_file}"
}

# ---------------------------------------------------------------------------
# Generate a human-readable Markdown summary of the review results using
# the Vibe CLI. Applies a strict six-section template and falls back to a
# default summary if generation fails.
# ---------------------------------------------------------------------------
function generate_summary {
	local batch_result="$1"

	local summary_prompt="${REVIEW_PREAMBLE}

GOAL: Generate a human-readable Markdown summary of code review results suitable for a GitHub PR review comment.

INPUT DATA STRUCTURE:
${batch_result}

NOTE: If the input contains no issues (empty issues arrays), that means the code review analysed all changed files and found no problems. You MUST still produce the full template below — fill each section explaining that no issues were found and highlight positive aspects of the code. If the input is an empty array ([]), state that the automated review could not produce results and recommend a manual review.

OUTPUT:
Return ONLY a Markdown-formatted text summary (NOT JSON). You MUST use the EXACT template below, filling in each section. If a section has no relevant content, you MUST still include the heading and write a single sentence explaining why there are no comments for that section (e.g. 'No critical or error-level issues were identified.').

TEMPLATE (follow this structure exactly):

## Overall Assessment

<One or two sentences summarising the overall quality of the changes.>

## Critical and Error Issues

<List any critical or error severity issues found. If none, state why.>

## Warnings

<List any warning severity issues found. If none, state why.>

## Informational Notes

<List any info severity observations. If none, state why.>

## Positive Aspects

<Highlight good practices, clean code, or well-handled areas.>

## Recommendations

<Actionable suggestions for improvement. If none, state why.>

REQUIREMENTS:
- Your response MUST start with '## Overall Assessment' — no preamble, introduction, or conversational text before it
- You MUST include ALL six sections listed above, in order
- Each section MUST have content — either findings or an explanation of why there are none
- ONLY report issues that are present in the INPUT DATA — do NOT invent, assume, or hallucinate issues. If an issue is not in the input JSON, it MUST NOT appear in the summary. The summary is a reformatting of the input, not an independent review
- Be specific, factual, and professional
- Use bullet points within sections where multiple items exist
- Do NOT add extra sections or change the headings
- NEVER return a one-line response — always produce the full template"

	local summary
	summary=$(invoke_vibe "text" "${summary_prompt}")

	# Strip markdown code fences that some models wrap their response in
	if printf '%s\n' "${summary}" | grep --quiet --extended-regexp '^```'; then
		summary=$(printf '%s\n' "${summary}" | sed '/^```/d')
	fi

	# Strip any preamble text before the first markdown heading
	if printf '%s\n' "${summary}" | grep --quiet '^#'; then
		summary=$(printf '%s\n' "${summary}" | sed -n '/^#/,$p')
	fi

	# Use fallback template if summary generation failed or returned empty
	if [[ -z ${summary} || ${summary} == "No summary available." ]]; then
		print_error "Summary generation failed, using fallback template"
		summary="## Automated Review Failed

The review model did not return a usable summary. This does not indicate issues with the code itself — please review the changes manually.

If this keeps happening, please drop James a message on Basecamp with a link to this PR so he can investigate."
	fi

	echo "${summary}"
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
	if [[ -z ${ROOT_DIRECTORY:-} ]]; then
		print_error "Error: ROOT_DIRECTORY is not set."
		return 2
	fi

	cd "$ROOT_DIRECTORY"

	# Authenticate with the Mistral API
	check_mistral_auth

	# Step 1: Discover changed files
	local files
	if ! files=$(get_changed_files); then
		print_error "Failed to retrieve changed files"
		exit 1
	fi

	if [[ -z ${files} ]]; then
		print_information "No files to review"
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

	# Step 3: Review files with the Vibe CLI (batched to stay under ARG_MAX)
	print_information "Reviewing all files with Vibe CLI"
	local batch_result
	batch_result=$(review_files "${files_json_file}")
	rm --force "${files_json_file}"

	# Log the batch review result size for diagnostics
	local batch_issue_count
	batch_issue_count=$(echo "${batch_result}" | jq '[.[]?.issues[]?] | length' 2>/dev/null || echo "0")
	print_information "Batch review returned ${batch_issue_count} issues across $(echo "${batch_result}" | jq 'length' 2>/dev/null || echo "0") file entries"

	# Derive line comments and statistics from the batch result
	local all_comments
	all_comments=$(build_line_comments "${batch_result}")

	local comment_count
	comment_count=$(echo "${all_comments}" | jq 'length' 2>/dev/null || echo "0")
	print_information "After code_snippet filter: ${comment_count} of ${batch_issue_count} issues retained"

	# Only flag as critical for confirmed critical-severity issues; errors may
	# stem from stale model knowledge and should not trigger change requests
	local has_critical
	has_critical=$(echo "${batch_result}" | jq '[.[]?.issues[]? | select(.severity == "critical") | select(.code_snippet != null and .code_snippet != "")] | length > 0' 2>/dev/null || echo "false")

	# Step 4: Generate a human-readable Markdown summary
	print_information "Generating text summary for review comment"
	local summary_text
	summary_text=$(generate_summary "${batch_result}")

	# Step 5: Submit the review with line comments and summary
	submit_review "${comment_count}" "${has_critical}" "${summary_text}" "${all_comments}"
}

main "$@"
exit 0
