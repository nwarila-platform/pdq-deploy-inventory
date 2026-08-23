# ansible/inventory/

## There is no static inventory, and that is deliberate

The AWS deploy is **ephemeral**: every run creates a new instance, converges it, and destroys it.
An instance id written into a file here would be wrong the moment the run that produced it ended.

## `aws_ec2.yml` — a dynamic inventory, filtered to this run

The inventory is the `amazon.aws.aws_ec2` plugin. At runtime it queries EC2 and keeps only the
instances whose `RepositoryId`, `RunId`, `Environment`, and `Repository` tags match the run that is
executing — the values come from the environment the workflow (or a local operator) exports:
`GITHUB_REPOSITORY_ID`, `GITHUB_RUN_ID`, `env`, and `GITHUB_REPOSITORY`. The `pdq_servers` group is
formed from the product tag. Because the filter keys on this run's own tags, a host from any other
run is never in scope, and the playbook additionally asserts exactly one matching host before it
configures anything.

## Transport: direct SSH over the launch-time public IPv4

`compose:` sets `ansible_host: aws_public_ip_address` (the subnet-assigned launch-time address; no
Elastic IP, no NAT), `ansible_connection: ssh`, `ansible_user: Administrator`,
`ansible_shell_type: cmd`, and the private key from the `CI_PRIVATE_KEY` environment variable.
Reachability is the runner-scoped security group the framework attaches at runtime plus the
temporary development-cycle ingress declared in `terraform/aws.tfvars`. SSM (via the instance
profile's `AmazonSSMManagedInstanceCore`) is the -admin backup connection, not this path.

## Running the playbook by hand

Export the four tag environment variables above and AWS credentials, then point `-i` at
`aws_ec2.yml` while the instance still exists. The playbook asserts the ownership contract itself,
so a mismatched environment fails closed rather than touching another run's host.
