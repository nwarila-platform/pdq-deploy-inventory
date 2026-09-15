# Reference

What this deployment depends on but does not create. Terraform builds instances and Ansible
converges them; none of it provisions IAM or writes Group Policy. Those are applied by an operator
and must already exist before a deployment can succeed, so they are recorded here.

| Path | Holds |
|---|---|
| [`aws-iam/`](aws-iam/) | The roles, policies and instance profile the deployment runs with, exported from the live account |
| [`group-policy-objects/`](group-policy-objects/) | Group Policy the deployment assumes is already in place |
| [`wmi-filters/`](wmi-filters/) | WMI filters; none exist, and the absence is recorded |
| [`pdq-automation.md`](pdq-automation.md) | The PDQ command-line and configuration surface the roles automate |
