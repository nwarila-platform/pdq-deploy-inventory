# Adopt this repository

**Type**: How-to (Diátaxis). What must exist before a deployment can succeed, and what must be
changed because it names this environment.

Nothing here is created by the pipeline. A clone with none of it configured fails, and the
failures are early and loud rather than subtle — but they are only obvious if you already know
the list. That is what this document is.

## 1. AWS account

| Thing | Detail |
|---|---|
| **GitHub OIDC provider** | `token.actions.githubusercontent.com`, audience `sts.amazonaws.com`. The role trust documents in `resources/aws/iam-roles/` assume it exists |
| **IAM** | Apply everything in `resources/aws/`, substituting `<account-id>`. `resources/README.md` gives the order and says why it is strict |
| **`<account-id>-terraform`** | S3 bucket for remote state. The workflow's `terraform init` names it |
| **`<account-id>-apprepo`** | S3 bucket. Product installers, licences, and the Feature-on-Demand cab |
| **`<account-id>-ansible`** | S3 bucket. Secrets the playbook reads at converge time |
| **EC2 key pair** | Named in `terraform/aws.tfvars` as `key_name`. The framework consumes key pairs and never creates them |
| **VPC, subnet, AZ** | `subnet_id` and `availability_zone` in `terraform/aws.tfvars` are literals of this account |
| **KMS** | `aws_kms_alias`; `aws/ebs` is the account-default alias |

## 2. Objects that must be staged in S3

The deployment fetches these. A missing one fails the converge, not the plan.

**`<account-id>-apprepo`**

| Key | What |
|---|---|
| `PDQ.com/PDQ Deploy/<version>/PDQ_Deploy_x86-x64.exe` | Installer. Version and sha256 are pinned in `ansible/playbooks/pdq-aws.yml` |
| `PDQ.com/PDQ Inventory/<version>/PDQ_Inventory_x86-x64.exe` | Installer, likewise pinned |
| `fod/<build>/OpenSSH-Server-Package~31bf3856ad364e35~amd64~~.cab` | Only for images shipping without OpenSSH. `20348` is Server 2022 |

**`<account-id>-ansible/applications/pdq/`**

| Key | What |
|---|---|
| `pdq-deploy-license-key.lic`, `pdq-deploy-license-email.txt` | Deploy licence |
| `pdq-inventory-license-key.lic`, `pdq-inventory-license-email.txt` | Inventory licence |
| `svc-pdq-password.txt` | The LOCAL service account's password |
| `svc-pdq-domain-password.txt` | The DOMAIN service account's password, used by `ad-config.yml` |

The installer pins are digests, not names: replacing an installer without updating its `sha256`
in the playbook fails the verified copy, by design.

## 3. GitHub repository secrets

| Secret | For |
|---|---|
| `AWS_ACCOUNT_ID` | The account to assume into; also names every bucket above |
| `AWS_EC2_SSH_PRIVATE_KEY` | The private half of the `key_name` pair, so the runner can reach the guest |
| `AWS_DEBUG_HOSTNAME` | Optional. A DNS name resolving to an operator's address, opened in the security group for direct access. Absent means no operator access, not a failed run |

## 4. Active Directory

Required whenever a host is domain-joined, which the AWS playbook does.

- **Windows LAPS**, configured as `resources/group policy objects/windows-laps.md` records —
  schema extended, `BackupDirectory = 2`, machines able to write their own password.
- **The OUs named in the playbooks must exist.** They are literals of this directory:
  `OU=Domain Workstations`, `OU=Domain Servers`, `OU=PDQ,OU=Domain Servers`,
  `OU=Domain Service Accounts`, all under `DC=tcn,DC=trinitytechnicalservices,DC=com`.
- **A domain join account**, supplied through the `domain_member` role's own secret contract.
- **A VPN path to the directory** if the instances are not routable to it. `remote_client` builds
  the tunnel; the profile it uses is site policy, not this repository's.

`ansible/playbooks/ad-config.yml` creates the service account, the PDQ computer OU, and the LAPS
read grants. It does NOT create the OUs above it, the LAPS policy, or the schema.

## 5. What must be renamed or repointed

Everything below names this environment and will be wrong in another:

- **`terraform/aws.tfvars`** — `subnet_id`, `availability_zone`, `key_name`, `ami`,
  `iam_instance_profile`, and the `hostname` of each system.
- **`ansible/playbooks/pdq-aws.yml`** and **`ad-config.yml`** — every distinguished name, the
  realm, and the service account name.
- **`ansible/inventory/aws_ec2.yml`** — the region, and the `Function` tag values if you rename
  them.
- **IAM names** — `nwarila-platform_<repository>_<principal>` embeds this repository's name;
  `docs/reference/aws-iam/README.md` also lists the literal `RepositoryId` values to change.
- **The framework pins** in `.github/` — valid for any adopter, but they are release SHAs and
  should be moved deliberately, never by hand to an untagged commit.

## 6. What this repository does NOT do

- It does not create IAM, buckets, VPCs, key pairs, OUs, GPOs, or the AD schema.
- It does not source the product installers or licences; it consumes what you stage.
- It does not rotate the service account password. The role sets what it is given, and the domain
  expires it on the domain's own schedule.
- It does not scan or deploy anything on its own. It configures the products; what they then do is
  driven by their own declarations.
