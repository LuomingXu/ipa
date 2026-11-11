#!/usr/bin/env bash
set -euo pipefail

REPO="${GITHUB_REPOSITORY:-LuomingXu/ipa}"
TAG="${RELEASE_TAG:-latest}"
DRY_RUN="${DRY_RUN:-0}"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
mapfile -t UPSTREAMS < <(grep -v '^[[:space:]]*$' "$script_dir/../upstreams.txt")

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

run() {
  if [ "$DRY_RUN" = 1 ]; then
    printf 'DRY-RUN: %s\n' "$*"
  else
    "$@"
  fi
}

declare -A want_digest want_url want_meta have_id have_digest
order=()

for r in "${UPSTREAMS[@]}"; do
  gh api "repos/$r/releases/latest" --jq '
    .tag_name as $tag | .published_at as $pub |
    .assets[] | select(.name | ascii_downcase | endswith(".ipa")) |
    [.name, (.digest // ""), (.size | tostring), .browser_download_url, $tag, $pub] | @tsv
  ' >"$work/up.tsv"

  # 上游没有 ipa 时直接失败，避免把已镜像的文件当成过期文件删掉
  if [ ! -s "$work/up.tsv" ]; then
    echo "错误: $r 最新 release 没有 .ipa 资源" >&2
    exit 1
  fi

  while IFS=$'\t' read -r name digest size url tag pub; do
    [ -n "$name" ] || continue
    [ -n "${want_digest[$name]+x}" ] || order+=("$name")
    want_digest[$name]="$digest"
    want_url[$name]="$url"
    want_meta[$name]="$r"$'\t'"$tag"$'\t'"$size"$'\t'"$pub"
    echo "上游 $r $tag -> $name"
  done <"$work/up.tsv"
done

release_exists=0
: >"$work/have.tsv"
: >"$work/current-body.md"
if gh api "repos/$REPO/releases/tags/$TAG" --jq \
  '.assets[] | [.id, .name, (.digest // "")] | @tsv' >"$work/have.tsv" 2>/dev/null; then
  release_exists=1
  gh api "repos/$REPO/releases/tags/$TAG" --jq '.body // ""' >"$work/current-body.md"
fi

while IFS=$'\t' read -r id name digest; do
  [ -n "$id" ] || continue
  have_id[$name]="$id"
  have_digest[$name]="$digest"
done <"$work/have.tsv"

stale_ids=()
stale_names=()
for name in "${!have_id[@]}"; do
  case "${name,,}" in *.ipa) ;; *) continue ;; esac
  if [ -z "${want_digest[$name]+x}" ]; then
    stale_ids+=("${have_id[$name]}")
    stale_names+=("$name")
  fi
done

uploads=()
for name in "${order[@]}"; do
  if [ -n "${have_id[$name]+x}" ] && [ -n "${want_digest[$name]}" ] &&
    [ "${have_digest[$name]}" = "${want_digest[$name]}" ]; then
    echo "未变化: $name"
  else
    uploads+=("$name")
  fi
done

{
  printf '每日自动同步的上游 IPA 镜像，保留上游原始文件名。只在上游有更新时替换文件。\n\n'
  printf '| 应用 | 上游版本 | 文件 | 大小 | 上游发布 |\n'
  printf '| --- | --- | --- | --- | --- |\n'
  for name in "${order[@]}"; do
    IFS=$'\t' read -r repo tag size pub <<<"${want_meta[$name]}"
    mib="$(awk "BEGIN { printf \"%.1f\", $size / 1048576 }")"
    printf '| [%s](https://github.com/%s) | `%s` | `%s` | %s MiB | %s |\n' \
      "${repo#*/}" "$repo" "$tag" "$name" "$mib" "${pub:0:10}"
  done
  printf '\n固定下载链接：`https://github.com/%s/releases/latest/download/<文件名>`\n' "$REPO"
} >"$work/body.md"

if [ "$release_exists" = 0 ]; then
  run gh release create "$TAG" --repo "$REPO" --target "${GITHUB_SHA:-master}" \
    --title '最新 IPA 合集' --notes-file "$work/body.md"
  cp "$work/body.md" "$work/current-body.md"
fi

for i in "${!stale_ids[@]}"; do
  echo "删除过期文件: ${stale_names[$i]}"
  run gh api -X DELETE "repos/$REPO/releases/assets/${stale_ids[$i]}"
done

mkdir -p "$work/dl"
for name in "${uploads[@]}"; do
  echo "更新: $name"
  if [ "$DRY_RUN" != 1 ]; then
    curl -fL --retry 3 --retry-delay 5 --connect-timeout 30 -o "$work/dl/$name" "${want_url[$name]}"
    if [ -n "${want_digest[$name]}" ]; then
      actual="sha256:$(sha256sum "$work/dl/$name" | cut -d' ' -f1)"
      if [ "$actual" != "${want_digest[$name]}" ]; then
        echo "错误: $name 校验失败 $actual != ${want_digest[$name]}" >&2
        exit 1
      fi
    fi
  fi
  run gh release upload "$TAG" "$work/dl/$name" --repo "$REPO" --clobber
done

# $(<file) 会剥掉尾部换行，抵消 gh --jq 输出时补的那个换行
if [ "$(<"$work/body.md")" != "$(<"$work/current-body.md")" ]; then
  run gh release edit "$TAG" --repo "$REPO" --notes-file "$work/body.md"
fi

echo "完成: 共 ${#order[@]} 个 IPA，更新 ${#uploads[@]} 个，删除 ${#stale_ids[@]} 个"

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  cat "$work/body.md" >>"$GITHUB_STEP_SUMMARY"
fi