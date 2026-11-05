#!/bin/bash

REGION="us-east-1"
INSTANCE="i-0fd99892ca323cb0b"

echo "Sending EC2 diagnostics..."

COMMAND_ID=$(aws ssm send-command \
  --instance-ids "$INSTANCE" \
  --document-name "AWS-RunShellScript" \
  --parameters '{"commands":["sudo systemctl status docker --no-pager","docker --version","sudo docker ps -a","sudo ss -tulpn","sudo cloud-init status --long","sudo tail -40 /var/log/cloud-init-output.log"]}' \
  --region "$REGION" \
  --query 'Command.CommandId' \
  --output text)

if [ -z "$COMMAND_ID" ] || [ "$COMMAND_ID" = "None" ]; then
    echo "Failed to send SSM command."
    exit 1
fi

echo "Command ID: $COMMAND_ID"
echo "Waiting for diagnostics..."

aws ssm wait command-executed \
  --command-id "$COMMAND_ID" \
  --instance-id "$INSTANCE" \
  --region "$REGION"

echo "Diagnostic results:"
aws ssm get-command-invocation \
  --command-id "$COMMAND_ID" \
  --instance-id "$INSTANCE" \
  --region "$REGION" \
  --query '{Status:Status,Output:StandardOutputContent,Errors:StandardErrorContent}' \
  --output json
