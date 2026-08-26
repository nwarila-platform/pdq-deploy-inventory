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
# The OpenSSH DefaultShell boots as cmd; the playbook's bootstrap play flips it to PowerShell on
# first contact, and every play after that declares the PowerShell shell type.
#
# =========================================================================================== #

# environment and the deployment identity (repository, repository_id, commit_sha, run_id) are
# deliberately NOT in this file: the workflow passes them with -var, the highest-precedence
# source, so the identity that drives the provider's tags cannot be overridden here.

all_systems = [
  {
    region   = "us_east_1"
    hostname = "tcnaw-pdq01"
    # The ratified availability-zone spec lock, and a subnet in this account's only VPC.
    availability_zone = "us-east-1c"
    subnet_id         = "subnet-03a855e712be7b399"
    # The framework CONSUMES key pairs and never creates them, so this names the standing
    # account key pair. user_data installs its public half by reading IMDS; the private half
    # lives only in the AWS_EC2_SSH_PRIVATE_KEY organization secret and the runner's
    # temporary directory.
    key_name = "nwarila-ec2-key"
    # The org EC2 baseline plus read-only access to the application repository bucket, which is
    # what lets this host pull its own repository contents down rather than receiving them from
    # the controller. It is a SEPARATE profile, not an edit to the shared one: the org-owned
    # nwarila-ec2-profile stays exactly as it is, and this repository still creates and modifies
    # neither -- the runner role only reads and passes whichever is named here.
    iam_instance_profile = "nwarila-ec2-apprepo-profile"
    aws_kms_alias        = "aws/ebs"
    # Windows_Server-2025-English-STIG-Full, owner 801119661308 — accepted from the
    # framework's vendor allowlist, the same hardened base the sibling deploy uses.
    ami = "ami-04807a1de3f592cc5"
    # OS-DRIVE REPLACEMENT (immutable-OS pattern). refresh=true makes this host's OS instance
    # swap-eligible: bumping the framework's refresh_serial variable (0 -> 1 -> ...) replaces the
    # OS instance in place while the standalone data volumes below detach and re-attach to the
    # replacement, so the databases (D:, E:) and repository (F:) survive an OS rebuild and PDQ
    # resumes on them. It is a no-op until refresh_serial actually changes, so the ephemeral
    # apply -> converge -> destroy path is unaffected.
    refresh = true
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
      # The AMI's native size — PDQ's databases and repository live on their own volumes, so
      # padding the ephemeral root is pure cost.
      volume_size = "30"
    }

    # Three RAW data disks, one per concern, so each can be sized, backed up and permissioned
    # on its own: PDQ Inventory's database, PDQ Deploy's database, and the shared package
    # repository. The deploy layer owns the hardware; the composed play's windows_disk_manager
    # formats each and assigns its drive letter. The Function tag is the identity the disk role
    # resolves a volume by (resolve_aws.yml), because a volume id only exists after apply, so
    # each tag here must be unique and must match the play's disk layout. Each is a STANDALONE
    # volume whose lifecycle is independent of the OS instance, so an OS replacement (refresh
    # above) detaches and re-attaches the SAME volume instead of recreating it. skip_destroy=false
    # tears them down with the ephemeral showcase; a persistent production deployment sets
    # skip_destroy=true so the data survives a full `terraform destroy`.
    ebs_block_devices = [
      {
        resource_key = "pdqinventory"
        device_index = 0
        iops         = null
        snapshot_id  = null
        skip_destroy = false
        tags         = { Function = "PDQINVENTORY" }
        throughput   = null
        volume_type  = "gp3"
        volume_size  = "30"
      },
      {
        resource_key = "pdqdeploy"
        device_index = 1
        iops         = null
        snapshot_id  = null
        skip_destroy = false
        tags         = { Function = "PDQDEPLOY" }
        throughput   = null
        volume_type  = "gp3"
        volume_size  = "30"
      },
      {
        resource_key = "pdqrepository"
        device_index = 2
        iops         = null
        snapshot_id  = null
        skip_destroy = false
        tags         = { Function = "PDQREPO" }
        throughput   = null
        volume_type  = "gp3"
        # The repository holds every package's installer files, so it is the volume that grows.
        volume_size = "60"
      }
    ]

    ami_block_device_overrides = []

    network_interfaces = [
      {
        description     = "tcnaw-pdq01 CI firewall"
        interface_type  = null
        private_ip      = null
        security_groups = []
        ingress         = []
        egress = [
          {
            description                  = "HTTPS out"
            ip_protocol                  = "tcp"
            from_port                    = 443
            to_port                      = 443
            cidr_ipv4                    = "0.0.0.0/0"
            prefix_list_id               = null
            referenced_security_group_id = null
          },
          # The VPN tunnel that carries the host onto the private network. Scoped by port rather
          # than by address: the profile names its endpoint by DNS, and that address changes.
          {
            description                  = "OpenVPN tunnel out"
            ip_protocol                  = "udp"
            from_port                    = 1194
            to_port                      = 1194
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
