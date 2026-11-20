#!/usr/bin/env python3
import argparse
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import socket
import subprocess
import tarfile
import tempfile
import time
import urllib.error
import urllib.request


CORE = ["bin/audiocpp_server", "bin/audiocpp_cli", "bin/audiocpp_model_manager",
        "bin/provision-models.sh", "etc/server.json.template",
        "assets/silero_vad/silero_vad_16k.safetensors",
        "assets/demo_voices/prompt_text"] + [f"assets/demo_voices/{name}.wav" for name in
                                           ("demo_1_man", "demo_2_man", "demo_3_woman", "demo_4_woman")]
RUNTIME = ["bin/service.py", "bin/provision-models.py", "etc/models.lock.json"]
COMMANDS = ["main", "install_init", "install_callback", "uninstall_init", "uninstall_callback",
            "upgrade_init", "upgrade_callback", "config_init", "config_callback"]


def archive_members(archive):
    result = {}
    for member in archive.getmembers():
        path = PurePosixPath(member.name)
        if path.is_absolute() or ".." in path.parts or member.isdev() or member.isfifo():
            raise ValueError(f"不安全的归档条目：{member.name}")
        name = str(path)
        if name in result:
            raise ValueError(f"重复归档条目：{name}")
        if member.issym() or member.islnk():
            target = PurePosixPath(member.linkname)
            if target.is_absolute() or ".." in target.parts:
                raise ValueError(f"不安全的归档链接：{name}")
        result[name] = member
    return result


def require_members(members, names):
    for name in names:
        item = members.get(name)
        if item is None or not item.isfile() or item.size <= 0:
            raise ValueError(f"归档缺少非空普通文件：{name}")


def check_fpk(path, version):
    with tarfile.open(path, "r:gz") as outer:
        entries = archive_members(outer)
        require_members(entries, ["manifest", "app.tgz", "config/privilege", "config/resource"] +
                        ["cmd/" + name for name in COMMANDS])
        manifest = {}
        for line in outer.extractfile(entries["manifest"]).read().decode().splitlines():
            if "=" in line and not line.lstrip().startswith("#"):
                key, value = line.split("=", 1)
                manifest[key.strip()] = value.strip()
        if (manifest.get("appname"), manifest.get("version"), manifest.get("platform")) != ("audiocpp", version, "x86"):
            raise ValueError("FPK manifest 的应用、版本或平台不符")
        main = outer.extractfile(entries["cmd/main"]).read()
        with tempfile.TemporaryFile() as payload:
            shutil.copyfileobj(outer.extractfile(entries["app.tgz"]), payload)
            payload.seek(0)
            with tarfile.open(fileobj=payload, mode="r:gz") as inner:
                members = archive_members(inner)
                require_members(members, CORE + ["ui/config"])
                if b"service.py" in main:
                    require_members(members, RUNTIME + ["licenses/audio.cpp/LICENSE", "build-info.json"])
                if not any(name.startswith("bin/") and "vulkan" in name and ".so" in name for name in members):
                    raise ValueError("缺少 Vulkan 后端动态库")


def check_stage(root):
    for name in CORE + RUNTIME + ["licenses/audio.cpp/LICENSE", "build-info.json"]:
        path = root / name
        if not path.is_file() or path.stat().st_size == 0:
            raise ValueError(f"缺少载荷文件：{name}")
    for path in (root / "bin").iterdir():
        if path.is_symlink():
            if not path.exists() or not path.resolve().is_relative_to(root.resolve()):
                raise ValueError(f"载荷包含损坏或外部链接：{path}")
            continue
        with path.open("rb") as stream:
            if stream.read(4) != b"\x7fELF":
                continue
        symbols = subprocess.check_output(["objdump", "-T", str(path)], text=True)
        versions = [tuple(map(int, match.split("."))) for match in re.findall(r"GLIBC_([0-9.]+)", symbols)]
        if versions and max(versions) > (2, 36):
            raise ValueError(f"{path.name} 要求 GLIBC > 2.36")
        env = {**os.environ, "LD_LIBRARY_PATH": str(root / "bin")}
        linked = subprocess.run(["/usr/bin/ldd", str(path)], env=env, text=True, capture_output=True)
        if linked.returncode or "not found" in linked.stdout + linked.stderr:
            raise ValueError(f"{path.name} 存在未解析依赖：{linked.stdout}{linked.stderr}")
        rpath = subprocess.check_output(["patchelf", "--print-rpath", str(path)], text=True).strip()
        if rpath != "$ORIGIN":
            raise ValueError(f"{path.name} RPATH 不为 $ORIGIN")
    if not list((root / "bin").glob("*vulkan*.so*")):
        raise ValueError("缺少 Vulkan 后端")


def smoke(root):
    if os.confstr("CS_GNU_LIBC_VERSION") != "glibc 2.36":
        raise ValueError("启动验证必须在 Debian 12/glibc 2.36 环境运行")
    with tempfile.TemporaryDirectory() as tmp:
        temp = Path(tmp)
        config = temp / "server.json"
        config.write_text(json.dumps({"ui": False, "lazy_load": True, "models": [
            {"id": "smoke", "family": "sense_asr", "path": str(temp / "absent.gguf"),
             "task": "asr", "mode": "streaming"}]}))
        with socket.socket() as sock:
            sock.bind(("127.0.0.1", 0))
            port = sock.getsockname()[1]
        with (temp / "server.log").open("w+") as log:
            child = subprocess.Popen([str(root / "bin/audiocpp_server"), "--no-ui", "--host", "127.0.0.1",
                                      "--port", str(port), "--backend", "cpu", "--config", str(config)],
                                     cwd=root / "bin", stdout=log, stderr=log,
                                     env={**os.environ, "LD_LIBRARY_PATH": str(root / "bin")})
            try:
                deadline = time.monotonic() + 30
                while time.monotonic() < deadline and child.poll() is None:
                    try:
                        with urllib.request.urlopen(f"http://127.0.0.1:{port}/health", timeout=1) as response:
                            if response.status == 200:
                                break
                    except (urllib.error.URLError, TimeoutError):
                        time.sleep(0.2)
                else:
                    log.seek(0)
                    raise ValueError(f"Debian 12 启动/health 验证失败：{log.read()}")
                with urllib.request.urlopen(f"http://127.0.0.1:{port}/v1/models", timeout=5) as response:
                    if not json.load(response):
                        raise ValueError("模型列表为空")
            finally:
                if child.poll() is None:
                    child.terminate()
                    try:
                        child.wait(timeout=10)
                    except subprocess.TimeoutExpired:
                        child.kill()
                        child.wait()


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--stage", type=Path)
    group.add_argument("--fpk", type=Path)
    parser.add_argument("--version")
    parser.add_argument("--smoke", action="store_true")
    args = parser.parse_args()
    if args.fpk:
        check_fpk(args.fpk, args.version)
    else:
        check_stage(args.stage)
        if args.smoke:
            smoke(args.stage)
    print("Payload checks passed")
