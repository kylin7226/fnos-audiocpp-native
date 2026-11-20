#!/usr/bin/env python3
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile


BASE_RE = r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)"
TAG_RE = re.compile(rf"v({BASE_RE})-([0-9]{{3}})")


def validate_base(base):
    if not re.fullmatch(BASE_RE, base):
        raise ValueError(f"仅支持标准正式版本 X.Y.Z，不支持后缀版本：{base!r}")
    return base


def parse_tag(tag):
    match = TAG_RE.fullmatch(tag)
    if not match:
        raise ValueError(f"发布 tag 必须为 vX.Y.Z-NNN：{tag!r}")
    return match.groups()


def tags():
    return subprocess.check_output(["git", "tag", "-l", "v*"], text=True).splitlines()


def next_revision(base, existing):
    revisions = [int(m.group(2)) for tag in existing if (m := TAG_RE.fullmatch(tag)) and m.group(1) == base]
    value = max(revisions, default=-1) + 1
    if value > 999:
        raise ValueError(f"{base} 的三位修订号已耗尽")
    return f"{value:03d}"


def resolve(env, existing):
    if env.get("CALL_BASE"):
        base, revision, kind = env["CALL_BASE"], env.get("IN_REV", ""), "release"
    elif env.get("GITHUB_REF", "").startswith("refs/tags/"):
        base, revision = parse_tag(env["GITHUB_REF"].removeprefix("refs/tags/"))
        kind = "release"
    else:
        base = validate_base(env.get("IN_REF", "").removeprefix("v"))
        revision = env.get("IN_REV") or next_revision(base, existing)
        kind = "preview"
    validate_base(base)
    if not re.fullmatch(r"[0-9]{3}", revision):
        raise ValueError(f"修订号必须是三位数字：{revision!r}")
    version = f"{base}-{revision}"
    return {"ref": f"v{base}", "version": version, "kind": kind, "tag_name": f"v{version}"}


def api(endpoint, optional=False, paginate=False):
    command = ["gh", "api", endpoint]
    if paginate:
        command += ["--paginate", "--slurp"]
    result = subprocess.run(command, text=True, capture_output=True)
    if result.returncode:
        if optional and "(HTTP 404)" in result.stderr:
            return None
        raise RuntimeError(f"GitHub API 请求失败 {endpoint}: {result.stderr.strip()}")
    return json.loads(result.stdout)


def asset_for(release, tag):
    if not release:
        return None
    base, revision = parse_tag(tag)
    expected = f"audiocpp_{base}-{revision}_x86.fpk"
    assets = [asset for asset in release["assets"] if asset["name"].endswith(".fpk")]
    if any(asset["name"] != expected for asset in assets):
        raise ValueError(f"{tag} 含非预期 FPK 附件，拒绝覆盖")
    if len(assets) > 1:
        raise ValueError(f"{tag} 存在重复附件")
    if assets and assets[0].get("state") == "starter" and assets[0].get("size") == 0:
        return None
    if assets and (assets[0].get("state") != "uploaded" or assets[0].get("size", 0) <= 0):
        raise ValueError(f"{tag} 附件状态异常，拒绝覆盖已有内容")
    return assets[0] if assets else None


def digest_of(asset):
    value = asset.get("digest")
    if value is None or value == "":
        return None
    if not re.fullmatch(r"sha256:[0-9a-f]{64}", value):
        raise ValueError(f"不支持的附件 digest：{value!r}")
    return value.removeprefix("sha256:")


def hash_file(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(4 * 1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def download_asset(repo, tag, asset, directory):
    subprocess.run(["gh", "release", "download", tag, "--repo", repo,
                    "--pattern", asset["name"], "--dir", str(directory)], check=True)
    path = directory / asset["name"]
    digest = hash_file(path)
    if path.stat().st_size != asset["size"]:
        raise ValueError("下载附件大小与 Release 不符")
    expected = digest_of(asset)
    if expected and digest != expected:
        raise ValueError("下载附件 SHA256 与 Release 不符")
    if not expected:
        print("::warning::旧附件缺少 GitHub digest；已校验大小并计算本地 SHA256")
    return path, digest


def release(repo, tag):
    result = api(f"repos/{repo}/releases/tags/{tag}", optional=True)
    if result and result["prerelease"]:
        raise ValueError(f"{tag} 是预发布，拒绝作为正式包处理")
    return result


def detect(repo, in_base, force, existing, index, sha):
    if force not in ("", "false", "true"):
        raise ValueError("force 必须是 true 或 false")
    if in_base:
        base = validate_base(in_base.removeprefix("v"))
        upstream = api(f"repos/0xShug0/audio.cpp/releases/tags/v{base}")
        if upstream["draft"] or upstream["prerelease"]:
            raise ValueError("只能构建上游正式 Release")
    else:
        pages = api("repos/0xShug0/audio.cpp/releases?per_page=100", paginate=True)
        candidates = [r["tag_name"][1:] for page in pages for r in page
                      if not r["draft"] and not r["prerelease"]
                      and re.fullmatch(rf"v{BASE_RE}", r["tag_name"])]
        if not candidates:
            raise ValueError("未找到标准 X.Y.Z 正式 Release")
        base = max(candidates, key=lambda v: tuple(map(int, v.split("."))))
    api(f"repos/0xShug0/audio.cpp/git/ref/tags/v{base}")
    git_tags = set(existing)
    own_pages = api(f"repos/{repo}/releases?per_page=100", paginate=True)
    existing = git_tags | {item["tag_name"] for page in own_pages for item in page}
    matching = sorted(tag for tag in existing if (m := TAG_RE.fullmatch(tag)) and m.group(1) == base)
    latest = matching[-1] if matching else None
    rev = parse_tag(latest)[1] if latest and force != "true" else next_revision(base, existing)
    action = "build"
    if latest and force != "true":
        base, rev = parse_tag(latest)
        current = release(repo, latest)
        asset = asset_for(current, latest)
        package = index.get("apps", {}).get("audiocpp", {}).get("releases", {}).get(latest[1:], {}).get("packages", {}).get("x86")
        if asset:
            digest = digest_of(asset)
            if not digest:
                with tempfile.TemporaryDirectory() as tmp:
                    _, digest = download_asset(repo, latest, asset, Path(tmp))
            if package and (package["sha256"] != digest or package["size"] != asset["size"]):
                raise ValueError("已索引版本的附件内容发生变化，拒绝自动覆盖索引")
            complete = package and package["download_url"] == asset["browser_download_url"] and not current["draft"]
            action = "none" if complete else "sync"
        elif package:
            raise ValueError("已索引的发布附件丢失，不能重建替换相同版本；请恢复原附件或使用新修订号")
        else:
            commit = (subprocess.check_output(["git", "rev-list", "-n", "1", latest], text=True).strip()
                      if latest in git_tags else (current or {}).get("target_commitish"))
            if commit != sha:
                rev = next_revision(base, existing)
    return {"action": action, "base": base, "rev": rev, "tag": f"v{base}-{rev}"}


def emit(values):
    with open(os.environ["GITHUB_OUTPUT"], "a", encoding="utf-8") as stream:
        for key, value in values.items():
            print(f"{key}={value}")
            stream.write(f"{key}={value}\n")


def assert_tag_sha(repo, tag, sha):
    ref = api(f"repos/{repo}/git/ref/tags/{tag}", optional=True)
    if ref:
        obj = ref["object"]
        while obj["type"] == "tag":
            obj = api(f"repos/{repo}/git/tags/{obj['sha']}")["object"]
        if obj["type"] != "commit" or obj["sha"] != sha:
            raise ValueError("现有 tag 不指向本次打包源码；请递增修订号，禁止移动 tag")


def inspect(repo, tag, sha):
    parse_tag(tag)
    current = release(repo, tag)
    if asset_for(current, tag):
        return {"build": "false"}
    assert_tag_sha(repo, tag, sha)
    return {"build": "true"}


def publish(repo, tag, sha, directory):
    import check_payload
    parse_tag(tag)
    current = release(repo, tag)
    asset = asset_for(current, tag)
    if not asset:
        assert_tag_sha(repo, tag, sha)
        expected = directory / f"audiocpp_{tag[1:]}_x86.fpk"
        if not expected.is_file():
            raise FileNotFoundError(expected)
        if not current:
            subprocess.run(["gh", "release", "create", tag, "--repo", repo, "--target", sha,
                            "--draft", "--title", f"audio.cpp fnOS fpk {tag[1:]}",
                            "--generate-notes"], check=True)
        if current:
            for item in current["assets"]:
                if item["name"] == expected.name and item.get("state") == "starter" and item["size"] == 0:
                    subprocess.run(["gh", "api", "--method", "DELETE",
                                    f"repos/{repo}/releases/assets/{item['id']}"], check=True)
        subprocess.run(["gh", "release", "upload", tag, str(expected), "--repo", repo], check=True)
        current = release(repo, tag)
        asset = asset_for(current, tag)
        with tempfile.TemporaryDirectory() as tmp:
            path, digest = download_asset(repo, tag, asset, Path(tmp))
            check_payload.check_fpk(path, tag[1:])
        if digest != hash_file(expected):
            raise ValueError("上传后的附件与本次构建不一致")
    elif current["draft"]:
        with tempfile.TemporaryDirectory() as tmp:
            path, _ = download_asset(repo, tag, asset, Path(tmp))
            check_payload.check_fpk(path, tag[1:])
    if current["draft"]:
        subprocess.run(["gh", "release", "edit", tag, "--repo", repo, "--draft=false"], check=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("action", choices=["resolve", "detect", "inspect", "publish", "download"])
    args = parser.parse_args()
    repo = os.environ.get("GITHUB_REPOSITORY", "")
    tag = os.environ.get("TAG", "")
    if args.action == "resolve":
        emit(resolve(os.environ, tags()))
    elif args.action == "detect":
        emit(detect(repo, os.environ.get("IN_BASE", ""), os.environ.get("IN_FORCE", ""),
                    tags(), json.loads(Path("moo.json").read_text()), os.environ["GITHUB_SHA"]))
    elif args.action == "inspect":
        emit(inspect(repo, tag, os.environ["GITHUB_SHA"]))
    elif args.action == "publish":
        publish(repo, tag, os.environ["GITHUB_SHA"], Path("dist"))
    else:
        current = release(repo, tag)
        asset = asset_for(current, tag)
        if not asset:
            raise ValueError(f"{tag} 没有可用 FPK 附件")
        directory = Path(os.environ["FPK_DIR"])
        directory.mkdir(parents=True, exist_ok=True)
        path, _ = download_asset(repo, tag, asset, directory)
        import check_payload
        check_payload.check_fpk(path, tag[1:])
        if current["draft"]:
            subprocess.run(["gh", "release", "edit", tag, "--repo", repo, "--draft=false"], check=True)


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, RuntimeError, subprocess.CalledProcessError) as exc:
        print(f"::error::{exc}", file=sys.stderr)
        sys.exit(1)
