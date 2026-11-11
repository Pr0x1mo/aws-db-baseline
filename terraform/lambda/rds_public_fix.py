"""
Closes a publicly accessible RDS instance as soon as AWS Config flags it,
then emails the team what was changed.

Trigger: EventBridge rule on "Config Rules Compliance Change" = NON_COMPLIANT
for the RDS_INSTANCE_PUBLIC_ACCESS_CHECK rule.

AWS Config reports RDS instances by their DbiResourceId (db-XXXXXXXX),
not by their name, so the function looks the instance up by that ID first.
"""

import json
import os

import boto3

rds = boto3.client("rds")
sns = boto3.client("sns")
TOPIC = os.environ["ALERT_TOPIC_ARN"]


def handler(event, context):
    resource_id = event["detail"]["resourceId"]  # e.g. db-ABCDEFGHIJKL

    found = rds.describe_db_instances(
        Filters=[{"Name": "dbi-resource-id", "Values": [resource_id]}]
    )["DBInstances"]

    if not found:
        print(f"No instance found for {resource_id}; it may have been deleted.")
        return {"status": "not_found"}

    db = found[0]
    name = db["DBInstanceIdentifier"]

    if not db.get("PubliclyAccessible"):
        print(f"{name} is already private; nothing to do.")
        return {"status": "already_private"}

    rds.modify_db_instance(
        DBInstanceIdentifier=name,
        PubliclyAccessible=False,
        ApplyImmediately=True,
    )

    message = {
        "action": "Set PubliclyAccessible = false",
        "instance": name,
        "dbi_resource_id": resource_id,
        "reason": "AWS Config rule RDS_INSTANCE_PUBLIC_ACCESS_CHECK reported NON_COMPLIANT",
        "next_step": "Find who made the change in CloudTrail (ModifyDBInstance or CreateDBInstance) "
                     "and make sure the Terraform code matches.",
    }
    sns.publish(
        TopicArn=TOPIC,
        Subject=f"Auto-remediated: {name} was publicly accessible",
        Message=json.dumps(message, indent=2),
    )

    print(json.dumps(message))
    return {"status": "remediated", "instance": name}
