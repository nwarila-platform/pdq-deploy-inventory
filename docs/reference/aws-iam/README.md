# AWS IAM reference

The IAM this deployment runs with, **exported from the live account** on 2026-09-14. The account
id is the only substitution, written as `<account-id>`. [`manifest.json`](manifest.json) records the
default version of every policy exported.

Terraform does not manage any of this; an operator applies it. After changing IAM, export the
changed documents from the account rather than editing these by hand: two hand-maintained copies
drifted, one scoped to a repository id that no longer exists and the other holding amendments that
were never applied.

## Roles

| Role | Trusted by | Attached policies | Does |
|---|---|---|---|
| `nwarila-platform_pdq-deploy-inventory_runner` | GitHub OIDC: `aws-deploy.yml` on `main` | the eight `…_runner_*` | Provision, converge, prove, destroy |
| `nwarila-platform_pdq-deploy-inventory_reaper` | GitHub OIDC: `aws-reaper.yml` on `main` | the six `…_reaper_*` | Destroy what a killed run left behind |
| `nwarila-platform_pdq-deploy-inventory_admin` | The `github_nwarila-platform` IAM Identity Center permission set | the runner's eight, plus `…_admin_s3` | Operator deploys and artifact publishing |
| `nwarila-ec2-apprepo-role` | EC2, through `nwarila-ec2-apprepo-profile` | `AmazonSSMManagedInstanceCore`, `nwarila-apprepo-read` | What both deployed hosts run as |

None of the roles carries an inline policy.

## Boundaries in the documents

- Every statement is `Allow`; none is `Deny`.
- **The OIDC trusts** require the `sts.amazonaws.com` audience, this repository's id
  (`1347369220`), the `refs/heads/main` ref, one of the two `sub` forms GitHub issues for it, and a
  `job_workflow_ref` naming the one workflow that role belongs to. A branch, a fork or another
  workflow in this repository cannot assume either role.
- **The operator trust** names this account and limits `aws:PrincipalArn` to the role IAM Identity
  Center generates for the `github_nwarila-platform` permission set; each `?` in its `ArnLike`
  pattern matches one character of the generated suffix.
- **Launching an instance** requires the `Repository`, `RepositoryId`, `ManagedBy`, `CommitSha`,
  `RunId` and `Environment` request tags. Operations on existing instances, network interfaces,
  security groups and volumes are conditioned on the `RepositoryId` resource tag.
- **Passing a role** is limited to `nwarila-ec2-role` and `nwarila-ec2-apprepo-role`, and only to
  `ec2.amazonaws.com`.
- **KMS** cryptographic use is conditioned on `kms:ViaService` for EC2 in `us-east-1`.

## What the runner reads from S3

From `…_runner_s3`:

- **Terraform state:** read and write the one state object and its lock, with listing limited to
  those two keys.
- **Installers:** `s3:GetObject` on the **whole** application repository bucket, with no listing.
  The statement is named `ReadAppRepoByExactPathOnlyNoListing`; per-installer grants were the
  intent, and the resource is what is deployed.
- **Licences:** the Deploy and Inventory licence keys and registration emails, plus the two licence
  objects under their earlier names.
- **Service-account secrets:** the local service account, the directory account, and the three
  per-class target accounts.
- **Host credentials:** the domain-join password and the OpenVPN profile.

The roles fetch these on the controller. Only installers are copied to a guest; no credential on a
deployed host can read these objects.

## The instance profile

Both hosts run as `nwarila-ec2-apprepo-profile`. Its role reads the **whole** application repository
(`s3:ListBucket` and `s3:GetObject`) and carries `AmazonSSMManagedInstanceCore`. The PDQ console
needs the whole bucket, because `Sync-Repository.cmd` mirrors it; the scan target needs only the one
Feature-on-Demand cab it fetches at boot. Narrowing that is tracked in
[issue #56](https://github.com/nwarila-platform/pdq-deploy-inventory/issues/56).

## Operator access

Because the operator trust names the account and then narrows to the generated role, the
`github_nwarila-platform` permission set must itself allow `sts:AssumeRole` on the operator role.
That is managed outside this repository: add the role's ARN to the permission set's inline policy
and provision the permission set to the account. Do not edit the generated `AWSReservedSSO_*` role,
which IAM Identity Center owns. See AWS on
[role delegation](https://docs.aws.amazon.com/STS/latest/APIReference/API_AssumeRole.html) and
[permission-set inline policies](https://docs.aws.amazon.com/singlesignon/latest/userguide/permissionsetcustom.html).

## Accepted residuals

- Launch references allow any image, subnet, security group, key pair and placement group in
  `us-east-1`; no condition narrows them.
- No condition requires EBS encryption, or bounds instance type, volume size, IOPS or throughput.
- No condition restricts security-group rule ports.
- The runner has no Elastic IP, internet-gateway or route-table actions, but nothing prevents a
  public IPv4 address at launch.
- KMS cryptographic access is `Resource: "*"`, bounded only by the `kms:ViaService` condition.

## Adapting for another repository

Change every repository-specific value together: the account id, the repository id and name in
the trusts and tag conditions, the region, and the role, policy and state-key names that carry this
repository's name.
