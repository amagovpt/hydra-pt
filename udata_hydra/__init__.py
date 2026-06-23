import importlib.metadata
import logging
import os
import re
import tomllib
from pathlib import Path

log = logging.getLogger("udata-hydra")


class Configurator:
    """Loads a dict of config from TOML file(s) and behaves like an object, ie config.VALUE"""

    configuration: dict = {}

    def __init__(self):
        if not self.configuration:
            self.configure()

    def configure(self) -> None:
        # load default settings
        with open(Path(__file__).parent / "config_default.toml", "rb") as f:
            configuration: dict = tomllib.load(f)

        # override with local settings
        local_settings = self._local_settings_path()
        if local_settings:
            with open(local_settings, "rb") as f:
                configuration.update(tomllib.load(f))
            log.info("Loaded local settings from %s", local_settings)
        else:
            log.warning(
                "No local config.toml found (set HYDRA_SETTINGS or place config.toml "
                "in the working directory); using config_default.toml only."
            )

        self.configuration = configuration
        self.check()

        # add project metadata to config
        self.configuration["APP_NAME"] = "udata-hydra"
        self.configuration["APP_VERSION"] = importlib.metadata.version("udata-hydra")

    @staticmethod
    def _local_settings_path() -> Path | None:
        """Resolve the local settings file (config.toml) overriding the defaults.

        Lookup order:
          1. the HYDRA_SETTINGS env var (explicit path, always wins);
          2. config.toml in the current working directory (where the command runs);
          3. config.toml next to the project root (so it is found regardless of cwd,
             e.g. when launched by systemd/gunicorn from another directory).

        Returns the first existing path, or None when no local settings exist.
        """
        env_path = os.environ.get("HYDRA_SETTINGS")
        candidates = (
            [Path(env_path)]
            if env_path
            else [Path.cwd() / "config.toml", Path(__file__).parent.parent / "config.toml"]
        )
        return next((path for path in candidates if path.exists()), None)

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
