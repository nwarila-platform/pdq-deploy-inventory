# =========================================================================================== #
# File: 'terraform/aws.tfvars'
# --- [ Description ] ----------------------------------------------------------------------- #
#
# Variable input for the pinned aws-terraform-framework (SHA in .github/terraform-framework-pin).
# Plain tfvars — the workflow passes this file to terraform verbatim. This repository declares
# NO .tf files of its own: resources live in the pinned framework, configuration in the pinned
# ansible-framework plus this repository's roles.
#
# REACHABILITY — ZERO INBOUND, SSH OVER SSM. The security group allows no ingress at all. The
# runner reaches the instance through an SSM session (AWS-StartSSHSession) riding the SSM
# agent's own outbound 443. The deploy subnet sets MapPublicIpOnLaunch, so the pre-created ENI
# is auto-assigned a public IPv4 at launch and the agent egresses through the internet gateway.
# No Elastic IP is involved. The account has no NAT and no VPC endpoints, so that auto-assigned
# address is the only egress route — SSM registration is the proof it carries traffic.
#
# The dependency worth knowing: MapPublicIpOnLaunch is an attribute of a shared subnet no
# repository owns. If it is ever turned off, an instance without an Elastic IP launches with no
# address and no egress, and the failure appears minutes later as an SSM agent that never
# registers rather than as an apply error.
#
# readiness_gate is FALSE by design: the framework's gate dials the instance directly over SSH,
# which a zero-ingress security group forbids. The playbook's first play waits for readiness
# over SSM-SSH instead. The OpenSSH DefaultShell stays cmd — the boot default — because a
# PowerShell login shell breaks ansible's module bootstrap.
#
# =========================================================================================== #

# environment and the deployment identity (repository, repository_id, commit_sha, run_id) are
# deliberately NOT in this file: the workflow passes them with -var, the highest-precedence
# source, so the identity that drives the provider's tags cannot be overridden here.

all_systems = [
  {
    region   = "us_east_1"
    hostname = "pdq-poc-01"
    # The ratified availability-zone spec lock, and a subnet in this account's only VPC.
    availability_zone = "us-east-1c"
    subnet_id         = "subnet-03a855e712be7b399"
    # The framework CONSUMES key pairs and never creates them, so this names the standing
    # account key pair. user_data installs its public half by reading IMDS; the private half
    # lives only in the AWS_EC2_SSH_PRIVATE_KEY organization secret and the runner's
    # temporary directory.
    key_name = "nwarila-ec2-key"
    # Ratified 2026-08-12: the EC2 instance REUSES the org-owned profile as-is. This
    # repository never creates or modifies it; the runner role only reads and passes it.
    iam_instance_profile = "nwarila-ec2-profile"
    aws_kms_alias        = "aws/ebs"
    # Windows_Server-2025-English-STIG-Full, owner 801119661308 — accepted from the
    # framework's vendor allowlist, the same hardened base the sibling deploy uses.
    ami     = "ami-04807a1de3f592cc5"
    refresh = false
    # PDQ Deploy and PDQ Inventory are co-located on ONE Central Server host with their own
    # database engine; 4 GiB is not enough headroom for an all-in-one install.
    instance_type = "t3.large"
    # "ssh-ssm" names what actually happens: SSH on the wire, reached through an SSM tunnel
    # with no inbound path opened. The framework requires readiness_gate = false for this
    # transport because its own gate dials directly and cannot traverse the tunnel.
    connection_type = "ssh-ssm"
    readiness_user  = null

    readiness_gate             = false
    readiness_command          = null
    readiness_script_dir       = null
    readiness_private_key_path = null
    imds_hop_limit             = 1
    set_state                  = null

    tags = {
      Function = "pdq"
      Backup   = false
    }

    root_block_device = {
      delete_on_termination = true
      iops                  = null
      tags                  = {}
      throughput            = null
      volume_type           = "gp3"
      # The AMI's native size — PDQ's database and repository live on the data volume, so
      # padding the ephemeral root is pure cost.
      volume_size = "30"
    }

    # One RAW data disk. The deploy layer owns the hardware; the composed play's
    # windows_disk_manager formats it and assigns its drive letter. The Function tag is the
    # identity the disk role resolves it by (resolve_aws.yml), because a volume id only
    # exists after apply.
    ebs_block_devices = [
      {
        resource_key = "pdqdata"
        device_index = 0
        iops         = null
        snapshot_id  = null
        skip_destroy = false
        tags         = { Function = "PDQDATA" }
        throughput   = null
        volume_type  = "gp3"
        volume_size  = "30"
      }
    ]

    ami_block_device_overrides = []

    network_interfaces = [
      {
        description     = "pdq-poc-01 CI firewall"
        interface_type  = null
        private_ip      = null
        security_groups = []
        # Non-null ingress + egress => the framework creates and attaches the group.
        # Ingress [] = ZERO inbound: the runner's SSH rides the SSM agent's own outbound
        # session, so nothing on the internet can dial this instance. Egress is HTTPS only —
        # the SSM agent registering and streaming through the internet gateway.
        ingress = []
        egress = [
          {
            description                  = "HTTPS out (SSM agent registration and sessions)"
            ip_protocol                  = "tcp"
            from_port                    = 443
            to_port                      = 443
            cidr_ipv4                    = "0.0.0.0/0"
            prefix_list_id               = null
            referenced_security_group_id = null
          }
        ]
        tags = {}
      }
    ]

    # No Elastic IP: the subnet auto-assigns a public IPv4 at launch, which is all the SSM
    # agent's outbound registration needs. This is zero-inbound either way — the security
    # group allows no ingress — so the address is an egress route, not a door.
    associate_public_ip = false
  }
]

all_databases      = []
all_load_balancers = []
