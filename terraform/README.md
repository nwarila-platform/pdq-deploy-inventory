# terraform/ — NOT ACTIVE

This directory reserves the future AWS deploy layer. The Terraform skeleton is not
executed, validated, or wired as a deploy capability.

As of 2026-08-10, the repository's IAM foundation is live: its reviewed policy and trust
documents are under `docs/reference/aws-iam/`, and `scripts/bootstrap-iam.sh` has applied
that foundation. This does not make the Terraform deploy layer active.

The AWS deploy layer is the next development direction as of 2026-08-10. It will be shaped
against the repository's current IAM boundary and application deployment requirements
before this notice is removed; no unimplemented infrastructure behavior is implied here.
