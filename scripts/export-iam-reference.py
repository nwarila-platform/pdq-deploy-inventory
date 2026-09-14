#!/usr/bin/env python3
# =========================================================================================== #
# File: 'scripts/export-iam-reference.py'
# --- [ Description ] ----------------------------------------------------------------------- #
#
# Regenerates docs/reference/aws-iam/ from the live AWS account, so the reference records what
# is deployed rather than what someone last remembered to copy. Hand-maintained copies of these
# documents drifted twice: one tree was scoped to a repository id that no longer exists, and the
# other held amendments that were never applied.
#
# Read-only: it calls only IAM get/list and STS get-caller-identity. The account id is replaced
# with <account-id> in memory, before anything is written.
#
#   usage: scripts/export-iam-reference.py [--profile admin] [--out docs/reference/aws-iam]
#
# Needs boto3 and a session that can read IAM (for this account: aws sso login --profile admin).
#
# =========================================================================================== #

import argparse
import datetime
import json
import os
import shutil

import boto3

# What this deployment touches. The two OIDC roles are the ones the workflows assume
# (DEPLOY_ROLE, REAPER_ROLE); the operator role is assumed by hand; the instance profile is the
# one terraform/aws.tfvars attaches to both hosts. Roles held by a profile are exported with it.
ROLES = [
    'nwarila-platform_pdq-deploy-inventory_runner',
    'nwarila-platform_pdq-deploy-inventory_reaper',
    'nwarila-platform_pdq-deploy-inventory_admin',
]
INSTANCE_PROFILES = [
    'nwarila-ec2-apprepo-profile',
]
SUBDIRECTORIES = ('policies', 'roles', 'instance-profiles')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--profile', default='admin')
    parser.add_argument('--out', default='docs/reference/aws-iam')
    args = parser.parse_args()

    session = boto3.Session(profile_name=args.profile)
    iam = session.client('iam')
    account = session.client('sts').get_caller_identity()['Account']

    def write(relative, document):
        path = os.path.join(args.out, relative)
        # Sorted, because IAM returns a condition's keys in a different order from one call to the
        # next: without it, re-exporting an unchanged account rewrites every trust document.
        text = json.dumps(document, indent=2, sort_keys=True).replace(account, '<account-id>')
        with open(path, 'w', encoding='utf-8', newline='\n') as handle:
            handle.write(text + '\n')

    # Start from empty, so a policy detached since the last export does not linger as if deployed.
    for subdirectory in SUBDIRECTORIES:
        shutil.rmtree(os.path.join(args.out, subdirectory), ignore_errors=True)
        os.makedirs(os.path.join(args.out, subdirectory))

    manifest = {'exported': datetime.date.today().isoformat(), 'roles': {}, 'instance_profiles': {}}

    def export_role(name):
        role = iam.get_role(RoleName=name)['Role']
        write('roles/%s.trust.json' % name, role['AssumeRolePolicyDocument'])
        attached = []
        for page in iam.get_paginator('list_attached_role_policies').paginate(RoleName=name):
            for policy in page['AttachedPolicies']:
                if ':aws:policy/' in policy['PolicyArn']:
                    attached.append({'name': policy['PolicyName'], 'managed_by': 'aws'})
                    continue
                default = iam.get_policy(PolicyArn=policy['PolicyArn'])['Policy']['DefaultVersionId']
                version = iam.get_policy_version(PolicyArn=policy['PolicyArn'], VersionId=default)
                write('policies/%s.json' % policy['PolicyName'], version['PolicyVersion']['Document'])
                attached.append({'name': policy['PolicyName'], 'version': default})
        inline = []
        for page in iam.get_paginator('list_role_policies').paginate(RoleName=name):
            for policy_name in page['PolicyNames']:
                document = iam.get_role_policy(RoleName=name, PolicyName=policy_name)['PolicyDocument']
                write('roles/%s.inline.%s.json' % (name, policy_name), document)
                inline.append(policy_name)
        manifest['roles'][name] = {'attached': sorted(attached, key=lambda p: p['name']), 'inline': inline}

    for name in ROLES:
        export_role(name)
    for name in INSTANCE_PROFILES:
        profile = iam.get_instance_profile(InstanceProfileName=name)['InstanceProfile']
        held = [role['RoleName'] for role in profile['Roles']]
        write('instance-profiles/%s.json' % name, {'InstanceProfileName': name, 'Roles': held})
        manifest['instance_profiles'][name] = held
        for role_name in held:
            export_role(role_name)

    write('manifest.json', manifest)
    print('exported %d roles and %d instance profiles to %s'
          % (len(manifest['roles']), len(manifest['instance_profiles']), args.out))


if __name__ == '__main__':
    main()
