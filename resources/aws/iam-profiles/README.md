# Instance profiles

An instance profile holds exactly one role and carries no document of its own, so there is nothing
here to apply. What matters is which role each profile holds and how that role is composed.

## Naming

Roles and profiles follow the fleet pattern `nwarila-platform_<repository>_<principal>`, with
`_instance` taking the principal slot beside the existing `_runner`, `_admin` and `_reaper`. No
new policy is introduced under that pattern: the instance role composes policies that already
exist, and `nwarila-fod-read` is org-level like `nwarila-apprepo-read` because it describes what
any managed machine needs rather than anything about this repository.

## The tiers

| Profile | Role | Attached policies |
|---|---|---|
| `nwarila-ec2-profile` | `nwarila-ec2-role` | `AmazonSSMManagedInstanceCore`, `nwarila-fod-read` |
| `nwarila-platform_pdq-deploy-inventory_instance` | same name | the two above, **plus** `nwarila-apprepo-read` |

The instance role is the baseline **plus one policy**. Its extra grant is stated in one place, and
anything the baseline gains later is attached to both — so the relationship stays legible instead
of the two drifting into unrelated permission sets.

## Why the baseline carries the FoD read

A Windows image that ships without OpenSSH — Server 2022 does — is unreachable until the
Feature-on-Demand cab is installed, and the shared framework's `user_data` fetches it from
`s3://<account-id>-apprepo/fod/<build>/`. A system holding the default without that grant has no
route to the cab and **fails at boot by design**.

Being fetchable is part of what makes a machine manageable here, not an application concern.
Without it in the default, every repository that meets such an image reaches for a broader profile
that happens to include the bucket — which is what this one did, giving a scan target read access
to the whole application repository to fetch a single 1.4 MB cab.

## Why the console needs more

`Sync-Repository.cmd` runs `aws s3 sync s3://<account-id>-apprepo/` into `F:\PDQ Repository`,
mirroring the entire bucket. That is `nwarila-apprepo-read`, reused rather than restated — a
second policy with the same grants would be two things to keep in step.

`nwarila-fod-read` is attached to the console too, even though its whole-bucket `GetObject`
already covers that prefix. The redundancy is deliberate: it makes the console literally the
baseline plus a delta, so the composition survives a future baseline change that is not about S3.

## Both tiers keep SSM

`AmazonSSMManagedInstanceCore` is required, not incidental. The framework supports four connection
profiles — `ssh-direct`, `ssh-ssm`, `winrm-direct`, `winrm-ssm` — and the two SSM ones need it.
`connection_type` is a per-system choice in `terraform/aws.tfvars`, so omitting it silently
removes half the supported transports.

## What this retires

`nwarila-ec2-apprepo-profile` and `nwarila-ec2-apprepo-role` are named as shared fleet
infrastructure while this repository is their only consumer, and they are what a scan target was
wrongly given. The instance profile above replaces them; `nwarila-apprepo-read`, the policy they
carry, is kept and reused.
