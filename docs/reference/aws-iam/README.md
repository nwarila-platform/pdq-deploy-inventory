# AWS IAM reference

**Type**: Reference (Diátaxis). These documents record the IAM used by this repository's
ephemeral AWS deployment. An operator provisions the roles and policies; Terraform does not manage
them.

## Materializing and adapting the documents

The policy files use only `<account-id>` as a placeholder. The trust files use `<account-id>`, and
the CI trust also uses `<owner-id>` and `<repository-id>`. Other repository, region, resource and tag
values are literals or wildcards. In particular, `RepositoryId` is the literal `1316209027` in five
runner policies, the region is `us-east-1`, and the VPC, subnet, key-pair and KMS resources are not
repository-specific placeholders.

Before applying a downstream clone, review every document together and change:

- the account ID;
- the owner ID, repository ID, owner and repository name;
- the region; and
- the VPC, subnet, key-pair and EBS KMS references if the downstream policy narrows their current
  wildcards.

Also rename role, policy, state-key and file-name literals that contain this repository's name.

## Roles and policy attachments

| Role | Trust document | Attached permissions | Purpose |
|---|---|---|---|
| `nwarila-platform_pdq-deploy-inventory_runner` | `roles/github_nwarila-platform_pdq-deploy-inventory.trust.json` | All eight `runner_*.json` policies below | Workflow deploy, converge, prove and destroy |
| `github_nwarila-platform_pdq-deploy-inventory-admin` | `roles/github_nwarila-platform_pdq-deploy-inventory-admin.trust.json` | The eight runner policies plus `nwarila-platform_pdq-deploy-inventory_admin_s3.json` | Operator deploy and artifact publishing |
| `nwarila-ec2-role` | `roles/nwarila-ec2-role.trust.json` | `AmazonSSMManagedInstanceCore` only | EC2 instance profile `nwarila-ec2-profile` |

The workflow assumes `nwarila-platform_pdq-deploy-inventory_runner` through `DEPLOY_ROLE`.

| Policy document | Grant |
|---|---|
| `nwarila-platform_pdq-deploy-inventory_runner_iam.json` | Read `nwarila-ec2-profile`; pass only `nwarila-ec2-role` and only to EC2 |
| `nwarila-platform_pdq-deploy-inventory_runner_eni.json` | Describe ENIs and addresses; create tagged ENIs; manage owned ENIs and attach them to owned instances |
| `nwarila-platform_pdq-deploy-inventory_runner_sg.json` | Describe security groups; create tagged groups; manage owned groups and their rule resources |
| `nwarila-platform_pdq-deploy-inventory_runner_ec2.json` | Read deployment metadata; launch tagged instances and volumes; manage and tag owned instances and volumes |
| `nwarila-platform_pdq-deploy-inventory_runner_ssm.json` | Read the AMI parameter hierarchy; start SSH sessions and PowerShell commands on repository-tagged instances; read results and tear down the runner's sessions |
| `nwarila-platform_pdq-deploy-inventory_runner_kms.json` | Resolve KMS aliases and keys; use KMS cryptographic and grant operations through EC2 in `us-east-1` |
| `nwarila-platform_pdq-deploy-inventory_runner_s3.json` | Manage the two Terraform state objects; read the two licences, the versioned PDQ and OpenVPN installers, the VPN profile, and the two service-account secrets |
| `nwarila-platform_pdq-deploy-inventory_runner_ebs.json` | Describe volumes; create tagged volumes; attach, detach and delete owned volumes |
| `nwarila-platform_pdq-deploy-inventory_admin_s3.json` | List `PDQ.com/`; publish PDQ installers and the two licences; abort multipart uploads under `PDQ.com/` |

## Boundaries present in the documents

- Every statement is `Allow`; none is `Deny`.
- EC2, ENI, security-group and EBS creation requires the repository, repository ID and `ManagedBy`
  request-tag values, plus the presence of commit, run and environment tags. Lifecycle operations
  on instances, ENIs, security groups and volumes require the corresponding ownership tags.
- The CI trust requires the audience and repository ID, accepts the two recorded `sub` forms, and
  limits `job_workflow_ref` to this repository's `aws-deploy.yml`. The workflow reference is one
  string value, not an array.
- The operator trust accepts only the `github_nwarila-platform` IAM Identity Center role name with
  a 16-character generated suffix: each `?` in its `ArnLike` pattern matches one character.
- The runner can pass only `nwarila-ec2-role` to EC2. KMS use is conditioned on the EC2 service in
  `us-east-1`.

## Artifact access and the instance profile

The runner reads exactly the two licence objects and the PDQ service-account secret under
`applications/pdq/`, the directory-join secret under `applications/domain_member/`, and the VPN
profile under `openvpn/`. It also reads the versioned installers at
`PDQ.com/PDQ Deploy/<version>/PDQ_Deploy_x86-x64.exe`,
`PDQ.com/PDQ Inventory/<version>/PDQ_Inventory_x86-x64.exe`, and
`OpenVPN.net/OpenVPN Community/<version>/OpenVPN_Community_amd64.msi`. Every installer key keeps
the version out of the filename, so each grant carries exactly one wildcard: the version segment.
The roles fetch those objects on the controller and copy only the installers to the guest. The operator role has the same
reads and additionally publishes installers and licences through `admin_s3`.

The instance profile carries `AmazonSSMManagedInstanceCore` only and has no S3 policy. No credential
on the target can fetch these S3 objects.

## Broker permission set

The operator trust names the account principal and then limits `aws:PrincipalArn` to the generated
IAM Identity Center role. The `github_nwarila-platform` permission set must therefore also allow
`sts:AssumeRole` on this repository's operator role. That permission is managed outside this
repository.

Add the operator-role ARN to the permission set's inline policy, then provision the updated
permission set to the account. Do not edit the generated `AWSReservedSSO_*` role directly; IAM
Identity Center manages that role. See AWS's documentation for
[account-principal role delegation](https://docs.aws.amazon.com/STS/latest/APIReference/API_AssumeRole.html)
and [permission-set inline policies](https://docs.aws.amazon.com/singlesignon/latest/userguide/permissionsetcustom.html).

## Deployment values outside IAM

Terraform and the composed play currently declare one `t3.large` host and these `gp3` disks:

| Drive | Label | Size | Purpose |
|---|---|---:|---|
| `C:` | AMI root | 30 GiB | Operating system |
| `D:` | `PDQINVENTORY` | 30 GiB | PDQ Inventory database |
| `E:` | `PDQDEPLOY` | 30 GiB | PDQ Deploy database |
| `F:` | `PDQREPO` | 60 GiB | Package repository |

`terraform/aws.tfvars` also sets the IMDS hop limit to `1` and declares ingress for SSH, the PDQ
Deploy console and the PDQ Inventory console. Those are Terraform settings, not IAM controls.

## Accepted IAM residuals

- Launch references allow any image, subnet, security group, key pair and placement group matching
  the regional ARN patterns. There is no subnet or image-owner condition.
- IAM does not require EBS encryption or cap instance type, volume size, IOPS, throughput, instance
  count or spend.
- IAM does not restrict the security-group rule ports. The rule-resource grants are regional
  wildcards; the corresponding group grants require the repository ownership tags.
- IAM does not prevent a public IPv4 at launch. The runner has no Elastic IP, internet-gateway or
  route-table actions.
- KMS cryptographic access uses `Resource: "*"`, bounded by `kms:ViaService` for EC2 in `us-east-1`.
