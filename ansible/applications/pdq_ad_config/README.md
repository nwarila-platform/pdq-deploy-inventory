# PDQ Active Directory configuration

This elevated role owns the directory objects PDQ depends on. It ensures the PDQ computer OU
exists and converges the declared service accounts, each with exactly the group membership its
declaration names.

In `absent` state it removes those accounts. It leaves the computer OU and every shared OU in
place, deliberately: this role did not create them alone and is not the only thing that files
objects there.

The role is run manually and separately from ordinary PDQ convergence — it runs against a domain
controller, which the deployment pipeline never touches. The operator needs directory authority to
manage the declared objects, and AWS read authority for the secrets the playbook resolves.

## What it does not do

The role never generates, stores or rotates a password. The caller resolves each password and
hands over the value; S3 is the operator's to write, not this role's. Nothing here reads or writes
S3 at all.

It writes no permissions. Privileges are granted by GROUP MEMBERSHIP, because that is how the
directory grants them: LAPS decryption is conferred by the group each OU's policy names as its
encryption principal, and local administrator rights on a machine come from that machine's OU
policy. Naming a group is the whole grant; this role writes no ACE anywhere.

An account created here is a plain member of Domain Users and can do nothing on a machine until a
policy says otherwise — which reaches machines this deployment never built, and is why the grant
lives there rather than here.

## Invocation

Converge the declared objects:

```shell
COMPOSE_PLAYBOOK=ad-config.yml COMPOSE_INVENTORY=ansible/inventory/directory.yml \
  scripts/compose-and-run.sh \
  -e ENV=prod -e aws_account_id=<account> -e aws_region=us-east-1
```

`ENV` is upper case. The framework loader requires it by that name and fails immediately without
it; the dynamic AWS inventory composes it from a tag, but this static inventory does not, so it is
passed here.

Remove the accounts and their explicit OU permissions:

```shell
COMPOSE_PLAYBOOK=ad-config.yml COMPOSE_INVENTORY=ansible/inventory/directory.yml \
  scripts/compose-and-run.sh \
  -e ENV=prod -e aws_account_id=<account> -e aws_region=us-east-1 \
  -e state=absent
```

## Variables

`state` accepts `present` or `absent`.

`service_accounts` and `computer_ou` declare the complete site-specific state. Both are empty by
default: every value this role needs names one particular directory, so a working default here
would be one site's directory wearing a default's clothes.

`service_accounts` is a list. Each entry carries:

| Key | Required | Meaning |
|---|---|---|
| `name` | yes | the account name |
| `ou` | yes | distinguished name of the container it is filed in |
| `password` | yes | resolved by the caller; this role never sources it |
| `groups` | no | groups the account belongs to, besides its primary Domain Users |

Every account appears in the one list; only those needing a privilege name the group that confers
it. Declaring `groups` with an empty list is refused — that says what omitting the key already
says, and a reader cannot tell an empty declaration from an unfinished one.

No account in this deployment declares `groups` today: `svc-pdq` reads the directory for the
computer sync, and the class accounts authenticate to a target as themselves, taking their rights
there from that machine's OU policy.

An account is set to exactly what its entry says, group membership included, so an account that
gained a group elsewhere loses it on the next converge. A duplicated `name` is refused: two
declarations of one object mean the second silently wins.

## A note on diagnostics

The account task is `no_log`, because a password crosses on every item. That censors the loop
label with it, so a run reporting `changed` does not say which account changed. The task that
follows names every declared account, which is not the same thing.
