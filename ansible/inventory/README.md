# ansible/inventory/

## There is no static inventory, and that is deliberate

The AWS deploy is **ephemeral**: every run creates a new instance, converges it, and destroys it.
An instance id written into a file here would be wrong the moment the run that produced it ended.

## `aws_ec2.yml` — a dynamic inventory, filtered to this run

The inventory is the `amazon.aws.aws_ec2` plugin. It keeps only **running** instances matching four
tag filters: `RepositoryId`, `RunId`, and `Repository` come from the environment
(`GITHUB_REPOSITORY_ID`, `GITHUB_RUN_ID`, `GITHUB_REPOSITORY`), while `Environment` is pinned to
`test` in the plugin. Every matched instance joins the `pdq_servers` group (`groups:
pdq_servers: 'true'`), and the play then asserts **at least one** `pdq_servers` host before
configuring anything — the framework guarantees a single host per run, so in practice that is the
one this run created. Host attributes are namespaced with `aws_` so the EC2 `state` attribute cannot
collide with the role's `state` input.

## Transport: direct SSH over the launch-time public IPv4

`compose:` sets `ansible_host: aws_public_ip_address` (the subnet-assigned launch-time address; no
Elastic IP, no NAT), `ansible_connection: ssh`, `ansible_user: Administrator`,
`ansible_shell_type: cmd`, and the private key from `CI_PRIVATE_KEY`; a keepalive `ssh_common_args`
outlasts the minutes-long settings settle poll. Reachability is the runner-scoped security group the
framework attaches at runtime plus the temporary development-cycle ingress in `terraform/aws.tfvars`.
SSM (via the instance profile's `AmazonSSMManagedInstanceCore`) is the administrator's backup
connection, not this path.

## Running the playbook by hand

Export `GITHUB_REPOSITORY_ID`, `GITHUB_RUN_ID`, and `GITHUB_REPOSITORY` plus AWS credentials, then
point `-i` at `aws_ec2.yml` while the instance still exists (the workflow also passes
`--extra-vars env=test`; the `Environment` tag filter is pinned to `test` either way). The play
asserts its ownership contract, so a run whose tags do not match fails closed.
