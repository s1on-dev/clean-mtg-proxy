#!/usr/bin/env python3
import pathlib
import sys
try:
    import tomllib
except ModuleNotFoundError:  # Python 3.10 on Ubuntu 22.04
    import tomli as tomllib


path = pathlib.Path(sys.argv[1])
with path.open("rb") as config_file:
    config = tomllib.load(config_file)

assert config["general"]["use_middle_proxy"] is True
assert config["general"]["me2dc_fallback"] is True
assert config["general"]["me2dc_fast"] is True
assert config["general"]["modes"] == {
    "classic": False,
    "secure": True,
    "tls": False,
}
assert config["general"]["links"]["public_host"] == "203.0.113.10"
assert config["general"]["links"]["public_port"] == 8443
assert config["server"]["port"] == 3128
assert config["server"]["api"]["enabled"] is True
assert config["server"]["api"]["read_only"] is True
assert config["censorship"]["mask"] is False
assert config["censorship"]["tls_emulation"] is False
assert config["access"]["users"] == {
    "default": "0123456789abcdef0123456789abcdef",
    "family": "fedcba9876543210fedcba9876543210",
}

raw = path.read_text(encoding="utf-8")
assert "domain-fronting" not in raw
assert "sslip.io" not in raw
assert "nineseconds/mtg" not in raw
