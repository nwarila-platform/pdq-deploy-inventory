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

| Object | State | Purpose |
|---|---|---|
| `iam-roles/nwarila-ec2-role.trust.json` | exists | The organizational default role |
| `iam-policy/nwarila-fod-read.json` | **new** | Fetch the Feature-on-Demand cab. Attach to the default |
| `iam-policy/nwarila-apprepo-read.json` | exists | Whole-bucket read, for the repository sync. Reused, not restated |
| `iam-roles/nwarila-platform_pdq-deploy-inventory_console.trust.json` | **new** | The console role, composed from the two policies above plus SSM |
| `iam-policy/…_runner_iam.json` | **amended** | The runner must be able to read and pass the new profile and role |

The last one is not optional. `iam:PassRole` on the runner names each role it may hand to EC2,
and Terraform fails with a PassRole denial on any role missing from it — so the runner policy
has to name the console role **before** the tfvars change lands.

## What is proposed here

**1. Give the organizational default the ability to fetch the FoD cab.** Attach a new
`nwarila-fod-read` to `nwarila-ec2-role`. A Windows image without OpenSSH — Server 2022 — is
unreachable until that cab is installed, so a system holding the default fails at boot on such an
image. That is a fleet gap, not an application one: any repository meeting such an image hits it,
and the natural workaround is to reach for a broader profile that happens to include the bucket.
This repository did exactly that.

**2. Replace the generic profile on the console with a composed one.** The PDQ console becomes
`nwarila-platform_pdq-deploy-inventory_console`: the baseline's policies **plus**
`nwarila-apprepo-read`, which it needs because `Sync-Repository.cmd` mirrors the whole bucket to
`F:\`. That policy is reused, not restated. This retires `nwarila-ec2-apprepo-profile`, which is
named as shared fleet infrastructure though this repository is its only consumer.

**3. Point the scan target at the default.** With the baseline able to pull the cab, the target
needs nothing repository-specific.

| Host | Profile | Because |
|---|---|---|
| `tcnaw-wks01` | `nwarila-ec2-profile` — the default | fetches one FoD cab at boot; packages arrive later over SMB from the console's share |
| `tcnaw-pdq01` | `nwarila-platform_pdq-deploy-inventory_console` | baseline, plus the whole-bucket read its repository sync needs |

### Order matters

`nwarila-ec2-role` is org-owned and shared with `secure-wazuh`. Steps are additive and read-only
on one prefix, but the sequence is strict:

1. Create `nwarila-fod-read`; attach it to `nwarila-ec2-role`.
2. Create the console role from its trust document and the profile that holds it; attach
   `AmazonSSMManagedInstanceCore`, `nwarila-fod-read` and `nwarila-apprepo-read`.
3. Publish the amended `…_runner_iam` as a new policy version, so the runner may read and pass
   the console profile and role.
4. **Then** merge the `terraform/aws.tfvars` changes.

Order is what makes this safe. Merging the tfvars change first leaves the target on a profile
with no route to the cab, and it fails at boot; leaving step 3 out means Terraform is refused
when it tries to pass the console role. Steps 1-3 change nothing on their own, so they can land
well ahead of step 4, and reverting the two tfvars lines is the rollback.

## What is deliberately NOT here

The **runner** IAM — what GitHub Actions assumes in order to deploy — lives in
`docs/reference/aws-iam/`, which also records how it was derived. This tree is about what a
deployed *machine* and the *directory* need.
