import importlib.metadata
import logging
import os
import re
import tomllib
try:
    from dotenv import load_dotenv
except ImportError as e:
    raise ImportError(
        "python-dotenv is required by udata_hydra for .env support.\n"
        "Install it with: 'poetry add python-dotenv' or 'pip install python-dotenv'"
    ) from e
from pathlib import Path
from typing import Any

log = logging.getLogger("udata-hydra")





_ENV_RE = re.compile(r"\$\{([A-Z0-9_]+)(:-([^}]*))?\}|\$([A-Z0-9_]+)")


def _interpolate_value(val: Any) -> Any:
    """Recursively interpolate environment variables in strings.

    Supports ${VAR} and ${VAR:-default} and $VAR. Non-string values are returned unchanged.
    """
    if isinstance(val, str):
        def _repl(m: re.Match) -> str:
            # group 1 = VAR in ${VAR...}, group 3 = default if provided, group 4 = $VAR
            var = m.group(1) or m.group(4)
            default = m.group(3)
            if var in os.environ:
                return os.environ[var]
            if default is not None:
                return default
            return ""

        return _ENV_RE.sub(_repl, val)
    if isinstance(val, dict):
        return {k: _interpolate_value(v) for k, v in val.items()}
    if isinstance(val, list):
        return [_interpolate_value(x) for x in val]
    return val


class Configurator:
    """Loads a dict of config from TOML file(s) and behaves like an object, ie config.VALUE"""

    configuration: dict = {}

    def __init__(self):
        if not self.configuration:
            self.configure()

    def configure(self) -> None:
        # load .env from cwd and project root (do not override real env vars)
        cwd_dotenv = Path.cwd() / ".env"
        root_dotenv = Path(__file__).parent.parent / ".env"
        # use python-dotenv (assumed to be installed)
        try:
            load_dotenv(dotenv_path=str(cwd_dotenv), override=False)
            load_dotenv(dotenv_path=str(root_dotenv), override=False)
        except Exception:
            log.debug("python-dotenv load failed; ensure python-dotenv is installed")

        # helper to interpolate placeholders in raw TOML text before parsing
        def _interpolate_raw_toml(text: str) -> str:
            # reuse regex _ENV_RE which supports ${VAR} and ${VAR:-default} and $VAR
            def _repl(m: re.Match) -> str:
                var = m.group(1) or m.group(4)
                default = m.group(3)
                if var in os.environ:
                    return os.environ[var]
                if default is not None:
                    return default
                return ""

            return _ENV_RE.sub(_repl, text)

        # load default settings (read as text so we can interpolate placeholders before parse)
        default_path = Path(__file__).parent / "config_default.toml"
        with open(default_path, "r", encoding="utf-8") as f:
            default_text = f.read()
        default_text = _interpolate_raw_toml(default_text)
        configuration: dict = tomllib.loads(default_text)

        # override with local settings (HYDRA_SETTINGS or ./config.toml) — also interpolate
        local_settings = os.environ.get("HYDRA_SETTINGS", str(Path.cwd() / "config.toml"))
        if Path(local_settings).exists():
            with open(Path(local_settings), "r", encoding="utf-8") as f:
                local_text = f.read()
            local_text = _interpolate_raw_toml(local_text)
            configuration.update(tomllib.loads(local_text))

        # post-parse interpolation for any remaining string values (keeps backwards compatibility)
        configuration = _interpolate_value(configuration)

        # override with os env settings (respect types from defaults)
        for config_key in list(configuration.keys()):
            if config_key in os.environ:
                value: Any = os.getenv(config_key)
                # Casting env value to match default type
                default_val = configuration.get(config_key)
                if isinstance(default_val, list):
                    value = value.split(",") if value else []
                elif isinstance(default_val, bool):
                    value = value.lower() in ["true", "1", "t", "y", "yes"]
                elif isinstance(default_val, int):
                    try:
                        value = int(value)
                    except Exception:
                        # keep as string if casting fails
                        pass
                elif isinstance(default_val, float):
                    try:
                        value = float(value)
                    except Exception:
                        pass
                configuration[config_key] = value

        self.configuration = configuration
        self.check()

        # add project metadata to config
        self.configuration["APP_NAME"] = "udata-hydra"
        try:
            self.configuration["APP_VERSION"] = importlib.metadata.version("udata-hydra")
        except Exception:
            # package metadata may not be available in dev environments
            self.configuration["APP_VERSION"] = "0.0.0"

    def override(self, **kwargs) -> None:
        self.configuration.update(kwargs)
        self.check()

    def check(self) -> None:
        """Sanity check on config"""
        assert self.MAX_POOL_SIZE >= self.BATCH_SIZE, "BATCH_SIZE cannot exceed MAX_POOL_SIZE"

    def __getattr__(self, __name):
        return self.configuration.get(__name)

    @property
    def __dict__(self):
        return self.configuration

    @property
    def USER_AGENT_FULL(self) -> str:
        """Build the complete user agent string with version"""
        if self.USER_AGENT and self.APP_VERSION:
            # Use regex to find pattern: / followed by version-like string
            pattern = r"/([^/\s]+)(?=\s|$)"
            result = re.sub(pattern, f"/{self.APP_VERSION}", self.USER_AGENT)
            # If no replacement was made (no version found), append it
            if result == self.USER_AGENT:
                return f"{self.USER_AGENT}/{self.APP_VERSION}"
            return result
        return "udata-hydra"


config = Configurator()
