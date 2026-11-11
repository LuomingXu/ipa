# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""生成 manifest.json，供 index.html 读取。"""

import argparse
import json
import os
import sys
import urllib.error
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent.parent
UPSTREAMS_FILE = ROOT / ".github" / "upstreams.txt"
OUTPUT = ROOT / "manifest.json"
API = "https://api.github.com"


def api_get(path: str, token: str) -> dict:
    req = urllib.request.Request(
        f"{API}{path}",
        headers={
            "Authorization": f"Bearer {token}",
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28",
            "User-Agent": "ipa-manifest-generator",
        },
    )
    with urllib.request.urlopen(req, timeout=30) as resp:
        return json.load(resp)


def build(repo: str, tag: str, token: str) -> dict:
    upstreams = [
        line.strip()
        for line in UPSTREAMS_FILE.read_text(encoding="utf-8").splitlines()
        if line.strip()
    ]

    meta = {}
    for upstream in upstreams:
        release = api_get(f"/repos/{upstream}/releases/latest", token)
        for asset in release.get("assets", []):
            if asset["name"].lower().endswith(".ipa"):
                meta[asset["name"]] = {
                    "repo": upstream,
                    "tag": release["tag_name"],
                    "published": (release.get("published_at") or "")[:10],
                }

    mirror = api_get(f"/repos/{repo}/releases/tags/{tag}", token)
    order = {name: i for i, name in enumerate(upstreams)}
    apps = []
    # 以镜像里实际存在的 asset 为准，保证页面不会列出下载不到的文件
    for asset in mirror.get("assets", []):
        name = asset["name"]
        if not name.lower().endswith(".ipa"):
            continue
        info = meta.get(name, {})
        apps.append(
            {
                "name": name,
                "repo": info.get("repo", ""),
                "tag": info.get("tag", ""),
                "size": asset["size"],
                "sha256": (asset.get("digest") or "").removeprefix("sha256:"),
                "published": info.get("published", ""),
                "url": f"https://github.com/{repo}/releases/latest/download/{name}",
            }
        )

    if not apps:
        raise SystemExit(f"错误: {repo} 的 {tag} release 里没有 .ipa，拒绝生成空清单")

    apps.sort(key=lambda a: (order.get(a["repo"], len(order)), a["name"]))

    unmatched = [a["name"] for a in apps if not a["repo"]]
    if unmatched:
        print(f"警告: 未能匹配上游元数据: {', '.join(unmatched)}", file=sys.stderr)

    return {
        "release": f"https://github.com/{repo}/releases/tag/{tag}",
        "release_updated": mirror.get("updated_at", ""),
        "apps": apps,
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dry-run", action="store_true", help="只打印，不写文件")
    args = parser.parse_args()

    token = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")
    if not token:
        raise SystemExit("错误: 需要设置 GH_TOKEN 或 GITHUB_TOKEN")

    repo = os.environ.get("GITHUB_REPOSITORY", "LuomingXu/ipa")
    tag = os.environ.get("RELEASE_TAG", "latest")

    try:
        manifest = build(repo, tag, token)
    except urllib.error.HTTPError as exc:
        raise SystemExit(f"错误: GitHub API {exc.code} {exc.url}") from exc
    except urllib.error.URLError as exc:
        raise SystemExit(f"错误: 无法访问 GitHub API: {exc.reason}") from exc

    text = json.dumps(manifest, indent=2, ensure_ascii=False) + "\n"
    if args.dry_run:
        print(text, end="")
        return

    OUTPUT.write_text(text, encoding="utf-8", newline="\n")
    print(f"已写入 {OUTPUT} ({len(manifest['apps'])} 个 IPA)")


if __name__ == "__main__":
    main()