# PDQ Active Directory configuration

This elevated role owns the directory objects that PDQ depends on. It creates or reconciles the
PDQ computer OU, the `svc-pdq` account, the account password held in S3, and the account's explicit
Windows LAPS read permissions on the two declared parent OUs. In absent state it removes the
account and only that account's explicit ACEs. It deliberately leaves the shared OUs in place.

The role is run manually and separately from ordinary PDQ convergence. The operator needs directory
authority to manage the declared objects and AWS authority to read and write exactly the declared
secret key.

## Invocation

Routine convergence rotates only when the current password is older than `rotate_interval_days`:

```shell
COMPOSE_PLAYBOOK=ad-config.yml COMPOSE_INVENTORY=ansible/inventory/directory.yml \
  scripts/compose-and-run.sh \
  -e env=prod -e aws_account_id=<account> -e aws_region=us-east-1
```

Force rotation with the same switch intended for future automation:

```shell
COMPOSE_PLAYBOOK=ad-config.yml COMPOSE_INVENTORY=ansible/inventory/directory.yml \
  scripts/compose-and-run.sh \
  -e env=prod -e aws_account_id=<account> -e aws_region=us-east-1 \
  -e rotate_password=true
```

Remove the account and its explicit OU permissions:

```shell
COMPOSE_PLAYBOOK=ad-config.yml COMPOSE_INVENTORY=ansible/inventory/directory.yml \
  scripts/compose-and-run.sh \
  -e env=prod -e aws_account_id=<account> -e aws_region=us-east-1 \
  -e state=absent
```

## Variables

`state` accepts `present` or `absent`. `rotate_password` defaults to `false` and accepts native or
string boolean values. `rotate_interval_days`, `password_length`, `password_charset`,
`service_account`, `computer_ou`, `laps_read_ous`, and `secret_url` declare the complete
site-specific state.

The password is never returned or written to a controller file. S3 remains authoritative: every
new password is written there before Active Directory is updated so a partial failure can be
recovered by re-pushing the stored value on the next run.
