#!/usr/libexec/platform-python
"""Configuration for the NovaSeq X upload service, loaded from config.ini."""

import configparser
from pathlib import Path
from typing import NamedTuple

DEFAULT_CONFIG_PATH = Path(__file__).resolve().parent / "config.ini"


class ConfigError(Exception):
    pass


class Config(NamedTuple):
    server_url: str
    auth_token: str
    max_parallel_uploads: int
    upload_max_attempts: int
    retry_base_delay: float
    upload_timeout: float
    lama_base_url: str
    lama_endpoint: str
    lama_max_attempts: int
    http_timeout: float
    mnt_runs_root: str
    local_runs_root: str
    poll_interval: int


def load_config(path=None, require_credentials=True):
    """Load config.ini. ``path`` is for tests only, prod expects the config.ini file next to this script"""
    cfg_path = Path(path).expanduser() if path else DEFAULT_CONFIG_PATH
    if not cfg_path.is_file():
        raise ConfigError(
            "Config file not found: {} — it must live next to these scripts.".format(cfg_path))
    parser = configparser.ConfigParser()
    parser.read(str(cfg_path))
    config = Config(
        server_url=parser.get("upload", "server_url", fallback="").strip(),
        auth_token=parser.get("upload", "auth_token", fallback="").strip(),
        max_parallel_uploads=parser.getint("upload", "max_parallel_uploads", fallback=6),
        upload_max_attempts=parser.getint("upload", "upload_max_attempts", fallback=3),
        retry_base_delay=parser.getfloat("upload", "retry_base_delay", fallback=5.0),
        upload_timeout=parser.getfloat("upload", "upload_timeout", fallback=3600.0),
        lama_base_url=parser.get("lama", "base_url", fallback="http://lama.prod-1").rstrip("/"),
        lama_endpoint=parser.get("lama", "lama_sequencing_endpoint", fallback="api/sequencing/sequencing-run-data").strip("/"),
        lama_max_attempts=parser.getint("lama", "lama_max_attempts", fallback=3),
        http_timeout=parser.getfloat("lama", "http_timeout", fallback=300.0),
        mnt_runs_root=parser.get("paths", "mnt_runs_root", fallback="/usr/local/illumina/mnt/runs").rstrip("/"),
        local_runs_root=parser.get("paths", "local_runs_root", fallback="/usr/local/illumina/runs").rstrip("/"),
        poll_interval=parser.getint("monitor", "poll_interval", fallback=900),
    )
    if require_credentials:
        missing = [key for key, value in (("server_url", config.server_url), ("auth_token", config.auth_token)) if not value]
        if missing:
            raise ConfigError("Config missing required key(s) for a real run: " + ", ".join(missing))
    return config
