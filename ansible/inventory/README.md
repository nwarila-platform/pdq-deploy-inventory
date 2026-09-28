# ansible/inventory/

## There is no static inventory, and that is deliberate

The AWS deploy is **ephemeral**: every run creates a new instance, converges it, and destroys it.
An instance id written into a file here would be wrong the moment the run that produced it ended.

## `aws_ec2.yml` — one run's instance, describing itself

The file is in two parts. The first is the only part that is about this repository: the region, the
four tag filters that select one run's instance — `RepositoryId`, `RunId` and `Repository` from the
workflow's own environment, and `Environment` from `ENVIRONMENT` or `test` — and the `pdq_servers`
group the play addresses. Everything below that is carried unchanged by any repository deploying a
host this way.

Hosts are named by their **Name tag**, which is the hostname Terraform declares, so
`inventory_hostname` is the system's own name and nothing downstream has to be told it again. Every
attribute the plugin publishes is namespaced with `aws_`, which keeps the EC2 instance `state` from
colliding with the role input that selects `present_windows.yml` or `absent_windows.yml`.

## Transport and credential ownership

| Value | Owner or source |
|---|---|
| Platform family and shell type | inventory, from the instance's `platform_details` |
| Connection transport, port, address and SSM proxy | inventory, from the `Connection` tag |
| Login user, private key or password | `credential_resolver`, from the play's ordered sets |
| `ENV` (the framework loader's input) | the `Environment` tag |

The `Connection` tag takes four values, and absent means `ssh-direct`:

| Value | Reaches the host by |
|---|---|
| `ssh-direct` | SSH to the routable address on 22 |
| `ssh-ssm` | SSH to the instance id through a Session Manager `ProxyCommand`; no inbound rule |
| `winrm-direct` | WinRM over HTTPS to the routable address on 5986 |
| `winrm-ssm` | WinRM over HTTPS to a local port an SSM port-forwarding session already holds open |

A WinRM host needs pywinrm on the controller and its launch key as an unencrypted PEM named by
`CI_PRIVATE_KEY`; `credential_resolver` decrypts the launch password, then `domain_member` adopts
the domain automation identity after its restart.

## Running the playbook by hand

Export `GITHUB_REPOSITORY_ID`, `GITHUB_RUN_ID` and `GITHUB_REPOSITORY` plus AWS credentials, then
point `-i` at `aws_ec2.yml` while the instance still exists. Set `ENVIRONMENT` if the deployment is
not the default `test`. The play asserts its ownership contract, so a run whose tags do not match
fails closed.

Before calling `scripts/compose-and-run.sh`, set `ANSIBLE_SSH_AGENT` or `SSH_AUTH_SOCK` to an
agent socket. It must already hold a passphrase-protected launch key for an SSH host; an empty
agent is valid when every selected host uses WinRM. An `ssh-ssm` host also requires the Session
Manager plugin on the controller.
