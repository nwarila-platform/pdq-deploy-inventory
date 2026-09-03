# Resources

**Type**: Reference. The environment artifacts this deployment DEPENDS ON but does not create.

Terraform builds instances, Ansible converges them, and `pdq_ad_config` prepares the directory
objects PDQ needs. None of them provision IAM and none write Group Policy. Those are an
operator's to apply and must exist before a deployment can succeed, so they are recorded here
rather than left as folklore.

`<account-id>` is the only placeholder, matching `docs/reference/aws-iam/README.md`. Nothing in
this tree contains an account identifier.

| Directory | Holds |
|---|---|
| `aws/iam-policy/` | Policy documents an operator applies |
| `aws/iam-profiles/` | Which role each instance profile holds, and how it is composed |
| `aws/iam-roles/` | Role trust documents |
| `group policy objects/` | Policy the deployment assumes is already set |
| `wmi filters/` | None exist; the absence is recorded |

## The IAM this deployment touches

Exported from the live account on 2026-09-03, with `<account-id>` substituted. Names follow
`nwarila-platform_<scope>_<principal>_<service>`; a role and the profile holding it share a name.

| Role | Trust | Policies | Does |
|---|---|---|---|
| `…_pdq-deploy-inventory_runner` | GitHub OIDC | eight `runner_*` | Deploy, converge, prove, destroy |
| `…_pdq-deploy-inventory_reaper` | GitHub OIDC | six `reaper_*` | Sweep what a killed run left behind |
| `…_pdq-deploy-inventory_admin` | GitHub OIDC | the runner's eight plus `admin_s3` | Operator deploy and artifact publishing |
| `…_instance-baseline_ec2` | EC2 | SSM, `…_instance-baseline_ec2_s3` | **Proposed.** Every managed machine |
| `…_pdq-deploy-inventory_ec2` | EC2 | the two above, plus `…_pdq-deploy-inventory_ec2_s3` | **Proposed.** The PDQ console |

Three files are not verbatim exports, and each says so in its own text:

- `…_instance-baseline_ec2_s3` and its role, profile and trust are **new** — the baseline tier.
- `…_pdq-deploy-inventory_ec2*` are the existing `nwarila-ec2-apprepo-*` objects renamed into the
  fleet pattern and given a repository-scoped policy in place of the org-level one.
- `…_runner_iam` and `…_reaper_iam` are **amended**: both enumerate the profiles and roles they
  may read or pass, by ARN, so Terraform and the reaper are refused on anything missing from
  them. That is what makes the ordering below strict rather than advisory.

Version drift is real, which is why these were taken from the live account rather than the
checked-in reference: that reference documents a role which does not exist and an instance profile
the deployment does not use, and several live policies are far past v1 — `runner_s3` is at v16.

## What is proposed here

**1. A baseline tier every managed machine can hold.** `…_instance-baseline_ec2`, carrying SSM
and a read scoped to `fod/*`. Without it a Server 2022 image is unreachable, and the workaround is
always to reach for something broader.

**2. The PDQ console tier, composed from it.** `…_pdq-deploy-inventory_ec2` carries the
baseline's policies plus a whole-bucket read for `Sync-Repository.cmd`.

**3. The scan target drops to the baseline.** It fetches one cab at boot; packages reach it later
over SMB from the console's share, never from S3.

| Host | Profile |
|---|---|
| `tcnaw-pdq01` | `nwarila-platform_pdq-deploy-inventory_ec2` |
| `tcnaw-wks01` | `nwarila-platform_instance-baseline_ec2` |

### Order matters

1. Create the baseline role, its policy, and the profile that holds it.
2. Create the PDQ role and profile; attach SSM and both `_ec2_s3` policies.
3. Publish the amended `…_runner_iam` and `…_reaper_iam` as new policy versions.
4. **Then** merge the `terraform/aws.tfvars` changes.

Steps 1-3 change nothing on their own and can land well ahead of step 4. Merging step 4 first
leaves both hosts on profiles that do not exist; skipping step 3 has Terraform refused when it
tries to pass the new roles. Reverting the two tfvars lines is the rollback.

## What is deliberately NOT here

The **runner** IAM — what GitHub Actions assumes in order to deploy — lives in
`docs/reference/aws-iam/`, which also records how it was derived. This tree is about what a
deployed *machine* and the *directory* need.
