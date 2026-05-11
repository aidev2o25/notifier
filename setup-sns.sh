#!/usr/bin/env bash
# Bootstrap AWS SNS for sending SMS via notify.py.
# Idempotent: re-running won't duplicate the policy or user.
#
# Required:
#   Your *admin* AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY must be set in the
#   current shell. This script bootstraps a *new* limited user for notify.py.
#
# Optional env vars:
#   SNS_REGION         default us-east-1 (intentionally NOT AWS_REGION -- see below)
#   IAM_USER_NAME      default notifier-sms
#   POLICY_NAME        default NotifierSendSMS
#   POLICY_FILE        default ./policy.json
#   MONTHLY_SPEND_USD  default 1   (hard cap; AWS will stop sending past this)
#   SANDBOX_PHONE      e.g. +441234123123 -- if set, triggers sandbox verify
#
# Why SNS_REGION and not AWS_REGION:
#   AWS SNS SMS sandbox behavior varies wildly by region. us-east-1 is the
#   most permissive (no origination-identity requirement for sandbox phone
#   verification). Some regions (eu-central-1 in particular) refuse to send
#   the verification OTP without a registered sender ID / 10DLC / toll-free.
#   To avoid your shell's general AWS_REGION (e.g. set for other projects)
#   silently routing this script to a region where SMS bootstrap is broken,
#   we use a project-scoped SNS_REGION instead.
set -euo pipefail

REGION="${SNS_REGION:-us-east-1}"
IAM_USER_NAME="${IAM_USER_NAME:-notifier-sms}"
POLICY_NAME="${POLICY_NAME:-NotifierSendSMS}"
POLICY_FILE="${POLICY_FILE:-policy.json}"
MONTHLY_SPEND_USD="${MONTHLY_SPEND_USD:-1}"
SANDBOX_PHONE="${SANDBOX_PHONE:-}"

if ! command -v aws >/dev/null 2>&1; then
  echo "error: aws CLI not found. Install with: brew install awscli" >&2
  exit 1
fi
if [ ! -f "$POLICY_FILE" ]; then
  echo "error: $POLICY_FILE not found (run from repo root, or set POLICY_FILE)" >&2
  exit 1
fi

echo "==> Region: $REGION"

# 1. Create (or reuse) the IAM policy from policy.json.
POLICY_ARN=$(aws iam list-policies --scope Local \
  --query "Policies[?PolicyName=='${POLICY_NAME}'].Arn" --output text)
if [ -z "$POLICY_ARN" ] || [ "$POLICY_ARN" = "None" ]; then
  POLICY_ARN=$(aws iam create-policy \
    --policy-name "$POLICY_NAME" \
    --policy-document "file://${POLICY_FILE}" \
    --query 'Policy.Arn' --output text)
  echo "Created policy: $POLICY_ARN"
else
  echo "Policy exists: $POLICY_ARN"
fi

# 2. Create (or reuse) the dedicated IAM user.
if ! aws iam get-user --user-name "$IAM_USER_NAME" >/dev/null 2>&1; then
  aws iam create-user --user-name "$IAM_USER_NAME" >/dev/null
  echo "Created user: $IAM_USER_NAME"
else
  echo "User exists: $IAM_USER_NAME"
fi

# 3. Attach the policy (no-op if already attached).
aws iam attach-user-policy \
  --user-name "$IAM_USER_NAME" \
  --policy-arn "$POLICY_ARN"

# 4. Create an access key only if the user has none (AWS caps at 2 per user).
EXISTING_KEYS=$(aws iam list-access-keys --user-name "$IAM_USER_NAME" \
  --query 'AccessKeyMetadata[].AccessKeyId' --output text)
if [ -z "$EXISTING_KEYS" ]; then
  echo "==> New access key for $IAM_USER_NAME (AccessKeyId  SecretAccessKey):"
  aws iam create-access-key --user-name "$IAM_USER_NAME" \
    --query 'AccessKey.[AccessKeyId,SecretAccessKey]' --output text
else
  echo "Access key(s) already exist for $IAM_USER_NAME: $EXISTING_KEYS"
  echo "(Skipping creation. Secrets cannot be retrieved later -- if you've"
  echo " lost them, delete the old key with 'aws iam delete-access-key" \
       "--user-name $IAM_USER_NAME --access-key-id <id>' and re-run.)"
fi

# 5. Account-wide SMS defaults: hard spend cap + Transactional priority.
aws sns set-sms-attributes --region "$REGION" --attributes \
  MonthlySpendLimit="$MONTHLY_SPEND_USD",DefaultSMSType=Transactional
echo "SMS attributes set (cap=\$${MONTHLY_SPEND_USD}/mo, type=Transactional)"

# 6. Optional: register a sandbox phone number for testing.
# Only meaningful while the account is in the SMS sandbox. New accounts are;
# accounts that have requested production access (or are already publishing
# successfully) are not -- in that case this step is a no-op.
if [ -n "$SANDBOX_PHONE" ]; then
  IN_SANDBOX=$(aws sns get-sms-sandbox-account-status --region "$REGION" \
    --query 'IsInSandbox' --output text 2>/dev/null || echo "unknown")
  case "$IN_SANDBOX" in
    False|false)
      echo "Account is already OUT of the SMS sandbox in $REGION" \
           "-- skipping phone verification."
      ;;
    True|true)
      EXISTING_STATUS=$(aws sns list-sms-sandbox-phone-numbers --region "$REGION" \
        --query "PhoneNumbers[?PhoneNumber=='${SANDBOX_PHONE}'].Status | [0]" \
        --output text 2>/dev/null || echo "None")
      case "$EXISTING_STATUS" in
        Verified)
          echo "Phone $SANDBOX_PHONE is already verified in $REGION sandbox."
          ;;
        Pending)
          echo "Phone $SANDBOX_PHONE is already registered (Pending) in $REGION."
          echo "  When the code arrives, run:"
          echo "  aws sns verify-sms-sandbox-phone-number --region $REGION \\"
          echo "    --phone-number $SANDBOX_PHONE --one-time-password <CODE>"
          ;;
        *)
          if aws sns create-sms-sandbox-phone-number \
              --region "$REGION" --phone-number "$SANDBOX_PHONE"; then
            echo "==> Verification SMS sent to $SANDBOX_PHONE."
            echo "    When the code arrives, run:"
            echo "    aws sns verify-sms-sandbox-phone-number --region $REGION \\"
            echo "      --phone-number $SANDBOX_PHONE --one-time-password <CODE>"
          else
            echo "warning: could not register $SANDBOX_PHONE in sandbox in $REGION." >&2
            echo "         AWS in some regions now requires a registered origination" >&2
            echo "         identity (sender ID / 10DLC / toll-free) before it will send" >&2
            echo "         OTPs for sandbox verification. Workaround: verify the number" >&2
            echo "         via the SNS console:" >&2
            echo "         SNS -> Mobile -> Sandbox destination phone numbers." >&2
          fi
          ;;
      esac
      ;;
    *)
      echo "warning: could not determine sandbox status in $REGION;" \
           "skipping phone verification." >&2
      ;;
  esac
fi

echo
echo "Done. Try:"
echo "  AWS_ACCESS_KEY_ID=<above> \\"
echo "  AWS_SECRET_ACCESS_KEY=<above> \\"
echo "  NOTIFY_PHONE_NUMBER=${SANDBOX_PHONE:-+441234123123} python3 notify.py"
