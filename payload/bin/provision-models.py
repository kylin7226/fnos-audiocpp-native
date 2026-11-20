#!/usr/bin/env python3
import fcntl
import hashlib
import json
import logging
from logging.handlers import RotatingFileHandler
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile


BASES = {
    "modelscope": ("AUDIOCPP_MS_BASE_URL", "https://www.modelscope.cn/models"),
    "hf": ("AUDIOCPP_HF_BASE_URL", "https://huggingface.co"),
    "hf-mirror": ("AUDIOCPP_HF_MIRROR_BASE_URL", "https://hf-mirror.com"),
}
ORDERS = {
    "modelscope": ["modelscope", "hf", "hf-mirror"],
    "hf": ["hf", "hf-mirror", "modelscope"],
    "hf-mirror": ["hf-mirror", "hf", "modelscope"],
}


def atomic_text(path, text):
    fd, tmp = tempfile.mkstemp(prefix=path.name + ".", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            stream.write(text)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)


def verified(path, spec):
    if not path.is_file() or path.stat().st_size != spec["size"]:
        return False
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        if stream.read(4) != b"GGUF":
            return False
        stream.seek(0)
        for chunk in iter(lambda: stream.read(4 * 1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest() == spec["sha256"]


def download(url, dest, spec, logger):
    # URL + content hash isolate resumable bytes from other mirrors and revisions.
    identity = hashlib.sha256((url + spec["sha256"]).encode()).hexdigest()[:20]
    partial = dest.with_name(dest.name + "." + identity + ".part")
    if verified(partial, spec):
        os.replace(partial, dest)
        return True
    if partial.exists() and partial.stat().st_size >= spec["size"]:
        partial.unlink()
    command = ["curl", "--fail", "--location", "--show-error", "--silent",
               "--connect-timeout", "20", "--max-time", "14400",
               "--speed-limit", "1024", "--speed-time", "120",
               "--retry", "3", "--retry-delay", "5", "--continue-at", "-",
               "--max-filesize", str(spec["size"]), "--output", str(partial), url]
    child = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    try:
        output, _ = child.communicate()
    except BaseException:
        child.terminate()
        child.wait()
        raise
    if output:
        logger.info("curl: %s", output.decode(errors="replace").strip())
    if child.returncode == 0 and verified(partial, spec):
        os.replace(partial, dest)
        return True
    # A server ignoring Range needs a fresh retry, not the same failing offset forever.
    if partial.exists() and (child.returncode in (0, 33, 36) or partial.stat().st_size >= spec["size"]):
        partial.unlink()
    logger.error("下载或 SHA256/大小/GGUF 校验失败：%s", dest.name)
    return False


def provision(config, bin_dir, log_dir):
    log_dir.mkdir(parents=True, exist_ok=True)
    lock = (config.parent / ".model-download.lock").open("a")
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        lock.close()
        print("已有模型下载任务运行中；本次未启动。", file=sys.stderr)
        return 75
    with lock:
        status = log_dir / "model-download.status"
        logger = logging.getLogger("models")
        logger.setLevel(logging.INFO)
        handler = RotatingFileHandler(log_dir / "model-download.log", maxBytes=5 * 1024 * 1024,
                                      backupCount=3, encoding="utf-8")
        handler.setFormatter(logging.Formatter("%(asctime)s %(levelname)s %(message)s"))
        logger.addHandler(handler)
        atomic_text(status, "running\n")
        try:
            source = os.environ.get("AUDIOCPP_MODEL_SOURCE", "modelscope").lower()
            if source not in ORDERS:
                raise ValueError("AUDIOCPP_MODEL_SOURCE 必须是 modelscope、hf 或 hf-mirror")
            data = json.loads(config.read_text(encoding="utf-8"))
            specs = json.loads((bin_dir.parent / "etc/models.lock.json").read_text(encoding="utf-8"))
            if not isinstance(data.get("models"), list) or not data["models"]:
                raise ValueError("配置必须包含非空 models 数组")
            failed = False
            for model in data["models"]:
                raw = model.get("path")
                if not isinstance(raw, str) or not raw:
                    raise ValueError("每个模型必须包含非空 path")
                dest = Path(raw)
                if not dest.is_absolute():
                    dest = config.parent / dest
                spec = specs.get(model.get("family"))
                if not spec or dest.name != spec["filename"]:
                    logger.error("非锁定的默认模型，不自动写入：%s；请自行准备并验证自定义模型", dest)
                    failed = True
                    continue
                if verified(dest, spec):
                    logger.info("SHA256 校验通过，跳过：%s", dest)
                    continue
                if dest.exists():
                    logger.warning("现有模型校验失败，保留原文件直到替换成功：%s", dest)
                dest.parent.mkdir(parents=True, exist_ok=True)
                with dest.with_name(dest.name + ".download.lock").open("a") as model_lock:
                    fcntl.flock(model_lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    for src in ORDERS[source]:
                        key, default = BASES[src]
                        base = os.environ.get(key, default).rstrip("/")
                        if not base.startswith(("https://", "http://")):
                            raise ValueError(f"{key} 必须使用 HTTP(S)")
                        suffix = spec["modelscope" if src == "modelscope" else "hf"]
                        logger.info("尝试 %s → %s", src, dest)
                        if download(base + "/" + suffix, dest, spec, logger):
                            logger.info("校验及保存完成：%s", dest)
                            break
                    else:
                        failed = True
            atomic_text(status, "failed\n" if failed else "done\n")
            return 1 if failed else 0
        except (Exception, KeyboardInterrupt) as exc:
            logger.error("下载失败：%s", exc)
            atomic_text(status, "failed\n")
            return 1
        finally:
            logger.removeHandler(handler)
            handler.close()


def interrupted(signum, frame):
    raise KeyboardInterrupt(f"收到信号 {signum}")


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, interrupted)
    try:
        if len(sys.argv) not in (3, 4):
            raise ValueError("用法：provision-models.sh <server.json> <bin_dir> [log_dir]")
        config = Path(sys.argv[1]).resolve(strict=True)
        bin_dir = Path(sys.argv[2]).resolve(strict=True)
        logs = Path(sys.argv[3]) if len(sys.argv) == 4 else config.parent / "logs"
        sys.exit(provision(config, bin_dir, logs))
    except (OSError, ValueError) as exc:
        print(f"provision: {exc}", file=sys.stderr)
        sys.exit(1)
