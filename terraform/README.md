# terraform/ — data only

This directory carries **no `.tf` files and never will**. The AWS resources are declared by the
pinned `nwarila-platform/aws-terraform-framework`; this repository contributes only the variable
input that shapes them.

- `aws.tfvars` — the system declaration consumed verbatim by the framework. It pins the
  availability zone, subnet, instance type, AMI, key pair, instance profile, disk layout, the
  network interface and its ingress, and marks the OS instance swap-eligible (`refresh = true`) so
  a `refresh_serial` bump replaces it while the standalone data volumes reattach.
- The framework SHA is pinned in `.github/terraform-framework-pin`.

`.github/workflows/aws-deploy.yml` checks the framework out at that pin, runs Terraform from
inside it, and passes this file with `-var-file`. The deployment identity (`environment`,
`repository`, `repository_id`, `commit_sha`, `run_id`) is supplied separately with `-var`, the
highest-precedence source, so the tags that satisfy the deploy role's create-time IAM conditions
cannot be overridden from here.

Reachability is **direct SSH over a launch-time public IPv4**: the shared subnet's
MapPublicIpOnLaunch assigns the address (no Elastic IP, no NAT), and at runtime the framework
attaches one security group scoped to the runner's validated public IPv4. As a temporary
development-cycle allowance `aws.tfvars` also opens SSH (22) and the PDQ Deploy console (6336) to
all of IPv4, split into two `/1` halves — remove it when the cycle ends. SSM (via the instance
profile's `AmazonSSMManagedInstanceCore`) is the -admin backup connection, not the primary path.
