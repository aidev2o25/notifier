# notifier

Send a text message via AWS SNS when computation has completed, e.g. after
training nanochat on an AI accelerator.

The repo has two pieces:

- `setup-sns.sh` — one-time bootstrap, run from your laptop with admin AWS
  credentials. Creates a dedicated, least-privilege IAM user, attaches a
  send-SMS-only policy, sets an account-wide spend cap, and (optionally)
  registers a sandbox phone number for testing.
- `notify.py` — the main script. Drop it onto any VM and run it at the end of
  your training job to get a text message.

## Prerequisites

- An AWS account.
- The `aws` CLI installed locally (`brew install awscli` on macOS).
- Admin AWS credentials exported in your current shell, *only* for the
  bootstrap step:

  ```bash
  export AWS_ACCESS_KEY_ID=AKIA...          # admin key
  export AWS_SECRET_ACCESS_KEY=...           # admin secret
  ```

  These are used once to create the limited `notifier-sms` user — they are
  *not* the credentials you ship to your training VM.

## One-time setup: `setup-sns.sh`

From the repo root:

```bash
./setup-sns.sh
```

The script is idempotent — re-running it is safe. It will:

1. Create (or reuse) an IAM policy `NotifierSendSMS` from `policy.json`,
   granting only `sns:Publish` and `sns:SetSMSAttributes`.
2. Create (or reuse) an IAM user `notifier-sms` and attach that policy.
3. Print a fresh `AccessKeyId` / `SecretAccessKey` pair for the user (only
   on the first run — AWS will not show the secret again).
4. Set account-wide SMS attributes: a `$1`/month hard spend cap and
   `Transactional` as the default message type.
5. Optionally register a phone number with the SNS SMS sandbox so you can
   test before requesting production SMS access.

Configurable via environment variables (all optional):

| Variable            | Default            | Purpose                                                 |
| ------------------- | ------------------ | ------------------------------------------------------- |
| `SNS_REGION`        | `us-east-1`        | Region for SNS. **Not** `AWS_REGION` — see note below.  |
| `IAM_USER_NAME`     | `notifier-sms`     | Name of the limited IAM user to create.                 |
| `POLICY_NAME`       | `NotifierSendSMS`  | Name of the IAM policy to create.                       |
| `POLICY_FILE`       | `./policy.json`    | Path to the policy document.                            |
| `MONTHLY_SPEND_USD` | `1`                | Hard SMS spend cap (AWS stops sending past this).       |
| `SANDBOX_PHONE`     | *(unset)*          | E.164 number to register for sandbox verification.      |

> **Why `SNS_REGION` and not `AWS_REGION`?** AWS SNS SMS sandbox behavior
> varies a lot by region. `us-east-1` is the most permissive and is the
> only region we've verified end-to-end. Some regions (notably
> `eu-central-1`) refuse to send the sandbox verification OTP without a
> registered origination identity (sender ID, 10DLC, toll-free). To keep
> your shell's general-purpose `AWS_REGION` from silently routing this
> script to a region where bootstrap is broken, we read the project-scoped
> `SNS_REGION` instead.

Example with a sandbox phone:

```bash
SANDBOX_PHONE=+441234123123 ./setup-sns.sh
```

If your account is still in the SMS sandbox, AWS will text a verification
code to that number. Complete verification with:

```bash
aws sns verify-sms-sandbox-phone-number \
  --region us-east-1 \
  --phone-number +441234123123 \
  --one-time-password <CODE>
```

Save the printed `AccessKeyId` / `SecretAccessKey` somewhere safe — you'll
need them on the VM.

## Running `notify.py`

Copy `notify.py` to the VM (e.g. via `scp`, `git clone`, or paste). It has
no install step: on first run it bootstraps a sibling `.venv` and installs
`boto3` into it, then re-execs itself. After that it just runs.

Minimal invocation:

```bash
AWS_ACCESS_KEY_ID=AKIA...          \
AWS_SECRET_ACCESS_KEY=...          \
NOTIFY_PHONE_NUMBER=+441234123123  \
    python3 notify.py
```

On success it prints something like:

```
sent SMS to +441234123123 via us-east-1 (MessageId=...): Process complete on gpu-box-01
```

### Environment variables

Required:

- `NOTIFY_PHONE_NUMBER` — destination phone number in E.164 format
  (must start with `+`, e.g. `+441234123123`).
- `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` — the keys printed by
  `setup-sns.sh`. Alternatively, boto3 will pick up credentials from an
  EC2/ECS instance profile, `~/.aws/credentials`, or AWS SSO.

Optional:

- `SNS_REGION` — defaults to `us-east-1`. Must match the region where you
  ran `setup-sns.sh` (the SMS spend cap and sandbox state are per-region).
  Intentionally **not** `AWS_REGION` — see the note in the setup section.
- `AWS_SESSION_TOKEN` — only needed for temporary STS credentials.
- `NOTIFY_MESSAGE` — override the default `"Process complete"` body. The
  hostname of the sending machine is appended automatically.

### Typical use: chain after a long-running command

```bash
python train.py && \
NOTIFY_PHONE_NUMBER=+441234123123 \
AWS_ACCESS_KEY_ID=AKIA... \
AWS_SECRET_ACCESS_KEY=... \
    python3 notify.py
```

Or unconditionally, so you also get notified on failure:

```bash
python train.py; \
NOTIFY_MESSAGE="train.py exited $?" \
NOTIFY_PHONE_NUMBER=+441234123123 \
AWS_ACCESS_KEY_ID=AKIA... \
AWS_SECRET_ACCESS_KEY=... \
    python3 notify.py
```

## SMS sandbox vs. production

New AWS accounts start in the SNS SMS sandbox: you can only send to phone
numbers you've explicitly verified (see `SANDBOX_PHONE` above). That's
usually fine for "text *me* when training is done." If you need to text
arbitrary numbers, request production SMS access in the SNS console
(Mobile → SMS → "Exit SMS sandbox"). The `$1`/month spend cap will still
protect you from runaway costs.
