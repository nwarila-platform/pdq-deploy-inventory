# Resources

**Type**: Reference. The environment artifacts this deployment DEPENDS ON but does not create.

Terraform builds instances; Ansible converges them; `pdq_ad_config` prepares the directory
objects PDQ needs. None of them provision IAM, and none of them write Group Policy. Those are an
operator's to apply, and they must exist before a deployment can succeed — so they are recorded
here rather than left as folklore.

Everything here is written with `<account-id>` as the only placeholder, matching the convention
in `docs/reference/aws-iam/README.md`. Nothing in this tree contains an account identifier.

| Directory | Holds | Applied by |
|---|---|---|
| `aws/iam-policy/` | Customer-managed policy documents | An operator, before the first deployment |
| `aws/iam-roles/` | Role trust documents | An operator |
| `aws/iam-profiles/` | Instance profiles and what they bind | An operator |
| `group policy objects/` | Policy the deployment assumes is already set | A directory administrator |
| `wmi filters/` | None exist; the absence is recorded | — |

## The instance profiles, and why they replace what is applied today

Both systems currently receive `nwarila-ec2-apprepo-profile`. It works, and it is wrong in two
ways: it is named as though it were shared fleet infrastructure when this repository is its only
consumer, and it gives a scan target the same whole-bucket read the console needs.

| | Console (`Function = pdq`) | Target (`Function = workstation`) |
|---|---|---|
| Reads | `aws s3 sync s3://<account-id>-apprepo/` into the repository share — the whole bucket, by design | one Feature-on-Demand cab under `fod/`, fetched by `user_data` at boot |
| S3 grant | `ListBucket` + `GetObject` on `*` | `GetObject` on `fod/*`; `ListBucket` conditioned on `s3:prefix = fod/*` |

Both keep `AmazonSSMManagedInstanceCore`. That is **required, not incidental**: the framework
supports four connection profiles — `ssh-direct`, `ssh-ssm`, `winrm-direct`, `winrm-ssm` — and the
two SSM ones need it. `connection_type` is a per-system choice in `terraform/aws.tfvars`, so a
profile that omits this silently removes half the supported transports.

### Migrating to them

1. Create both roles from `iam-roles/*.trust.json`.
2. Create both policies from `iam-policy/*.json`, substituting the account id.
3. Attach each policy and `AmazonSSMManagedInstanceCore` to its role, per `iam-profiles/*.json`.
4. Create the two instance profiles and add their roles.
5. Point each system in `terraform/aws.tfvars` at its own profile.

Additive throughout: nothing above modifies `nwarila-ec2-apprepo-profile`, so step 5 is the only
change with an effect and reverting it is the rollback.

## What is deliberately NOT here

The **runner** IAM — the role GitHub Actions assumes to deploy — lives in
`docs/reference/aws-iam/`, which also records how it was derived. This tree is about what a
deployed *machine* and the *directory* need; that one is about what the pipeline needs.
