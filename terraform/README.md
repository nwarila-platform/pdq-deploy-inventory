# terraform/ — data only

This directory carries **no `.tf` files and never will**. The AWS resources are declared by the
pinned `nwarila-platform/aws-terraform-framework`; this repository contributes only the variable
input that shapes them.

- `aws.tfvars` — the system declaration consumed verbatim by the framework. It pins the
  availability zone, subnet, instance type, AMI, key pair, instance profile, disk layout and the
  zero-ingress network interface.
- The framework SHA is pinned in `.github/terraform-framework-pin`.

`.github/workflows/aws-deploy.yml` checks the framework out at that pin, runs Terraform from
inside it, and passes this file with `-var-file`. The deployment identity (`environment`,
`repository`, `repository_id`, `commit_sha`, `run_id`) is supplied separately with `-var`, the
highest-precedence source, so the tags that satisfy the deploy role's create-time IAM conditions
cannot be overridden from here.

Reachability is **zero inbound**: the security group allows no ingress, and the runner reaches
the instance over SSH tunnelled through an SSM session riding the agent's own outbound 443.
