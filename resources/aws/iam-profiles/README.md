# Instance profiles

A profile is a named container holding exactly one role. The files here declare that binding, in
the shape `aws iam create-instance-profile` and `add-role-to-instance-profile` take.

| Profile | Role (same name) | Role's policies |
|---|---|---|
| `nwarila-platform_instance-baseline_ec2` | ditto | `AmazonSSMManagedInstanceCore`, `nwarila-platform_instance-baseline_ec2_s3` |
| `nwarila-platform_pdq-deploy-inventory_ec2` | ditto | the two above, **plus** `nwarila-platform_pdq-deploy-inventory_ec2_s3` |

Profile, role and policy share one name per tier, differing only by the `_s3` service suffix on
the policy, so what a machine may do is readable from what it runs as.

## Why the baseline carries an S3 read

A Windows image that ships without OpenSSH — Server 2022 does — is unreachable until the
Feature-on-Demand cab is installed, and the shared framework's `user_data` fetches it from
`s3://<account-id>-apprepo/fod/<build>/`. A system holding the baseline without that grant has no
route to the cab and **fails at boot by design**.

Being fetchable is part of what makes a machine manageable here, not an application concern.
Without it in the baseline, every repository meeting such an image reaches for a broader profile
that happens to include the bucket — which is what this one did, giving a scan target read access
to the whole application repository to fetch a single 1.4 MB cab.

`nwarila-platform_instance-baseline_ec2_s3` is scoped to that one prefix, with `ListBucket`
conditioned on `s3:prefix`.

## Why the PDQ tier needs more

`Sync-Repository.cmd` runs `aws s3 sync s3://<account-id>-apprepo/` into `F:\PDQ Repository`,
mirroring the entire bucket, so `nwarila-platform_pdq-deploy-inventory_ec2_s3` grants
`GetObject` on `*`. That read is this repository's, and it is named as this repository's.

The role also carries the baseline's policy even though the whole-bucket grant already covers
that prefix. The redundancy is deliberate: it makes the PDQ tier literally the baseline plus a
delta, so a later baseline change that is not about S3 still reaches this host.

## Both tiers keep SSM

`AmazonSSMManagedInstanceCore` is required, not incidental. The framework supports four connection
profiles — `ssh-direct`, `ssh-ssm`, `winrm-direct`, `winrm-ssm` — and the two SSM ones need it.
`connection_type` is a per-system choice in `terraform/aws.tfvars`, so omitting it silently
removes half the supported transports.

## What this retires

`nwarila-ec2-profile` / `nwarila-ec2-role` and `nwarila-ec2-apprepo-profile` /
`nwarila-ec2-apprepo-role`. The first pair is the organizational default under an older name; the
second is what both of this repository's hosts run as today, including the scan target that
should never have had it.
