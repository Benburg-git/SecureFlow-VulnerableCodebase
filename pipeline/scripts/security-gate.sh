#!/usr/bin/env bash
set -euo pipefail

REPORT_DIR="${REPORT_DIR:-security-reports}"
PR_NUMBER="${PR_NUMBER:-}"
REPO="${GITHUB_REPOSITORY:-}"
TOKEN="${GH_TOKEN:-${GITHUB_TOKEN:-}}"

mkdir -p "$REPORT_DIR"

count_json() {
  local file="$1"
  local filter="$2"

  if [[ -f "$file" ]]; then
    jq -r "$filter" "$file" 2>/dev/null || echo 0
  else
    echo 0
  fi
}

# ---------------------------------------------------------
# DevSecOps-owned scanners (blocking on CRITICAL findings)
# ---------------------------------------------------------
# Gitleaks findings are treated as CRITICAL-equivalent because
# exposed credentials require immediate remediation.
GITLEAKS_FILE="$REPORT_DIR/gitleaks-report.json"
K8S_FILE="$REPORT_DIR/trivy-k8s-report.json"
CHECKOV_FILE="$REPORT_DIR/checkov-report.json"

secret_critical=$(count_json "$GITLEAKS_FILE" \
  'if type == "array" then length else 0 end')

k8s_critical=$(count_json "$K8S_FILE" \
  '[.Results[]?.Misconfigurations[]? | select(.Severity == "CRITICAL")] | length')

checkov_critical=$(count_json "$CHECKOV_FILE" \
  '[.results.failed_checks[]? | select(((.severity // "") | ascii_upcase) == "CRITICAL")] | length')

image_critical=0
image_high=0

shopt -s nullglob
for file in "$REPORT_DIR"/trivy-*.json; do
  [[ "$file" == *"trivy-k8s-report.json" ]] && continue

  critical_count=$(count_json "$file" \
    '[.Results[]?.Vulnerabilities[]? | select(.Severity == "CRITICAL")] | length')

  high_count=$(count_json "$file" \
    '[.Results[]?.Vulnerabilities[]? | select(.Severity == "HIGH")] | length')

  image_critical=$((image_critical + critical_count))
  image_high=$((image_high + high_count))
done

# ---------------------------------------------------------
# AppSec-owned scanners (non-blocking, mandatory handoff)
# ---------------------------------------------------------
SONAR_FILE="$REPORT_DIR/sonar-findings.json"

sonar_high=$(count_json "$SONAR_FILE" \
  '[.issues[]? | select(
      .severity == "HIGH" or
      .severity == "CRITICAL" or
      .severity == "BLOCKER" or
      .severity == "MAJOR"
    )] | length')

blocking_total=$((
  secret_critical +
  image_critical +
  k8s_critical +
  checkov_critical
))

appsec_total=$sonar_high

# ---------------------------------------------------------
# Approved exception check
# ---------------------------------------------------------
exception_approved=false

if [[ -n "$PR_NUMBER" && -n "$TOKEN" && -n "$REPO" ]]; then
  labels=$(gh api "repos/$REPO/issues/$PR_NUMBER" --jq '[.labels[].name]')

  if jq -e 'index("security-exception-approved") != null' \
    <<<"$labels" >/dev/null; then
    exception_approved=true
  fi
fi

status="PASS"

if (( blocking_total > 0 )); then
  if [[ "$exception_approved" == "true" ]]; then
    status="PASS-WITH-EXCEPTION"
  else
    status="FAIL"
  fi
fi

# ---------------------------------------------------------
# Build PR comment / summary
# ---------------------------------------------------------
cat > "$REPORT_DIR/security-gate-summary.md" <<EOF
<!-- security-gate-report -->
## Security Gate — ${status}

### DevSecOps-owned findings

| Scanner | Blocking severity | Count |
|---|---:|---:|
| Gitleaks | CRITICAL-equivalent | ${secret_critical} |
| Trivy image | CRITICAL | ${image_critical} |
| Trivy Kubernetes/IaC | CRITICAL | ${k8s_critical} |
| Checkov Terraform | CRITICAL | ${checkov_critical} |

**Blocking total:** ${blocking_total}

### AppSec-owned findings

| Scanner | Policy | Count |
|---|---|---:|
| SonarQube | Non-blocking; AppSec triage required | ${appsec_total} |

AppSec intake: https://github.com/${REPO}/issues/new?template=appsec-intake.md

Exception status: **${exception_approved}**
EOF

# ---------------------------------------------------------
# Create or update PR comment
# ---------------------------------------------------------
if [[ -n "$PR_NUMBER" && -n "$TOKEN" && -n "$REPO" ]]; then
  existing_id=$(gh api \
    "repos/$REPO/issues/$PR_NUMBER/comments" \
    --paginate \
    --jq '.[] | select(.body | contains("<!-- security-gate-report -->")) | .id' \
    | head -n1 || true)

  if [[ -n "$existing_id" ]]; then
    gh api --method PATCH \
      "repos/$REPO/issues/comments/$existing_id" \
      -f body="$(cat "$REPORT_DIR/security-gate-summary.md")" \
      >/dev/null
  else
    gh api --method POST \
      "repos/$REPO/issues/$PR_NUMBER/comments" \
      -f body="$(cat "$REPORT_DIR/security-gate-summary.md")" \
      >/dev/null
  fi
fi

cat "$REPORT_DIR/security-gate-summary.md"

# ---------------------------------------------------------
# Final differentiated gate decision
# ---------------------------------------------------------
if [[ "$status" == "FAIL" ]]; then
  echo "::error::Security gate failed: ${blocking_total} blocking DevSecOps-owned CRITICAL finding(s)."
  exit 1
fi

echo "Security gate passed with status: $status"
