# AWS IAM — roles and policies (pdq-deploy-inventory)

**Type**: Reference (Diátaxis). The IAM used by this repository's ephemeral AWS PoC. An operator
provisions the roles and policies; Terraform does not manage them.

Cloned from `secure-wazuh` and **hardened during the clone** against four rounds of dual independent
audit. This document's most important section is the
[substitution contract](#substitution-contract) — read it before applying anything.

## Substitution contract

Every per-environment value in these sources is a `<placeholder>`. **Nothing here is a real
identifier.** That is deliberate: a `<...>` token can never match a real tag value, ARN, subject or
account, so an unsubstituted placeholder **fails closed** — the API rejects it and you find out
immediately.

The failure this contract exists to prevent is the opposite one. A *partial* substitution — the
right value in the Allows, a stale sibling value left in one condition or Deny — **fails open and
silently**: this repo's deploy still works while it holds authority over a sibling repository's live
resources in the shared account. Reading the applied policy back and diffing it against your
materialized copy **cannot** catch that, because the materialized copy is what is wrong.

| Placeholder | Substitute with | Source of truth | If you miss it |
|---|---|---|---|
| `<account-id>` | the 12-digit AWS account id | `aws sts get-caller-identity` | **fail-closed** — non-matching ARNs, or `MalformedPolicyDocument` at apply |
| `<repository-id>` | this repo's **immutable** GitHub repository id | `gh api repos/nwarila-platform/pdq-deploy-inventory --jq .id` | **fail-closed** if wholly absent — **FAIL-OPEN if a sibling's id is left in even one statement** (see below) |
| `<region>` | the deploy region | the deploy plan (`us-east-1`) | fail-closed |
| `<vpc-id>` | the deploy VPC | Layer-0 bootstrap output | fail-closed if absent. **Verified 2026-07-29: this account has ONE VPC**, so every sibling materializes the same value — it is shared infrastructure, not a per-repo literal |
| `<subnet-id>` | the deploy subnet | Layer-0 bootstrap output | as above — **one subnet account-wide**, shared by all siblings |
| `<ebs-kms-key-id>` | the key `alias/aws/ebs` resolves to **in this account** | `aws kms describe-key --key-id alias/aws/ebs` | fail-closed. Account-wide and AWS-managed, so **siblings legitimately share the same key id** |
| `<key-pair-name>` | this repo's EC2 key pair | Layer-0 bootstrap output | fail-closed at launch |

Because the VPC, subnet and EBS key are account-wide, **the identity tag is the only thing separating
the sibling repositories from each other.** The `ec2:Subnet` pin bounds every repo to the same deploy
subnet; it does not hold them apart. That raises the stakes on the next paragraph rather than easing
them.

**`<repository-id>` is the one that can hurt you.** It is the sole authorization key for
`LifecycleOnlyOnOurTaggedResources` (terminate / delete-volume / detach) and
`SsmSessionOnlyToOurTaggedInstances` (an interactive shell). A sibling's id left in either statement
gives this repository's CI role destroy authority and a shell over that sibling's running
infrastructure. Substitute it everywhere in one operation and let the gate prove it.

### The gate — run it, do not eyeball it

```bash
./scripts/check-iam-literals.sh                      # CI: sources carry placeholders, no foreign literals
./scripts/check-iam-literals.sh --materialized DIR   # pre-apply: DIR is fully substituted
```

Materialize into one untracked directory, substitute every placeholder in a single pass, run the
gate in `--materialized` mode, and only then apply. **A non-zero exit means do not apply.** The gate
also refuses any twelve-digit value in the tracked sources, which is what keeps a real account id
out of git.

## Role-to-policy map

| Role | Trust source | Policies | Purpose |
|---|---|---|---|
| `github_nwarila-platform_pdq-deploy-inventory` | `roles/github_nwarila-platform_pdq-deploy-inventory.trust.json` | `github_nwarila-platform_pdq-deploy-inventory` · `pdq-deploy-inventory_deploy-ec2-launch` · `pdq-deploy-inventory_deploy-ec2-lifecycle` · `pdq-deploy-inventory_deploy-sg-ssm-kms` · `pdq-deploy-inventory_deploy-discovery-iam` | CI state, deploy, prove, destroy |
| `github_nwarila-platform_pdq-deploy-inventory-admin` | `roles/github_nwarila-platform_pdq-deploy-inventory-admin.trust.json` | `github_nwarila-platform_pdq-deploy-inventory` · the same four deploy policies · `pdq-deploy-inventory_artifact-read` | Operator break-glass and local deploy |
| `pdq-deploy-inventory-poc-role` | `roles/pdq-deploy-inventory-poc-role.trust.json` | `AmazonSSMManagedInstanceCore` (AWS-managed) **only** | EC2 instance profile `pdq-deploy-inventory-poc-profile` |

The `-admin` role carries the state policy as well as the four deploy policies: a local
`deploy -> test -> destroy` cannot read or write Terraform state without it, and the row above
claims that capability. It alone also carries `pdq-deploy-inventory_artifact-read`, which reads the
pinned `applications/pdq/*` artifact prefix from the controller. CI is excluded to keep it
least-privilege until Phase 2 genuinely needs that read. `scripts/bootstrap-iam.sh` attaches the
four deploy policies to both roles, while its admin-only class removes the artifact-read policy
from the CI and instance roles before attaching it to `-admin`. Detach the deploy policies when the
local path is retired.
`MaxSessionDuration` is 3600 seconds on all three roles — the AWS default, materialized as a
role property rather than inside any document here.

The instance role carries **exactly one** AWS-managed policy and no inline policy. It holds no S3
access of any kind — see [what this clone deliberately drops](#what-this-clone-deliberately-drops).

### The broker permission set — the half of this setup that is not in any repository

**Provisioning the `-admin` role does not make it assumable.** Its trust document names
`"Principal": {"AWS": "arn:aws:iam::<account-id>:root"}`, which *delegates* the decision to IAM
rather than granting it. The SSO identity must therefore **also** be allowed `sts:AssumeRole` by an
identity policy — and that policy lives in Identity Center, outside every repository in this org.

It is the inline policy of the **`github_nwarila-platform` permission set** (statement
`AssumeThisOrgsRepoAdminRoles`), which **enumerates repo-admin role ARNs explicitly**. A role absent
from that list is unassumable no matter how correct everything in this directory is.

The symptom is indistinguishable from a broken trust policy:

```
AccessDenied ... is not authorized to perform: sts:AssumeRole on resource:
arn:aws:iam::<account-id>:role/github_nwarila-platform_pdq-deploy-inventory-admin
```

There is no trailing `because no identity-based policy allows ...` clause — `sts:AssumeRole` omits
it — so the message does not tell you which half failed. **Do not start by editing the trust.**

**Diagnose in one command.** Assume a *sibling's* `-admin` role from the same SSO session. Every
repo-admin trust in this account is byte-identical, so if the sibling works and this one does not,
the difference is the broker allowlist and nothing here is wrong:

```bash
aws sts get-caller-identity --profile repoadmin-nwarila-platform-secure-wazuh   # known-good sibling
aws iam get-role-policy --profile admin --policy-name AwsSSOInlinePolicy \
    --role-name "$(aws iam list-roles --profile admin --path-prefix /aws-reserved/sso.amazonaws.com/ \
        --query "Roles[?starts_with(RoleName,'AWSReservedSSO_github_nwarila-platform_')].RoleName | [0]" \
        --output text)"
```

**Fix** — privileged, needs the `AdministratorAccess` permission set. `put-inline-policy` **replaces
the whole document**, so include the ARNs already present:

```bash
INST=$(aws sso-admin list-instances --profile admin --query 'Instances[0].InstanceArn' --output text)
PS=...    # the permission set named github_nwarila-platform (sso-admin describe-permission-set)
aws sso-admin put-inline-policy-to-permission-set --profile admin \
    --instance-arn "$INST" --permission-set-arn "$PS" --inline-policy file://broker-inline.json
aws sso-admin provision-permission-set --profile admin \
    --instance-arn "$INST" --permission-set-arn "$PS" \
    --target-id <account-id> --target-type AWS_ACCOUNT
```

**Never** write it with `aws iam put-role-policy` against the `AWSReservedSSO_*` role. That appears
to work and is silently reverted the next time Identity Center provisions the permission set.

Verified 2026-07-30: this step was missed when both this repo's and `windows-wsus`'s `-admin` roles
were created — only `secure-wazuh` and `github-terraform-runner` were on the list, so both clones
were undiagnosably unassumable while every repo-side check passed. **Adding the ARN is part of
creating the role, not a follow-up.**

## Hardening applied during the clone

These close audit findings that are **still open in the source repository**. They are not optional
polish; each one is a finding both auditors raised.

- **Every literal is a placeholder** (R3-1/2/3/7, R4-1). The source repo placeholders only the
  account id; this clone placeholders all seven, so partial substitution becomes fail-closed.
- **`ec2:Encrypted: true` is required** on `RunInstancesVolumeCapped` and `CreateDataVolumeCapped`
  (R3-6). The source permits EBS encryption but never requires it, so omitting the KMS alias
  silently creates unencrypted volumes. PDQ carries the Deploy and Inventory SQLite databases and the
  application repository; encryption at rest is not optional here.
- **The ENI leg is subnet-pinned** via `ArnLike ec2:Subnet` (R3-4). VPC-pinning alone left a
  same-VPC foreign network interface attachable at launch, which would hand the instance another
  workload's address and security groups.
- **The SSO trust is bounded to the permission-set hash**, `AWSReservedSSO_github_nwarila-platform_`
  + sixteen `?` (R3-8). The source uses a trailing `*`, which also matches any future permission set
  named `github_nwarila-platform_<something>` — including a low-privilege one.
- **`job_workflow_ref` is single-valued** (R3-2), so there is no array shape teaching a cloner to
  *append* — an appended trust leaves the sibling repository trusted. Replace it wholesale.
  **`sub` deliberately lists BOTH subject forms.** GitHub emits the ID-embedded subject
  `repo:<owner>@<owner-id>/<repo>@<repository-id>:<context>` for repositories created after roughly
  2026-07-15 — proven from the CloudTrail `userName` on a real denied `AssumeRoleWithWebIdentity`,
  not inferred. An earlier audit finding called that subject dead and a single-valued `sub`
  de-credentialed CI in all three repositories until it was corrected. `repository_id` with
  `StringEquals` is the actual identity boundary, so carrying both forms costs nothing and survives
  a repository transfer.
- **IMDS hop limit pinned to 1** at launch and on modify (R3-14), so IMDS cannot be extended past
  the host network stack.
- **Denies carry no substitutable narrowing** (R3 F11). The state Denies dropped
  `aws:ResourceAccount`; the resource ARN already pins the bucket, and a Deny that depends on a
  second substitution is a Deny that can be switched off by a typo.
- **`aws-marketplace` is not a trusted image owner** (R4-2). It is an open publisher namespace.
  This repo launches Windows Server images published under the `amazon` alias, so the owner list is
  `amazon` plus this account — no marketplace entry, and the finding closes for free.
  **Trap:** do not write `self` for images this account builds. `self` is a `DescribeImages`
  *request parameter*; the `ec2:Owner` condition key accepts only `amazon`, `aws-marketplace`, or an
  account id. A policy containing `self` does not error — it silently never matches.
- **`env:/*` is not in the state-bucket list prefix** (R3 LOW). Terraform runs in the default
  workspace here, and that prefix would enumerate every other repository's workspace keys.
- **IAM ARNs name the account** rather than `*`, so a mis-materialized reference fails closed.
- **The EC2 policy ships split** into `-launch` (authorizing new resources into existence) and
  `-lifecycle` (tagging, the identity Denies, and mutation of resources we already own). Combined and
  materialized it measured 5,900 of the 6,144-character managed-policy limit — 96%, against a house
  rule of *split at 85%, never trim a control*. The source repo carries it combined at ~92% and has
  already had to defer fixes for want of room. Split now, before either clone extends it: the halves
  measure ~2.6 KB and ~3.3 KB. Each role has ten managed-policy slots; these deploy-facing policies
  use five on the admin role, including the admin-only artifact read, and four on CI. Attach both
  EC2 halves; they are one boundary in two documents. Do not recombine them.

## What this clone deliberately drops

Both auditors, independently, recommended that the Windows consumers drop the presigned,
target-side artifact-delivery path. This clone still has **no artifact-reader role or trust,
presigned-URL signer, or target-side fetch tasks**. It now has one narrower replacement: the
operator role can read only the pinned `applications/pdq/*` prefix from the controller, which then
pushes the file to the guest.

The read policy applies the relevant R4-4 correction directly: `s3:GetObject` is limited to that
single prefix, with no `s3:GetObjectVersion`, and the bucket listing is prefix-bounded. R4-3 and
R4-5 remain inapplicable because no bearer URL is created or delivered to the target; R4-7 does not
apply because there is no reader role or new `AssumeRole` session; and R4-8/R4-9 remain inapplicable
because there is no signer module. The R4-6 property is preserved: the instance profile is
`AmazonSSMManagedInstanceCore` and nothing else, so **no credential on the target can reach S3 at
all.**

## Values re-derived for this repository (never copied)

| Value | This repo | Why not the source's |
|---|---|---|
| Instance types | `t3.medium`, `t3.large` | Windows Server all-in-one running two PDQ services. The source's `m6i.xlarge` is a 4-vCPU SIEM node |
| Volume cap | 64 GiB | Largest single volume is the ~50 GiB Windows root, plus headroom. The three data disks are 20 GiB `PDQDEPLOY` (E:) / 20 GiB `PDQINVENTORY` (F:) / 30 GiB `PDQSHARE` (G:). The source's 100 GiB over-grants ~5× against these |
| IOPS / throughput | 3000 / 125 | gp3 defaults; `NumericLessThanEqualsIfExists` is intentional so an unspecified input inherits the default rather than failing |
| Ingress | TCP 7337 (PDQ Central Server) | The source's 1514/1515/443 are Wazuh agent and dashboard ports |
| State prefix | `nwarila-platform/pdq-deploy-inventory/` | Per repository, in Allows **and** Denies together |

**IAM does not enforce the ingress ports.** Security-group *rules* are Terraform configuration; IAM
governs who may manage the groups. Treat the rule set as code-reviewed, not policy-enforced.

## Known residuals (accepted, recorded rather than hidden)

- **Public IP association is not denied.** SSM is reached over the internet gateway from a public
  subnet, so `ec2:AssociatePublicIpAddress: false` would block every run. The structural fix is a
  private subnet with VPC endpoints, which is the recommended target for this repo; the role holds
  no EIP, internet-gateway or route-table actions, so a private subnet cannot be re-opened from
  inside this boundary.
- **`security-group-rule/*` is region-scoped.** Every rule action also authorizes against the parent
  `security-group/*` leg, which is tag- and VPC-pinned, so a foreign rule cannot be reached without
  its foreign parent. EC2 exposes VPC context on the parent group, not the rule resource — this is
  why it looks loose and is not.
- **SSM session teardown is region-scoped.** An assumed role's `${aws:userid}` is
  `<role-id>:<session-name>`, which is not an SSM session-id prefix, so using it to narrow the ARN
  would silently deny legitimate teardown.
- **IAM cannot cap instance count or total spend.** A service quota and a budget alarm are separate
  account-side backstops and must exist before they can be relied on. Derive the vCPU quota from
  this repo's actual instance set — do not copy a number from another repository's README.
