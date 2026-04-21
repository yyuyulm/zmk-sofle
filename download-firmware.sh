#!/bin/sh

set -eu

usage() {
  cat <<'EOF'
Usage: download-firmware.sh [options]

Download the latest successful GitHub Actions firmware artifact into ./firmware
or download a specific run by id.

Options:
  --repo OWNER/REPO     GitHub repository to use
  --workflow NAME       Workflow name to search (default: Build ZMK firmware)
  --branch NAME         Branch to search (default: current git branch)
  --select              Pick a run interactively from a numbered list
  --run-id ID           Download a specific workflow run id
  --artifact NAME       Optional artifact name filter
  -o, --output DIR      Output directory (default: firmware)
  -h, --help            Show this help
EOF
}

repo=""
workflow="Build ZMK firmware"
branch=""
select_mode=false
run_id=""
artifact=""
output_dir="firmware"

cleanup() {
  if [ -n "${runs_file:-}" ] && [ -e "$runs_file" ]; then
    rm -f "$runs_file"
  fi
}

choose_run_id() {
  runs_file=$(mktemp "${TMPDIR:-/tmp}/zmk-runs.XXXXXX")
  trap cleanup EXIT INT HUP TERM

  if [ -n "$repo" ]; then
    if [ -n "$branch" ]; then
      gh run list --repo "$repo" --workflow "$workflow" --branch "$branch" -L 20 --json databaseId,displayTitle,createdAt,status,conclusion,headBranch --jq '.[] | [(.databaseId|tostring), .createdAt, .headBranch, .status, .conclusion, .displayTitle] | @tsv' > "$runs_file"
    else
      gh run list --repo "$repo" --workflow "$workflow" -L 20 --json databaseId,displayTitle,createdAt,status,conclusion,headBranch --jq '.[] | [(.databaseId|tostring), .createdAt, .headBranch, .status, .conclusion, .displayTitle] | @tsv' > "$runs_file"
    fi
  else
    if [ -n "$branch" ]; then
      gh run list --workflow "$workflow" --branch "$branch" -L 20 --json databaseId,displayTitle,createdAt,status,conclusion,headBranch --jq '.[] | [(.databaseId|tostring), .createdAt, .headBranch, .status, .conclusion, .displayTitle] | @tsv' > "$runs_file"
    else
      gh run list --workflow "$workflow" -L 20 --json databaseId,displayTitle,createdAt,status,conclusion,headBranch --jq '.[] | [(.databaseId|tostring), .createdAt, .headBranch, .status, .conclusion, .displayTitle] | @tsv' > "$runs_file"
    fi
  fi

  if [ ! -s "$runs_file" ]; then
    printf 'No workflow runs found.\n' >&2
    exit 1
  fi

  printf 'Select a run to download:\n'
  index=1
  while IFS="$(printf '\t')" read -r row_run_id created_at head_branch status conclusion title; do
    [ -n "$row_run_id" ] || continue
    printf '%2s) %s | %s | %s/%s | %s\n' "$index" "$created_at" "$head_branch" "$status" "$conclusion" "$title"
    index=$((index + 1))
  done < "$runs_file"

  total=$((index - 1))
  while :; do
    printf 'Enter selection [1-%s]: ' "$total"
    IFS= read -r choice || exit 1

    case "$choice" in
      ''|*[!0-9]*)
        printf 'Enter a number.\n' >&2
        ;;
      *)
        if [ "$choice" -ge 1 ] && [ "$choice" -le "$total" ]; then
          sed -n "${choice}p" "$runs_file" | cut -f1
          return 0
        fi
        printf 'Selection out of range.\n' >&2
        ;;
    esac
  done
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo)
      repo=${2:?missing value for --repo}
      shift 2
      ;;
    --workflow)
      workflow=${2:?missing value for --workflow}
      shift 2
      ;;
    --branch)
      branch=${2:?missing value for --branch}
      shift 2
      ;;
    --select)
      select_mode=true
      shift
      ;;
    --run-id)
      run_id=${2:?missing value for --run-id}
      shift 2
      ;;
    --artifact)
      artifact=${2:?missing value for --artifact}
      shift 2
      ;;
    -o|--output)
      output_dir=${2:?missing value for --output}
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      printf 'Unknown argument: %s\n' "$1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [ -e "$output_dir" ]; then
  printf 'Refusing to overwrite existing path: %s\n' "$output_dir" >&2
  exit 1
fi

if [ -z "$run_id" ] && [ "$select_mode" = true ]; then
  run_id=$(choose_run_id)
fi

if [ -z "$run_id" ]; then
  if [ -z "$branch" ]; then
    branch=$(git branch --show-current 2>/dev/null || true)
  fi

  if [ -z "$branch" ]; then
    printf 'Could not detect a branch. Pass --branch or --run-id.\n' >&2
    exit 1
  fi

  if [ -n "$repo" ]; then
    run_id=$(gh run list --repo "$repo" --workflow "$workflow" --branch "$branch" -L 100 --json databaseId,status,conclusion --jq 'map(select(.status=="completed" and .conclusion=="success"))[0].databaseId')
  else
    run_id=$(gh run list --workflow "$workflow" --branch "$branch" -L 100 --json databaseId,status,conclusion --jq 'map(select(.status=="completed" and .conclusion=="success"))[0].databaseId')
  fi
fi

if [ -z "$run_id" ] || [ "$run_id" = "null" ]; then
  printf 'No successful run found. Pass --run-id to download a specific run.\n' >&2
  exit 1
fi

printf 'Downloading run %s into %s\n' "$run_id" "$output_dir"

if [ -n "$repo" ] && [ -n "$artifact" ]; then
  gh run download "$run_id" --repo "$repo" --name "$artifact" -D "$output_dir"
elif [ -n "$repo" ]; then
  gh run download "$run_id" --repo "$repo" -D "$output_dir"
elif [ -n "$artifact" ]; then
  gh run download "$run_id" --name "$artifact" -D "$output_dir"
else
  gh run download "$run_id" -D "$output_dir"
fi
