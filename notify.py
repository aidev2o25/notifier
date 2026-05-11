#!/usr/bin/env python3
"""Send an SMS via AWS SNS announcing that the current process is complete.

Usage:
    AWS_ACCESS_KEY_ID=AKIA...         \\
    AWS_SECRET_ACCESS_KEY=...         \\
    NOTIFY_PHONE_NUMBER=+441234123123 \\
        python3 notify.py

Required environment variables:
    NOTIFY_PHONE_NUMBER    Destination in E.164 format, e.g. +441234123123.
    AWS_ACCESS_KEY_ID      IAM user / role access key id.
    AWS_SECRET_ACCESS_KEY  IAM user / role secret access key.

    (AWS credentials can alternatively come from an EC2/ECS instance profile,
    ~/.aws/credentials, or AWS SSO -- boto3 picks them up automatically. The
    env-var pair above is the simplest "drop onto any VM" option.)

Optional environment variables:
    SNS_REGION             SNS region (default: us-east-1). Intentionally NOT
                           AWS_REGION -- the latter is your global AWS-config
                           region (often eu-central-1 etc.), and SNS SMS
                           sandbox/origination-identity rules vary by region.
                           us-east-1 is the most permissive starting point.
                           Override with SNS_REGION=eu-west-1 etc. if needed.
    AWS_SESSION_TOKEN      Required only when using temporary STS credentials.
    NOTIFY_MESSAGE         Override the default "Process complete" body.

The script bootstraps its own dependency (boto3) into the active Python
environment on first run, so it can be dropped onto a fresh VM and just work.
"""
from __future__ import annotations

import os
import socket
import subprocess
import sys
from pathlib import Path


def _ensure_boto3() -> None:
    """Make boto3 importable, bootstrapping a sibling .venv if needed.

    The host Python is often externally-managed (Homebrew, Debian PEP 668) or
    a conda env that disallows --user installs, which makes ``pip install``
    against ``sys.executable`` unreliable. To always work, we install boto3
    into a dedicated venv next to this script and re-exec ourselves with that
    venv's interpreter.
    """
    try:
        import boto3  # noqa: F401
        return
    except ImportError:
        pass

    script_dir = Path(__file__).resolve().parent
    venv_dir = script_dir / ".venv"
    if os.name == "nt":
        venv_python = venv_dir / "Scripts" / "python.exe"
    else:
        venv_python = venv_dir / "bin" / "python"

    if not venv_python.exists():
        import venv as _venv
        _venv.create(str(venv_dir), with_pip=True, clear=False)

    subprocess.check_call(
        [
            str(venv_python),
            "-m", "pip", "install",
            "--quiet", "--disable-pip-version-check",
            "boto3",
        ]
    )

    # If we're already running under the venv python, boto3 is now installed
    # for us -- just return so main() can import it.
    if Path(sys.executable).resolve() == venv_python.resolve():
        return

    # Otherwise re-exec under the venv interpreter so the rest of the script
    # picks up boto3 from .venv/lib/.../site-packages.
    os.execv(str(venv_python), [str(venv_python), os.path.abspath(__file__), *sys.argv[1:]])


def _vm_identifier() -> str:
    """Best-effort short identifier for the machine running the script."""
    for candidate in (
        os.environ.get("HOSTNAME"),
        socket.gethostname(),
        socket.getfqdn(),
    ):
        if candidate:
            return candidate
    return "unknown-host"


def main() -> int:
    phone = os.environ.get("NOTIFY_PHONE_NUMBER", "").strip()
    if not phone:
        print(
            "error: set NOTIFY_PHONE_NUMBER to an E.164 number, "
            "e.g. +441234123123",
            file=sys.stderr,
        )
        return 2
    if not phone.startswith("+"):
        print(
            f"error: NOTIFY_PHONE_NUMBER must be E.164 (start with '+'), got {phone!r}",
            file=sys.stderr,
        )
        return 2

    _ensure_boto3()
    import boto3  # imported after install

    # Project-scoped region: ignore AWS_REGION/AWS_DEFAULT_REGION so an
    # unrelated profile region (e.g. eu-central-1) doesn't silently route us
    # somewhere SMS bootstrap is broken. Override explicitly with SNS_REGION.
    region = os.environ.get("SNS_REGION", "us-east-1")
    body = os.environ.get("NOTIFY_MESSAGE", "Process complete")
    message = f"{body} on {_vm_identifier()}"

    sns = boto3.client("sns", region_name=region)
    response = sns.publish(
        PhoneNumber=phone,
        Message=message,
        MessageAttributes={
            "AWS.SNS.SMS.SMSType": {
                "DataType": "String",
                "StringValue": "Transactional",
            }
        },
    )
    print(f"sent SMS to {phone} via {region} (MessageId={response['MessageId']}): {message}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
