# ansible/inventory/

## There is no static inventory, and that is deliberate

The AWS deploy is **ephemeral**: every run creates a new instance, converges it, and destroys it.
An instance id written into a file here would be wrong the moment the run that produced it ended.

The inventory is therefore **generated per run from Terraform output** and verified against live
EC2 tags before Ansible is allowed to touch the host — see
`.github/workflows/aws-deploy.yml`, step *Build exact runtime inventory from Terraform output*.
That step refuses to proceed unless Terraform returned exactly one instance whose
`RepositoryId`, `RunId`, `Environment` and `Repository` tags match the run that is executing.

## Seeing the inventory a run actually used

The generated file is written to `aws-runtime.json` in this directory during a deploy, so it can
be read in the workspace and inspected after the fact. It is git-ignored: it is run state, not
configuration, and it names an instance that no longer exists once the run ends.

Its shape:

```json
{ "all": { "children": { "pdq_servers": { "hosts": {
  "i-0123456789abcdef0": {
    "ansible_host": "i-0123456789abcdef0",
    "ansible_user": "Administrator",
    "ansible_connection": "ssh",
    "ansible_shell_type": "cmd",
    "ansible_ssh_private_key_file": "<runner temp path>",
    "ansible_ssh_common_args": "<SSH through an SSM session>",
    "ec2_tags": { "RepositoryId": "...", "RunId": "...", "Environment": "test" }
  } } } } }
```

`ansible_host` is the **instance id**, not an address: the connection is SSH tunnelled through an
SSM session, so there is no inbound path and nothing to reach by hostname.

## Running the playbook by hand

Point `-i` at a run's `aws-runtime.json` while that instance still exists. The playbook asserts
the same ownership contract itself, so a stale file fails closed rather than configuring a host
belonging to another run.
