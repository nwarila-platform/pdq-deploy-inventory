#!/usr/bin/env python3
"""Fail closed unless repository-owned EC2 dependency edges retain one exact identity."""

from __future__ import annotations

import argparse
from collections import Counter
import json
import os
import re
import subprocess
import sys
from typing import Any, Callable


REPOSITORY_TAG = "RepositoryId"
REPOSITORY_NAME_TAG = "Repository"
ENVIRONMENT_TAG = "Environment"
RUN_TAG = "RunId"
LIVE_INSTANCE_STATES = "pending,running,stopping,stopped,shutting-down"
EXPECTED_DATA_FUNCTIONS = ("PDQDATA",)
TERRAFORM_EC2_IDS = {
    "aws_instance": ("instance", re.compile(r"^i-[0-9a-f]+$")),
    "aws_network_interface": ("interface", re.compile(r"^eni-[0-9a-f]+$")),
    "aws_ebs_volume": ("volume", re.compile(r"^vol-[0-9a-f]+$")),
    "aws_eip": ("address", re.compile(r"^eipalloc-[0-9a-f]+$")),
}


class GraphError(RuntimeError):
    """The live graph could not be proven safe."""


def aws_json(*arguments: str) -> dict[str, Any]:
    result = subprocess.run(
        ["aws", *arguments, "--output", "json"],
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        detail = result.stderr.strip() or result.stdout.strip() or f"exit {result.returncode}"
        raise GraphError(f"AWS {' '.join(arguments[:2])} failed: {detail}")
    try:
        value = json.loads(result.stdout)
    except json.JSONDecodeError as exc:
        raise GraphError(f"AWS {' '.join(arguments[:2])} returned invalid JSON") from exc
    if not isinstance(value, dict):
        raise GraphError(f"AWS {' '.join(arguments[:2])} returned a non-object")
    return value


def terraform_show_json() -> dict[str, Any]:
    result = subprocess.run(
        ["terraform", "show", "-json"],
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        detail = result.stderr.strip() or result.stdout.strip() or f"exit {result.returncode}"
        raise GraphError(f"terraform show -json failed: {detail}")
    try:
        value = json.loads(result.stdout)
    except json.JSONDecodeError as exc:
        raise GraphError("terraform show -json returned invalid JSON") from exc
    if not isinstance(value, dict):
        raise GraphError("terraform show -json returned a non-object")
    return value


def terraform_resource_ids(state: dict[str, Any]) -> dict[str, set[str]]:
    """Read current managed EC2 identities from every Terraform state module."""

    identities = {kind: set() for kind, _pattern in TERRAFORM_EC2_IDS.values()}
    values = state.get("values")
    if values is None:
        return identities
    if not isinstance(values, dict):
        raise GraphError("Terraform state values are malformed")
    root_module = values.get("root_module")
    if root_module is None:
        return identities
    if not isinstance(root_module, dict):
        raise GraphError("Terraform root module is malformed")

    def visit(module: dict[str, Any]) -> None:
        resources = module.get("resources", [])
        children = module.get("child_modules", [])
        if not isinstance(resources, list) or not isinstance(children, list):
            raise GraphError("Terraform module resources or children are malformed")
        for resource in resources:
            if not isinstance(resource, dict):
                raise GraphError("Terraform state contains a malformed resource")
            resource_type = resource.get("type")
            if resource.get("mode", "managed") != "managed" or resource_type not in TERRAFORM_EC2_IDS:
                continue
            resource_values = resource.get("values")
            if not isinstance(resource_values, dict):
                raise GraphError(f"Terraform {resource_type} values are malformed")
            identifier = resource_values.get("id")
            kind, pattern = TERRAFORM_EC2_IDS[resource_type]
            if not isinstance(identifier, str) or pattern.fullmatch(identifier) is None:
                raise GraphError(f"Terraform {resource_type} has a malformed live id")
            identities[kind].add(identifier)
        for child in children:
            if not isinstance(child, dict):
                raise GraphError("Terraform state contains a malformed child module")
            visit(child)

    visit(root_module)
    return identities


def tags(resource: dict[str, Any]) -> dict[str, str]:
    raw = resource.get("Tags", resource.get("TagSet", []))
    if not isinstance(raw, list):
        raise GraphError("resource tags are not a list")
    result: dict[str, str] = {}
    for tag in raw:
        if not isinstance(tag, dict) or not isinstance(tag.get("Key"), str):
            raise GraphError("resource contains a malformed tag")
        value = tag.get("Value")
        if not isinstance(value, str) or tag["Key"] in result:
            raise GraphError("resource contains a duplicate or non-string tag")
        result[tag["Key"]] = value
    return result


def list_field(value: dict[str, Any], key: str, label: str) -> list[Any]:
    if key not in value or not isinstance(value[key], list):
        raise GraphError(f"{label} has no valid {key} list")
    return value[key]


def optional_mapping(value: dict[str, Any], key: str, label: str) -> dict[str, Any]:
    if key not in value:
        return {}
    result = value[key]
    if not isinstance(result, dict):
        raise GraphError(f"{label} has a malformed {key} mapping")
    return result


def flatten_instances(response: dict[str, Any]) -> list[dict[str, Any]]:
    instances: list[dict[str, Any]] = []
    for reservation in list_field(response, "Reservations", "DescribeInstances response"):
        if not isinstance(reservation, dict):
            raise GraphError("DescribeInstances returned a malformed reservation")
        raw_instances = list_field(reservation, "Instances", "DescribeInstances reservation")
        instances.extend(raw_instances)
    if not all(isinstance(instance, dict) for instance in instances):
        raise GraphError("DescribeInstances returned a malformed instance")
    return instances


def exact_one(resources: list[dict[str, Any]], kind: str, identifier: str) -> dict[str, Any]:
    if len(resources) != 1:
        raise GraphError(f"could not read exactly one {kind} {identifier}")
    return resources[0]


class Inventory:
    def __init__(
        self, repository_id: str, repository: str, expected_run_id: str | None = None
    ) -> None:
        self.repository_id = repository_id
        self.repository = repository
        self.expected_run_id = expected_run_id
        repository_filter = f"Name=tag:{REPOSITORY_TAG},Values={repository_id}"
        self.instances = {
            item["InstanceId"]: item
            for item in flatten_instances(
                aws_json(
                    "ec2",
                    "describe-instances",
                    "--filters",
                    repository_filter,
                    f"Name=instance-state-name,Values={LIVE_INSTANCE_STATES}",
                )
            )
        }
        self.interfaces = {
            item["NetworkInterfaceId"]: item
            for item in list_field(
                aws_json("ec2", "describe-network-interfaces", "--filters", repository_filter),
                "NetworkInterfaces",
                "DescribeNetworkInterfaces response",
            )
        }
        self.volumes = {
            item["VolumeId"]: item
            for item in list_field(
                aws_json("ec2", "describe-volumes", "--filters", repository_filter),
                "Volumes",
                "DescribeVolumes response",
            )
        }
        self.addresses = {
            item["AllocationId"]: item
            for item in list_field(
                aws_json("ec2", "describe-addresses", "--filters", repository_filter),
                "Addresses",
                "DescribeAddresses response",
            )
        }

    @classmethod
    def from_fixture(
        cls,
        repository_id: str,
        repository: str,
        instances: list[dict[str, Any]],
        interfaces: list[dict[str, Any]],
        volumes: list[dict[str, Any]],
        addresses: list[dict[str, Any]],
        expected_run_id: str | None = None,
    ) -> "Inventory":
        inventory = cls.__new__(cls)
        inventory.repository_id = repository_id
        inventory.repository = repository
        inventory.expected_run_id = expected_run_id
        inventory.instances = {item["InstanceId"]: item for item in instances}
        inventory.interfaces = {item["NetworkInterfaceId"]: item for item in interfaces}
        inventory.volumes = {item["VolumeId"]: item for item in volumes}
        inventory.addresses = {item["AllocationId"]: item for item in addresses}
        return inventory

    def identity_run(self, resource: dict[str, Any], label: str) -> str:
        identity = tags(resource)
        run_id = identity.get(RUN_TAG, "")
        expected = {
            REPOSITORY_TAG: self.repository_id,
            REPOSITORY_NAME_TAG: self.repository,
            ENVIRONMENT_TAG: "test",
        }
        if any(identity.get(key) != value for key, value in expected.items()):
            raise GraphError(f"{label} has foreign or malformed repository/environment tags")
        if not run_id.isdigit():
            raise GraphError(f"{label} has no numeric run identity")
        if self.expected_run_id is not None and run_id != self.expected_run_id:
            raise GraphError(
                f"{label} belongs to run {run_id}; expected {self.expected_run_id}"
            )
        return run_id

    def instance(self, identifier: str) -> dict[str, Any]:
        if identifier not in self.instances:
            self.instances[identifier] = exact_one(
                flatten_instances(
                    aws_json("ec2", "describe-instances", "--instance-ids", identifier)
                ),
                "instance",
                identifier,
            )
        return self.instances[identifier]

    def interface(self, identifier: str) -> dict[str, Any]:
        if identifier not in self.interfaces:
            self.interfaces[identifier] = exact_one(
                list_field(
                    aws_json(
                        "ec2", "describe-network-interfaces", "--network-interface-ids", identifier
                    ),
                    "NetworkInterfaces",
                    "DescribeNetworkInterfaces response",
                ),
                "network interface",
                identifier,
            )
        return self.interfaces[identifier]

    def volume(self, identifier: str) -> dict[str, Any]:
        if identifier not in self.volumes:
            self.volumes[identifier] = exact_one(
                list_field(
                    aws_json("ec2", "describe-volumes", "--volume-ids", identifier),
                    "Volumes",
                    "DescribeVolumes response",
                ),
                "volume",
                identifier,
            )
        return self.volumes[identifier]

    def address(self, identifier: str) -> dict[str, Any]:
        if identifier not in self.addresses:
            self.addresses[identifier] = exact_one(
                list_field(
                    aws_json("ec2", "describe-addresses", "--allocation-ids", identifier),
                    "Addresses",
                    "DescribeAddresses response",
                ),
                "elastic IP",
                identifier,
            )
        return self.addresses[identifier]

    def include_terraform_state(self, state: dict[str, Any]) -> None:
        """Union exact state-owned IDs with the tag-filtered discovery roots."""

        identities = terraform_resource_ids(state)

        def include(
            identifier: str,
            kind: str,
            not_found_code: str,
            cache: dict[str, dict[str, Any]],
            loader: Callable[[], list[dict[str, Any]]],
        ) -> None:
            if identifier in cache:
                return
            try:
                resources = loader()
            except GraphError as exc:
                # An interrupted destroy can leave a syntactically valid ID in state after the
                # real object is gone. Only the EC2 API's exact resource-specific NotFound is
                # absence; authorization, transport, and all other failures remain fatal.
                if f"({not_found_code})" in str(exc):
                    return
                raise
            if not isinstance(resources, list):
                raise GraphError(f"state lookup for {kind} {identifier} returned a malformed list")
            if not resources:
                return
            cache[identifier] = exact_one(resources, kind, identifier)

        for identifier in identities["instance"]:
            include(
                identifier,
                "instance",
                "InvalidInstanceID.NotFound",
                self.instances,
                lambda identifier=identifier: flatten_instances(
                    aws_json("ec2", "describe-instances", "--instance-ids", identifier)
                ),
            )
        for identifier in identities["interface"]:
            include(
                identifier,
                "network interface",
                "InvalidNetworkInterfaceID.NotFound",
                self.interfaces,
                lambda identifier=identifier: list_field(
                    aws_json(
                        "ec2", "describe-network-interfaces", "--network-interface-ids", identifier
                    ),
                    "NetworkInterfaces",
                    "DescribeNetworkInterfaces response",
                ),
            )
        for identifier in identities["volume"]:
            include(
                identifier,
                "volume",
                "InvalidVolume.NotFound",
                self.volumes,
                lambda identifier=identifier: list_field(
                    aws_json("ec2", "describe-volumes", "--volume-ids", identifier),
                    "Volumes",
                    "DescribeVolumes response",
                ),
            )
        for identifier in identities["address"]:
            include(
                identifier,
                "elastic IP",
                "InvalidAllocationID.NotFound",
                self.addresses,
                lambda identifier=identifier: list_field(
                    aws_json("ec2", "describe-addresses", "--allocation-ids", identifier),
                    "Addresses",
                    "DescribeAddresses response",
                ),
            )

    def same_identity(self, parent_run: str, resource: dict[str, Any], label: str) -> None:
        child_run = self.identity_run(resource, label)
        if child_run != parent_run:
            raise GraphError(f"{label} belongs to run {child_run}; parent belongs to {parent_run}")

    def validate(self, require_pdq_data_volumes: bool = False) -> None:
        root_instances = list(self.instances.values())
        root_interfaces = list(self.interfaces.values())
        root_volumes = list(self.volumes.values())
        root_addresses = list(self.addresses.values())

        if require_pdq_data_volumes and len(root_instances) != 1:
            raise GraphError(
                f"PDQ configuration requires exactly one live repository instance; got {len(root_instances)}"
            )

        for instance in root_instances:
            instance_id = instance.get("InstanceId", "unknown")
            run_id = self.identity_run(instance, f"instance {instance_id}")
            attached_volumes: list[tuple[str, dict[str, Any]]] = []
            for interface_ref in list_field(
                instance, "NetworkInterfaces", f"instance {instance_id}"
            ):
                if not isinstance(interface_ref, dict):
                    raise GraphError(f"instance {instance_id} has a malformed ENI reference")
                interface_id = interface_ref.get("NetworkInterfaceId")
                if not isinstance(interface_id, str) or not interface_id:
                    raise GraphError(f"instance {instance_id} has a malformed ENI reference")
                self.same_identity(
                    run_id, self.interface(interface_id), f"network interface {interface_id}"
                )
            for mapping in list_field(
                instance, "BlockDeviceMappings", f"instance {instance_id}"
            ):
                if not isinstance(mapping, dict):
                    raise GraphError(f"instance {instance_id} has a malformed EBS mapping")
                ebs = optional_mapping(mapping, "Ebs", f"instance {instance_id} EBS mapping")
                volume_id = ebs.get("VolumeId")
                device_name = mapping.get("DeviceName")
                if not isinstance(volume_id, str) or not volume_id:
                    raise GraphError(f"instance {instance_id} has a malformed EBS reference")
                if not isinstance(device_name, str) or not device_name:
                    raise GraphError(f"instance {instance_id} has a malformed EBS device name")
                volume = self.volume(volume_id)
                self.same_identity(run_id, volume, f"volume {volume_id}")
                attached_volumes.append((device_name, volume))
            if require_pdq_data_volumes:
                root_device = instance.get("RootDeviceName")
                if not isinstance(root_device, str) or not root_device:
                    raise GraphError(f"instance {instance_id} has no exact root device name")
                system_volumes = [volume for device, volume in attached_volumes if device == root_device]
                data_volumes = [volume for device, volume in attached_volumes if device != root_device]
                expected_data = len(EXPECTED_DATA_FUNCTIONS)
                if (
                    len(attached_volumes) != expected_data + 1
                    or len(system_volumes) != 1
                    or len(data_volumes) != expected_data
                ):
                    raise GraphError(
                        f"instance {instance_id} must have one root and exactly "
                        f"{expected_data} data volume(s); got {len(data_volumes)}"
                    )
                if tags(system_volumes[0]).get("Function") in EXPECTED_DATA_FUNCTIONS:
                    raise GraphError(
                        f"instance {instance_id} root volume carries a reserved PDQ data identity"
                    )
                functions = Counter(tags(volume).get("Function") for volume in data_volumes)
                actual = {name: functions[name] for name in EXPECTED_DATA_FUNCTIONS}
                expected = {name: 1 for name in EXPECTED_DATA_FUNCTIONS}
                if actual != expected:
                    raise GraphError(
                        f"instance {instance_id} PDQ data-volume cardinality is {actual}; expected {expected}"
                    )

        for interface in root_interfaces:
            interface_id = interface.get("NetworkInterfaceId", "unknown")
            run_id = self.identity_run(interface, f"network interface {interface_id}")
            attachment = optional_mapping(
                interface, "Attachment", f"network interface {interface_id}"
            )
            instance_id = attachment.get("InstanceId")
            if instance_id is not None and (not isinstance(instance_id, str) or not instance_id):
                raise GraphError(f"network interface {interface_id} has a malformed instance attachment")
            if instance_id:
                self.same_identity(run_id, self.instance(instance_id), f"instance {instance_id}")
            association = optional_mapping(
                interface, "Association", f"network interface {interface_id}"
            )
            allocation_ids: set[str] = set()

            def record_allocation(candidate: Any) -> None:
                if candidate is None:
                    return
                if not isinstance(candidate, str) or not candidate:
                    raise GraphError(
                        f"network interface {interface_id} has a malformed EIP association"
                    )
                allocation_ids.add(candidate)

            record_allocation(association.get("AllocationId"))
            for private_address in list_field(
                interface, "PrivateIpAddresses", f"network interface {interface_id}"
            ):
                if not isinstance(private_address, dict):
                    raise GraphError(
                        f"network interface {interface_id} has a malformed private address"
                    )
                private_association = optional_mapping(
                    private_address,
                    "Association",
                    f"network interface {interface_id} private address",
                )
                record_allocation(private_association.get("AllocationId"))
            for allocation_id in sorted(allocation_ids):
                self.same_identity(run_id, self.address(allocation_id), f"elastic IP {allocation_id}")

        for volume in root_volumes:
            volume_id = volume.get("VolumeId", "unknown")
            run_id = self.identity_run(volume, f"volume {volume_id}")
            for attachment in list_field(volume, "Attachments", f"volume {volume_id}"):
                if not isinstance(attachment, dict):
                    raise GraphError(f"volume {volume_id} has a malformed instance attachment")
                instance_id = attachment.get("InstanceId")
                if not isinstance(instance_id, str) or not instance_id:
                    raise GraphError(f"volume {volume_id} has a malformed instance attachment")
                self.same_identity(run_id, self.instance(instance_id), f"instance {instance_id}")

        for address in root_addresses:
            allocation_id = address.get("AllocationId", "unknown")
            run_id = self.identity_run(address, f"elastic IP {allocation_id}")
            interface_id = address.get("NetworkInterfaceId")
            if interface_id is not None and (
                not isinstance(interface_id, str) or not interface_id
            ):
                raise GraphError(f"elastic IP {allocation_id} has a malformed ENI association")
            if interface_id:
                self.same_identity(
                    run_id, self.interface(interface_id), f"network interface {interface_id}"
                )
            instance_id = address.get("InstanceId")
            if instance_id is not None and (not isinstance(instance_id, str) or not instance_id):
                raise GraphError(f"elastic IP {allocation_id} has a malformed instance association")
            if instance_id:
                self.same_identity(run_id, self.instance(instance_id), f"instance {instance_id}")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--repository-id", default=os.environ.get("GITHUB_REPOSITORY_ID", "")
    )
    parser.add_argument(
        "--repository", default=os.environ.get("GITHUB_REPOSITORY", "")
    )
    parser.add_argument("--expected-run-id", default=None)
    parser.add_argument("--require-pdq-data-volumes", action="store_true")
    parser.add_argument("--include-terraform-state", action="store_true")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if not args.repository_id.isdigit():
        raise GraphError("repository id must be numeric")
    if args.expected_run_id is not None and not args.expected_run_id.isdigit():
        raise GraphError("expected run id must be numeric")
    inventory = Inventory(args.repository_id, args.repository, args.expected_run_id)
    if args.include_terraform_state:
        inventory.include_terraform_state(terraform_show_json())
    inventory.validate(args.require_pdq_data_volumes)
    print("AWS dependency graph proof passed: every attachment retains exact same-run identity.")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except GraphError as exc:
        print(f"assert-aws-resource-graph: FAIL — {exc}", file=sys.stderr)
        raise SystemExit(1) from exc
