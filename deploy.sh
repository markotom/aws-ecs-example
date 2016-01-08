#!/bin/bash

if [ -z "$(which aws)" ]; then
	echo "Error: Please install AWS-CLI first"
	exit 1
fi

# Constants
APP_NAME="store-demo"
APP_DESCRIPTION="This a simple store demo using AWS ECS"
CLUSTER_NAME="$APP_NAME-cluster"
SERVICE_NAME="$APP_NAME-service"
TASK_DEFINITION="$APP_NAME-containers"
TASKS_DESIRED_COUNT=1
VPC_NAME="$APP_NAME-vpc"
VPC_CIDR="172.31.0.0"
SUBNET_NAME="$APP_NAME-subnet"
AUTOSCALING_GROUP_NAME="$APP_NAME-group"
ECS_ROLE="ecsInstanceRole"
MIN_SIZE_INSTANCES=1
MAX_SIZE_INSTANCES=1
BASE=$(pwd)

# Get AWS region
REGION=$(aws configure list | grep region | awk '{ print $2 }')

if [ -z "$REGION" ]; then
	echo "Error: You muste run 'aws configure' to set a default region"
	exit 1
fi

# Set AMI available by region
case "$REGION" in
	"us-east-1") AMI="ami-6ff4bd05"
		;;
	"us-west-1") AMI="ami-46cda526"
		;;
	"us-west-2") AMI="ami-313d2150"
		;;
	"eu-west-1") AMI="ami-8073d3f3"
		;;
	"eu-central-1") AMI="ami-60627e0c"
		;;
	"ap-northeast-1") AMI="ami-6ca38b02"
		;;
	"ap-southeast-1") AMI="ami-a6ba79c5"
		;;
	"ap-southeast-2") AMI="ami-00e7bf63"
		;;
esac

# Check if cluster is already created and running
CLUSTER_STATUS=$(aws ecs describe-clusters --clusters $CLUSTER_NAME --query 'clusters[0].status' --output text)
if [ "$CLUSTER_STATUS" != "None" -a "$CLUSTER_STATUS" != "INACTIVE" ]; then
	echo "Error: AWS ECS cluster \"$CLUSTER_NAME\" is already created"
	exit 1
fi

# Cluster
echo -n "Creating AWS ECS cluster ($CLUSTER_NAME) .. "
aws ecs create-cluster --cluster-name $CLUSTER_NAME
echo "done"

# VPC
echo -n "Creating VPC ($VPC_NAME) .. "
VPC_ID=$(aws ec2 create-vpc --cidr-block $VPC_CIDR/16 --query 'Vpc.VpcId' --output text)
aws ec2 modify-vpc-attribute --vpc-id $VPC_ID --enable-dns-support
aws ec2 modify-vpc-attribute --vpc-id $VPC_ID --enable-dns-hostnames
aws ec2 create-tags --resources $VPC_ID --tag Key=Name,Value=$VPC_NAME
echo "done"

# Subnet
echo -n "Creating Subnet ($SUBNET_NAME) .. "
SUBNET_ID=$(aws ec2 create-subnet --vpc-id $VPC_ID --cidr-block $VPC_CIDR/28 --query 'Subnet.SubnetId' --output text)
aws ec2 create-tags --resources $SUBNET_ID --tag Key=Name,Value=$SUBNET_NAME
echo "done"

# Internet Gateway
echo -n "Creating Internet Gateway ($APP_NAME) .. "
GW_ID=$(aws ec2 create-internet-gateway --query 'InternetGateway.InternetGatewayId' --output text)
aws ec2 create-tags --resources $GW_ID --tag Key=Name,Value=$APP_NAME
aws ec2 attach-internet-gateway --internet-gateway-id $GW_ID --vpc-id $VPC_ID
TABLE_ID=$(aws ec2 describe-route-tables --query 'RouteTables[?VpcId==`'$VPC_ID'`].RouteTableId' --output text)
aws ec2 create-route --route-table-id $TABLE_ID --destination-cidr-block 0.0.0.0/0 --gateway-id $GW_ID
echo "done"

# Security group
echo -n "Creating Security Group ($APP_NAME) .. "
SECURITY_GROUP_ID=$(aws ec2 create-security-group --group-name $APP_NAME --vpc-id $VPC_ID --description "$APP_DESCRIPTION" --query 'GroupId' --output text)
sleep 5
aws ec2 authorize-security-group-ingress --group-id $SECURITY_GROUP_ID --protocol tcp --port 22 --cidr 0.0.0.0/0
aws ec2 authorize-security-group-ingress --group-id $SECURITY_GROUP_ID --protocol tcp --port 80 --cidr 0.0.0.0/0
aws ec2 authorize-security-group-ingress --group-id $SECURITY_GROUP_ID --protocol tcp --port 3000 --cidr 0.0.0.0/0
echo "done"

# Key pair
echo -n "Creating Key Pair ($APP_NAME, file $APP_NAME-key.pem) .. "
aws ec2 create-key-pair --key-name $APP_NAME-key --query 'KeyMaterial' --output text > $APP_NAME-key.pem
chmod 600 $APP_NAME-key.pem
echo "done"

# Launch configuration
echo -n "Creating Launch Configuration ($APP_NAME-launch-configuration) .. "
sleep 20

aws autoscaling create-launch-configuration --image-id $AMI --launch-configuration-name $APP_NAME-launch-configuration --key-name $APP_NAME-key --security-groups $SECURITY_GROUP_ID --instance-type t2.micro --user-data file://$BASE/set-cluster-name.sh  --iam-instance-profile $ECS_ROLE --associate-public-ip-address --instance-monitoring Enabled=false
echo "done"

# Auto Scaling Group
echo -n "Creating Auto Scaling Group ($AUTOSCALING_GROUP_NAME) with $MAX_SIZE_INSTANCES instances .. "
aws autoscaling create-auto-scaling-group --auto-scaling-group-name $AUTOSCALING_GROUP_NAME --launch-configuration-name $APP_NAME-launch-configuration --min-size $MIN_SIZE_INSTANCES --max-size $MAX_SIZE_INSTANCES --desired-capacity $MAX_SIZE_INSTANCES --vpc-zone-identifier $SUBNET_ID
echo "done"

# Wait for instances to be attached to cluster
echo -n "Waiting for instances to be attached to cluster (this may take a few minutes) .. "
while [ "$(aws ecs describe-clusters --clusters $CLUSTER_NAME --query 'clusters[0].registeredContainerInstancesCount' --output text)" != $MAX_SIZE_INSTANCES ]; do
    sleep 2
done
echo "done"

# Task definition
echo -n "Registering AWS ECS task definition ($TASK_DEFINITION) .. "
aws ecs register-task-definition --cli-input-json file://$BASE/task-definition.json
echo "done"

# Service
echo -n "Creating AWS ECS Service with $TASKS_DESIRED_COUNT tasks ($SERVICE_NAME) .. "
aws ecs create-service --cluster $CLUSTER_NAME --service-name  $SERVICE_NAME --task-definition $TASK_DEFINITION --desired-count $TASKS_DESIRED_COUNT
echo "done"

# Wait for tasks to be executed
echo -n "Waiting for tasks to be executed .. "
while [ "$(aws ecs describe-clusters --clusters $CLUSTER_NAME --query 'clusters[0].runningTasksCount')" != $TASKS_DESIRED_COUNT ]; do
    sleep 2
done
echo "done"

# Search the public hostnames of the created instances
INSTANCE_IDS=$(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names $AUTOSCALING_GROUP_NAME --query 'AutoScalingGroups[0].Instances[*].InstanceId' --output text)
DNS_NAMES=$(aws ec2 describe-instances --instance-ids $INSTANCE_IDS --query 'Reservations[0].Instances[*].PublicDnsName' --output text)

echo "Setup is completed."
echo "Open your browser with this URLs:"
for DNS_NAME in $DNS_NAMES; do
    echo "–  http://$DNS_NAME"
done
