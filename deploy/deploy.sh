#!/usr/bin/env bash
# GodotDeploy — export Godot Web build to gh-pages branch
set -euo pipefail

DEPLOY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$DEPLOY_DIR/.." && pwd)"
CONFIG_PATH="$DEPLOY_DIR/deploy.json"
LOCAL_CONFIG_PATH="$DEPLOY_DIR/deploy.local.json"
PROJECT_FILE="$PROJECT_ROOT/project.godot"
SHELL_TEMPLATE="$DEPLOY_DIR/html_shell/shell.html"
SHELL_PREPARED="$DEPLOY_DIR/html_shell/index.prepared.html"

COMMAND="${1:-help}"
DRY_RUN=false
SKIP_TAG=false
BUMP=""

shift || true
while [[ $# -gt 0 ]]; do
    case "$1" in
        -DryRun|--dry-run) DRY_RUN=true ;;
        -SkipTag|--skip-tag) SKIP_TAG=true ;;
        -Bump|--bump) BUMP="${2:-}"; shift ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
    shift
done

step() { echo ">> $*"; }
ok() { echo "OK  $*"; }
warn() { echo "!!  $*"; }
err() { echo "ERR $*" >&2; }

git_cmd() {
    git -C "$PROJECT_ROOT" "$@"
}

read_json_value() {
    local file="$1" key="$2"
    [[ -f "$file" ]] || return 0
    python3 - "$file" "$key" <<'PY'
import json, sys
path, key = sys.argv[1], sys.argv[2]
with open(path, encoding="utf-8") as f:
    data = json.load(f)
print(data.get(key, ""))
PY
}

get_project_setting() {
    local key="$1"
    grep -E "^${key}=" "$PROJECT_FILE" | head -n1 | sed -E 's/^[^"]*"([^"]*)".*$/\1/'
}

set_project_version() {
    local version="$1"
    if grep -q '^config/version=' "$PROJECT_FILE"; then
        sed -i.bak -E "s/^config/version=\"[^\"]*\"/config/version=\"${version}\"/" "$PROJECT_FILE"
        rm -f "$PROJECT_FILE.bak"
    else
        sed -i.bak "/^\[application\]/a config/version=\"${version}\"" "$PROJECT_FILE"
        rm -f "$PROJECT_FILE.bak"
    fi
}

bump_version() {
    local version="$1" part="$2"
    IFS='.' read -r major minor patch <<< "$version"
    case "$part" in
        major) echo "$((major + 1)).0.0" ;;
        minor) echo "${major}.$((minor + 1)).0" ;;
        patch) echo "${major}.${minor}.$((patch + 1))" ;;
        *) echo "$version" ;;
    esac
}

semver_greater() {
    local a="$1" b="$2"
    IFS='.' read -r am ai ap <<< "$a"
    IFS='.' read -r bm bi bp <<< "$b"
    (( am > bm )) && return 0
    (( am < bm )) && return 1
    (( ai > bi )) && return 0
    (( ai < bi )) && return 1
    (( ap > bp ))
}

max_semver() {
    if semver_greater "$1" "$2"; then echo "$1"; else echo "$2"; fi
}

latest_tag_version() {
    git_cmd fetch origin --tags 2>/dev/null || true
    local latest="0.0.0" tag ver
    while IFS= read -r tag; do
        [[ -z "$tag" ]] && continue
        if [[ "$tag" =~ ^v([0-9]+\.[0-9]+\.[0-9]+)$ ]]; then
            ver="${BASH_REMATCH[1]}"
            latest="$(max_semver "$ver" "$latest")"
        fi
    done < <(git_cmd tag -l 'v*' 2>/dev/null || true)
    echo "$latest"
}

resolve_next_version() {
    local bump_override="${1:-}"
    local part="${bump_override:-$(read_json_value "$CONFIG_PATH" auto_bump)}"
    [[ -n "$part" ]] || part="patch"

    local project_version tag_version base
    project_version="$(get_project_setting config/version)"
    [[ -n "$project_version" ]] || project_version="0.0.0"
    tag_version="$(latest_tag_version)"
    base="$(max_semver "$project_version" "$tag_version")"
    bump_version "$base" "$part"
}

complete_readme_from_template() {
    restore_template_readme
    git_cmd add README.md 2>/dev/null || true
}

sync_source_branch_no_head() {
    local branch="$1"
    complete_readme_from_template
    git_cmd add -A
    if [[ -n "$(git_cmd status --porcelain)" ]]; then
        git_cmd commit -m "Initial project setup"
    else
        git_cmd commit --allow-empty -m "Initial project setup"
    fi

    if ! git_cmd pull origin "$branch" --allow-unrelated-histories --no-rebase -X ours; then
        if git_cmd rev-parse --verify MERGE_HEAD >/dev/null 2>&1; then
            complete_readme_from_template
            git_cmd add README.md
            git_cmd commit --no-edit
        else
            err "git pull failed while initializing main"
            exit 1
        fi
    fi

    complete_readme_from_template
}

sync_source_branch() {
    local pull_enabled source_branch
    pull_enabled="$(read_json_value "$CONFIG_PATH" pull_before_deploy)"
    source_branch="$(read_json_value "$CONFIG_PATH" source_branch)"
    [[ "$pull_enabled" =~ ^([Ff]alse|null|0)$ ]] && return 0
    if $DRY_RUN; then
        warn "Dry run: skip git pull"
        return 0
    fi

    complete_readme_from_template

    step "Syncing with origin/${source_branch}..."
    git_cmd fetch origin 2>/dev/null || true

    if ! git_cmd rev-parse --verify "refs/remotes/origin/${source_branch}" >/dev/null 2>&1; then
        warn "Remote branch origin/${source_branch} not found - skip pull"
        return 0
    fi

    if ! git_cmd rev-parse --verify HEAD >/dev/null 2>&1; then
        sync_source_branch_no_head "$source_branch"
        return 0
    fi

    if ! git_cmd pull --rebase --autostash origin "$source_branch"; then
        git_cmd rebase --abort 2>/dev/null || true
        complete_readme_from_template
        git_cmd pull --no-rebase --autostash origin "$source_branch" || {
            err "git pull failed. Commit or stash local changes and retry."
            exit 1
        }
    fi

    complete_readme_from_template
}

restore_template_readme() {
    local template="$DEPLOY_DIR/README.template.md"
    [[ -f "$template" ]] || { warn "Missing deploy/README.template.md"; return 0; }
    cp -f "$template" "$PROJECT_ROOT/README.md"
}

find_godot() {
    local configured="$1"
    if [[ -n "$configured" && -x "$configured" ]]; then
        echo "$configured"
        return
    fi
    if command -v godot >/dev/null 2>&1; then
        command -v godot
        return
    fi
    err "Godot not found. Set godot_path in deploy/deploy.local.json"
    exit 1
}

github_pages_url() {
    local remote repo user
    remote="$(git_cmd remote get-url origin 2>/dev/null || true)"
    [[ -n "$remote" ]] || return 0
    if [[ "$remote" =~ github.com[:/]([^/]+)/([^/.]+) ]]; then
        user="${BASH_REMATCH[1]}"
        repo="${BASH_REMATCH[2]}"
        if [[ "$repo" == "${user}.github.io" ]]; then
            echo "https://${user}.github.io/"
        else
            echo "https://${user}.github.io/${repo}/"
        fi
    fi
}

prepare_html_shell() {
    local version="$1"
    sed "s/{{VERSION}}/${version}/g" "$SHELL_TEMPLATE" > "$SHELL_PREPARED"
}

get_release_commit_lines() {
    local since_version="$1"
    local git_args=(log --pretty=format:%h|%s|%an|%ad --date=short --no-merges)

    if [[ -n "$since_version" && "$since_version" != "0.0.0" ]] \
        && git_cmd rev-parse -q --verify "refs/tags/v${since_version}" >/dev/null 2>&1; then
        git_args+=("v${since_version}..HEAD")
    else
        git_args+=(-n 30)
    fi

    local output line parts
    output="$(git_cmd "${git_args[@]}" 2>/dev/null || true)"
    if [[ -z "$output" ]]; then
        echo "- Нет записей"
        return
    fi

    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        IFS='|' read -r hash subject author date <<< "$line"
        echo "- ${subject} (${author}, ${date})"
    done <<< "$output"
}

write_gh_pages_readme() {
    local worktree_path="$1" version="$2" previous_version="$3"
    local game_name pages_url play_link date commit_block

    game_name="$(get_project_setting config/name)"
    [[ -n "$game_name" ]] || game_name="Игра"
    pages_url="$(read_json_value "$CONFIG_PATH" github_pages_url)"
    [[ -z "$pages_url" ]] && pages_url="$(github_pages_url || true)"
    play_link="${pages_url:-index.html}"
    date="$(date +"%Y-%m-%d %H:%M")"
    commit_block="$(get_release_commit_lines "$previous_version")"

    cat > "$worktree_path/README.md" <<EOF
# [${game_name}](${play_link}) ${version}
${date}
## Изменения
${commit_block}
---
EOF
}

ensure_release_commit() {
    local version="$1"
    local commit_message
    commit_message="$(read_json_value "$CONFIG_PATH" source_commit_template)"
    commit_message="${commit_message//\{version\}/$version}"

    if $DRY_RUN; then
        warn "Dry run: skip source commit"
        return 0
    fi

    restore_template_readme

    git_cmd add -A
    if [[ -n "$(git_cmd status --porcelain)" ]]; then
        git_cmd commit -m "$commit_message"
        ok "Source committed on $(read_json_value "$CONFIG_PATH" source_branch)"
    fi
}

invoke_export() {
    local godot="$1" preset="$2" output_dir="$3"
    mkdir -p "$output_dir"
    step "Exporting Web build..."
    if $DRY_RUN; then
        warn "Dry run: skip Godot export"
        return
    fi
    "$godot" --headless --path "$PROJECT_ROOT" --export-release "$preset" "$output_dir/index.html"
}

publish_gh_pages() {
    local export_dir="$1" version="$2" previous_version="$3"
    local pages_branch worktree_dir commit_message
    pages_branch="$(read_json_value "$CONFIG_PATH" pages_branch)"
    worktree_dir="$(read_json_value "$CONFIG_PATH" worktree_dir)"
    commit_message="$(read_json_value "$CONFIG_PATH" commit_message_template)"
    commit_message="${commit_message//\{version\}/$version}"
    worktree_path="$PROJECT_ROOT/$worktree_dir"

    if $DRY_RUN; then
        warn "Dry run: would publish to $pages_branch"
        return
    fi

    if [[ -d "$worktree_path" ]]; then
        git_cmd worktree remove --force "$worktree_dir" || true
    fi

    step "Preparing gh-pages worktree..."
    if git_cmd show-ref --verify --quiet "refs/heads/$pages_branch"; then
        git_cmd worktree add "$worktree_dir" "$pages_branch"
    elif git_cmd show-ref --verify --quiet "refs/remotes/origin/$pages_branch"; then
        git_cmd fetch origin "${pages_branch}:${pages_branch}"
        git_cmd worktree add "$worktree_dir" "$pages_branch"
    else
        git_cmd worktree add -B "$pages_branch" "$worktree_dir"
    fi

    find "$worktree_path" -mindepth 1 -maxdepth 1 ! -name '.git' -exec rm -rf {} +
    cp -a "$export_dir/." "$worktree_path/"
    write_gh_pages_readme "$worktree_path" "$version" "$previous_version"

    git -C "$worktree_path" add -A
    if [[ -n "$(git -C "$worktree_path" status --porcelain)" ]]; then
        git -C "$worktree_path" commit -m "$commit_message"
        step "Pushing $pages_branch..."
        git -C "$worktree_path" push -u origin "$pages_branch"
    else
        warn "No changes in web build — skip push"
    fi

    git_cmd worktree remove --force "$worktree_dir"
}

push_source_and_tag() {
    local version="$1"
    local source_branch tag_name
    source_branch="$(read_json_value "$CONFIG_PATH" source_branch)"
    tag_name="v$version"

    if $DRY_RUN; then
        warn "Dry run: would tag $tag_name"
        return 0
    fi

    if git_cmd rev-parse -q --verify "refs/tags/$tag_name" >/dev/null; then
        err "Tag $tag_name already exists"
        exit 1
    fi

    if ! $SKIP_TAG; then
        git_cmd tag "$tag_name"
        git_cmd push origin "$source_branch"
        git_cmd push origin "$tag_name"
    else
        git_cmd push origin "$source_branch"
    fi
}

initialize_gh_pages_branch() {
    git_cmd rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
        warn "gh-pages будет создана при первом deploy (нужен git)"
        return 0
    }
    git_cmd remote get-url origin >/dev/null 2>&1 || {
        warn "gh-pages будет создана при первом deploy (нужен origin)"
        return 0
    }

    local pages_branch worktree_path
    pages_branch="$(read_json_value "$CONFIG_PATH" pages_branch)"
    [[ -n "$pages_branch" ]] || pages_branch="gh-pages"
    worktree_path="$PROJECT_ROOT/$(read_json_value "$CONFIG_PATH" worktree_dir)"

    git_cmd fetch origin 2>/dev/null || true
    if git_cmd show-ref --verify --quiet "refs/remotes/origin/$pages_branch"; then
        ok "Branch $pages_branch already on GitHub"
        return 0
    fi

    step "Creating branch $pages_branch on GitHub..."
    [[ -d "$worktree_path" ]] && git_cmd worktree remove --force "$(read_json_value "$CONFIG_PATH" worktree_dir)" || true
    git_cmd worktree add -B "$pages_branch" "$(read_json_value "$CONFIG_PATH" worktree_dir)"

    find "$worktree_path" -mindepth 1 -maxdepth 1 ! -name '.git' -exec rm -rf {} +
    cat > "$worktree_path/README.md" <<'EOF'
# Скоро здесь будет игра

Запусти `deploy.bat deploy` из ветки main.
EOF

    git -C "$worktree_path" add README.md
    git -C "$worktree_path" commit -m "Initialize gh-pages"
    git -C "$worktree_path" push -u origin "$pages_branch"
    git_cmd worktree remove --force "$(read_json_value "$CONFIG_PATH" worktree_dir)"
    ok "Branch $pages_branch created - enable GitHub Pages"
}

cmd_init() {
    step "Initializing GodotDeploy..."
    [[ -f "$PROJECT_FILE" ]] || { err "project.godot not found"; exit 1; }

    restore_template_readme
    ok "README restored from template"

    [[ -f "$CONFIG_PATH" ]] || cp "$DEPLOY_DIR/deploy.json.example" "$CONFIG_PATH"
    [[ -f "$LOCAL_CONFIG_PATH" ]] || cp "$DEPLOY_DIR/deploy.local.json.example" "$LOCAL_CONFIG_PATH"

    local version
    version="$(get_project_setting config/version)"
    prepare_html_shell "$version"
    ok "Prepared HTML shell for v$version"

    git_cmd rev-parse --is-inside-work-tree >/dev/null 2>&1 && ok "Git repository detected" || warn "Not a git repo yet"

    local godot_path godot
    godot_path="$(read_json_value "$LOCAL_CONFIG_PATH" godot_path)"
    godot="$(find_godot "$godot_path")"
    ok "Godot: $godot"

    initialize_gh_pages_branch

    local url
    url="$(github_pages_url || true)"
    echo
    echo "Next steps:"
    echo "  1. Rename game in project.godot"
    echo "  2. Install Web Export Templates in Godot"
    echo "  3. Enable GitHub Pages: branch gh-pages, folder /"
    echo "  4. ./deploy/deploy.sh deploy"
    [[ -n "$url" ]] && echo "  5. Game URL: $url"
}

cmd_deploy() {
    [[ -f "$CONFIG_PATH" ]] || { err "Run init first"; exit 1; }
    git_cmd rev-parse --is-inside-work-tree >/dev/null

    sync_source_branch

    local previous_version version preset export_dir godot_path godot export_relative
    previous_version="$(latest_tag_version)"
    version="$(resolve_next_version "$BUMP")"
    if ! $DRY_RUN; then
        set_project_version "$version"
    fi
    ok "Auto version: $version"

    ensure_release_commit "$version"

    preset="$(read_json_value "$CONFIG_PATH" export_preset)"
    export_dir="$PROJECT_ROOT/$(read_json_value "$CONFIG_PATH" export_output_dir)"
    export_relative="$(read_json_value "$CONFIG_PATH" export_output_dir)/index.html"
    godot_path="$(read_json_value "$LOCAL_CONFIG_PATH" godot_path)"
    godot="$(find_godot "$godot_path")"
    ok "Godot: $godot"

    prepare_html_shell "$version"
    invoke_export "$godot" "$preset" "$export_dir"
    ok "Export complete"

    publish_gh_pages "$export_dir" "$version" "$previous_version"
    ok "Published to gh-pages"

    push_source_and_tag "$version"

    local url
    url="$(read_json_value "$CONFIG_PATH" github_pages_url)"
    [[ -z "$url" ]] && url="$(github_pages_url || true)"
    echo
    echo "Deploy complete - v$version"
    [[ -n "$url" ]] && echo "Play: $url"
    warn "Hard-refresh (Ctrl+F5) if browser shows old build."
}

case "$COMMAND" in
    init) cmd_init ;;
    deploy) cmd_deploy ;;
    *)
        cat <<'EOF'
GodotDeploy — one-repo Web deploy to GitHub Pages

Usage:
  ./deploy/deploy.sh init
  ./deploy/deploy.sh deploy [--dry-run] [--skip-tag] [--bump patch|minor|major]
EOF
        ;;
esac
