# =========================================================================================== #
# File: 'terraform/aws.tfvars'
# --- [ Description ] ----------------------------------------------------------------------- #
#
# Variable input for the pinned aws-terraform-framework (SHA in .github/terraform-framework-pin).
# Plain tfvars — the workflow passes this file to terraform verbatim. This repository declares
# NO .tf files of its own: resources live in the pinned framework, configuration in the pinned
# ansible-framework plus this repository's roles.
#
# REACHABILITY — DIRECT SSH OVER A PUBLIC IPv4. The workflow discovers the runner's public IPv4
# and passes it as the framework's runtime-only runner_ip variable. The framework attaches one
# security group scoped to that address to every interface. The instance receives a public IPv4
# at launch; no Elastic IP is involved. The account has no NAT and no VPC endpoints.
#
# The dependency worth knowing: MapPublicIpOnLaunch is an attribute of a shared subnet no
# repository owns. Direct SSH requires the instance's launch-time public address as well as the
# runner-scoped security group.
#
# readiness_gate is FALSE by design: the playbook owns the bounded direct-SSH readiness check.
# The OpenSSH DefaultShell stays cmd — the boot default — because a PowerShell login shell breaks
# ansible's module bootstrap.
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
    # Direct SSH reaches the launch-time public IPv4 through the runner-scoped framework SG.
    connection_type = "ssh"
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
        # Deliberate temporary development-cycle allowance: SSH from the whole IPv4 space, split
        # into two halves because the framework refuses a zero-length prefix; remove when the cycle ends.
        ingress = [
          {
            description                  = "SSH from first half of IPv4"
            ip_protocol                  = "tcp"
            from_port                    = 22
            to_port                      = 22
            cidr_ipv4                    = "0.0.0.0/1"
            prefix_list_id               = null
            referenced_security_group_id = null
          },
          {
            description                  = "SSH from second half of IPv4"
            ip_protocol                  = "tcp"
            from_port                    = 22
            to_port                      = 22
            cidr_ipv4                    = "128.0.0.0/1"
            prefix_list_id               = null
            referenced_security_group_id = null
          }
        ]
        egress = [
          {
            description                  = "HTTPS out"
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

    # No Elastic IP: the subnet auto-assigns the launch-time public IPv4 used for direct SSH.
    associate_public_ip = false
  }
]

all_databases      = []
all_load_balancers = []
