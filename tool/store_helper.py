#!/usr/bin/env python3
"""Snap Store requests for Confdb Studio, using surl's macaroon handling.

The app runs this with the surl venv on PYTHONPATH and talks JSON:

  store_helper.py whoami
  store_helper.py login            stdin: {"email", "password", "otp"?, "store"?}
  store_helper.py logout
  store_helper.py request METHOD PATH [CONTENT_TYPE]    stdin: request body

Credentials are a surl config file (root and discharge macaroons, and the
store environment) at $CONFDB_STORE_AUTH, readable only by the user.

Every command prints one JSON object on stdout: {"status", "body"} for an
HTTP response, or {"error", "code"} when it couldn't make one.
"""

import json
import os
import sys

import requests
import surl
from pymacaroons import Macaroon

TIMEOUT = 60


class Failure(Exception):
    def __init__(self, message, code="error"):
        super().__init__(message)
        self.code = code


def auth_path():
    path = os.environ.get("CONFDB_STORE_AUTH")
    if not path:
        raise Failure("CONFDB_STORE_AUTH isn't set.", "config")
    return path


def load():
    path = auth_path()
    if not os.path.exists(path):
        raise Failure("Not signed in to the Snap Store.", "not-logged-in")
    try:
        return surl.load_config(path)
    except (surl.ConfigError, KeyError, OSError):
        raise Failure("The saved Snap Store login is unreadable. Sign in again.", "not-logged-in")


def save(config):
    os.makedirs(os.path.dirname(config.path), mode=0o700, exist_ok=True)
    # Macaroons are bearer credentials: keep the file private from the start.
    fd = os.open(config.path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    os.close(fd)
    surl.save_config(config)


def base_url(store_env):
    return surl.CONSTANTS[store_env]["sca_base_url"]


def respond(response):
    return {"status": response.status_code, "body": response.text}


def sso_error(response):
    try:
        data = response.json()
    except ValueError:
        return Failure("Ubuntu One answered {}.".format(response.status_code))
    code = data.get("code") or "error"
    message = data.get("message") or data.get("title") or "Ubuntu One answered {}.".format(response.status_code)
    return Failure(message, {
        "TWOFACTOR_REQUIRED": "twofactor-required",
        "TWOFACTOR_FAILURE": "twofactor-failed",
        "INVALID_CREDENTIALS": "invalid-credentials",
        "ACCOUNT_SUSPENDED": "account-suspended",
        "ACCOUNT_DEACTIVATED": "account-deactivated",
        "PASSWORD_POLICY_ERROR": "password-policy",
    }.get(code, code.lower()))


def login(args):
    """surl's email login (`surl -e <email> -s <store> -a <ident>`), with the
    password and one-time code from stdin instead of a terminal prompt."""
    creds = json.load(sys.stdin)
    store_env = creds.get("store") or "production"
    if store_env not in ("production", "staging"):
        raise Failure("Unknown store {!r}.".format(store_env), "config")
    constants = surl.CONSTANTS[store_env]
    headers = surl.DEFAULT_HEADERS.copy()

    response = requests.post(
        "{}/dev/api/acl/".format(constants["sca_base_url"]),
        json=surl._get_authorization_payload(None, None, None, None),
        headers=headers,
        timeout=TIMEOUT,
    )
    if response.status_code != 200:
        try:
            title = response.json().get("title")
        except ValueError:
            title = None
        raise Failure(title or "The Snap Store answered {}.".format(response.status_code))
    root = response.json()["macaroon"]
    (caveat,) = [c for c in Macaroon.deserialize(root).third_party_caveats() if c.location == constants["sso_location"]]

    sso = {"email": creds["email"], "password": creds["password"], "caveat_id": caveat.caveat_id}
    if creds.get("otp"):
        sso["otp"] = creds["otp"]
    response = requests.post(
        "{}/api/v2/tokens/discharge".format(constants["sso_base_url"]), json=sso, headers=headers, timeout=TIMEOUT
    )
    if response.status_code != 200:
        raise sso_error(response)
    discharge = response.json()["discharge_macaroon"]

    save(surl.ClientConfig(root=root, discharge=discharge, store_env=store_env, path=auth_path()))
    return whoami(args)


def logout(_args):
    try:
        os.remove(auth_path())
    except FileNotFoundError:
        pass
    return {"status": 200, "body": "{}"}


def request(method, path, content_type=None, body=None):
    config = load()
    headers = surl.DEFAULT_HEADERS.copy()
    if content_type:
        headers["Content-Type"] = content_type
    headers.update(surl.get_authorization_header(config.root, config.discharge, store_env=config.store_env))
    # store_request refreshes an expired discharge and saves it.
    response = surl.store_request(
        config,
        url=base_url(config.store_env) + path,
        method=method,
        data=body,
        headers=headers,
        timeout=TIMEOUT,
    )
    result = respond(response)
    result["store"] = config.store_env
    return result


def whoami(_args):
    return request("GET", "/api/v2/tokens/whoami")


def raw_request(args):
    if len(args) < 2:
        raise Failure("usage: request METHOD PATH [CONTENT_TYPE]", "usage")
    method, path = args[0], args[1]
    content_type = args[2] if len(args) > 2 else None
    body = sys.stdin.buffer.read() or None
    return request(method, path, content_type, body)


COMMANDS = {"whoami": whoami, "login": login, "logout": logout, "request": raw_request}


def main(argv):
    if len(argv) < 2 or argv[1] not in COMMANDS:
        result = {"error": "usage: store_helper.py {}".format("|".join(COMMANDS)), "code": "usage"}
    else:
        try:
            result = COMMANDS[argv[1]](argv[2:])
        except Failure as e:
            result = {"error": str(e), "code": e.code}
        except requests.exceptions.ConnectionError:
            result = {"error": "Couldn't reach the Snap Store. Check your connection.", "code": "offline"}
        except requests.exceptions.Timeout:
            result = {"error": "The Snap Store didn't answer in time.", "code": "offline"}
        except Exception as e:  # report, don't print a traceback the app can't parse
            result = {"error": "{}: {}".format(type(e).__name__, e), "code": "error"}
    json.dump(result, sys.stdout)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
